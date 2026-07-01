defmodule ObanClaude do
  @moduledoc """
  Run a Claude Code job (via [`claude_wrapper`](https://hex.pm/packages/claude_wrapper))
  on an Oban queue.

  `oban_claude` is the thin seam between Oban and claude:

    * `run/2` is the engine: a string-keyed args map in, a `{oban_return, result}`
      tuple out. It calls `ClaudeWrapper.query/2` and maps the typed
      `%ClaudeWrapper.Result{}` / `%ClaudeWrapper.Error{}` onto Oban's return
      values via a classifier (see `ObanClaude.Outcome`).
    * `ObanClaude.Worker` is the drop-in worker (`use ObanClaude.Worker`) with a
      single `c:ObanClaude.Worker.handle_result/2` override point.

  It owns no state and runs no daemon, and takes no position on what consumes a
  result. Whether the agent effects its own writes (full-auto) or returns
  structured data for a downstream effector is encoded in the *job's* args
  (prompt + permission mode), never here, so `oban_claude` supports both.

  ## Example

  Build the job's args with `ObanClaude.Args.new/1` (atom keys, validated) rather
  than a hand-written string map:

      defmodule MyApp.ClaudeJob do
        use ObanClaude.Worker, queue: :claude, max_attempts: 3
      end

      ObanClaude.Args.new(prompt: "summarize the repo", working_dir: "/path/to/repo")
      |> MyApp.ClaudeJob.new()
      |> Oban.insert()

  The raw string-keyed map is still accepted as the low-level escape hatch:

      %{"prompt" => "summarize the repo", "working_dir" => "/path/to/repo"}
      |> MyApp.ClaudeJob.new()
      |> Oban.insert()

  ## Telemetry

  `run/2` emits the following events via `:telemetry`:

  ### `[:oban_claude, :run, :stop]`

  Emitted after a successful `ClaudeWrapper.query/2` call. This includes
  `is_error: true` results, which are returned without raising.

    * Measurements:
      * `:duration` -- wall time of the query in native time units (convert with
        `System.convert_time_unit/3`)
      * `:cost_usd` -- the reported cost in USD from the result (`0.0` when the
        result carries no cost)
    * Metadata:
      * `:result` -- the `%ClaudeWrapper.Result{}` struct
      * `:args` -- the string-keyed args map passed to `run/2`

  ### `[:oban_claude, :run, :exception]`

  Emitted when `ClaudeWrapper.query/2` returns `{:error, %ClaudeWrapper.Error{}}`.

    * Measurements:
      * `:duration` -- wall time of the query in native time units
    * Metadata:
      * `:error` -- the `%ClaudeWrapper.Error{}` struct
      * `:args` -- the string-keyed args map passed to `run/2`
  """

  alias ClaudeWrapper.{Error, Result}

  @typedoc "An `c:Oban.Worker.perform/1` return value."
  @type oban_return ::
          :ok | {:ok, term} | {:error, term} | {:cancel, term} | {:snooze, pos_integer}

  # Args-map keys passed straight through to `ClaudeWrapper.query/2`. Kept a
  # superset of `ObanClaude.Args`'s curated keys, or a key the constructor emits
  # would be silently dropped when `build/1` assembles the query opts.
  @passthrough ~w(model max_turns max_budget_usd working_dir permission_mode timeout
                  system_prompt append_system_prompt fallback_model add_dir json_schema
                  allowed_tools disallowed_tools mcp_config effort agent)

  # String key -> atom key, resolved at COMPILE time so the atoms always exist.
  # `String.to_existing_atom/1` would depend on ClaudeWrapper.Query (the module
  # that defines these atoms) already being loaded -- not guaranteed before the
  # first query call, so it would crash the build of the very first job.
  @passthrough_atoms Map.new(@passthrough, &{&1, String.to_atom(&1)})

  # `permission_mode` arrives as a JSON string but `ClaudeWrapper.query/2`
  # pattern-matches it as an atom. Map it through an explicit allowlist rather
  # than `String.to_existing_atom/1`: the latter depends on ClaudeWrapper.Query
  # already being loaded (it is the module that defines these atoms), which is
  # not guaranteed before the first query call. The allowlist also documents
  # and validates the accepted vocabulary here.
  @permission_modes ~w(default accept_edits bypass_permissions dont_ask plan auto)
                    |> Map.new(&{&1, String.to_atom(&1)})

  # `effort` is the second atom-valued key: `ClaudeWrapper.query/2` matches it as
  # an atom, but it arrives as a JSON string. Same allowlist treatment as
  # `permission_mode`, for the same load-order reason.
  @efforts ~w(low medium high xhigh max) |> Map.new(&{&1, String.to_atom(&1)})

  @doc """
  Run a claude job from a string-keyed `args` map.

  Returns `{oban_return, %Result{} | %Error{}}` so a caller can both act on the
  Oban verdict and inspect the underlying run (cost, session id, structured
  output). `:prompt` is required; every key in `@passthrough` is forwarded to
  `ClaudeWrapper.query/2`.

  Options:

    * `:classifier` -- a 1-arity fun mapping the claude call's result onto
      `{oban_return, term}`. Defaults to `&ObanClaude.Outcome.classify/1`.
    * `:query_fun` -- the claude entrypoint: a 2-arity fun
      `(prompt, query_opts) -> {:ok, %Result{}} | {:error, %Error{}}`. Defaults
      to `&ClaudeWrapper.query/2`. Override to stub claude in tests, or to route
      through a different wrapper entrypoint.
  """
  @spec run(map, keyword) :: {oban_return, Result.t() | Error.t() | term()}
  def run(args, opts \\ []) when is_map(args) do
    classifier = Keyword.get(opts, :classifier, &ObanClaude.Outcome.classify/1)
    query_fun = Keyword.get(opts, :query_fun, &ClaudeWrapper.query/2)
    {prompt, query_opts} = build(args)

    start = System.monotonic_time()
    outcome = query_fun.(prompt, query_opts)
    emit(outcome, start, args)

    classifier.(outcome)
  end

  @doc """
  Return the full schema-validated `structured_output` from a result (a
  `--json-schema` run), or `nil` when the run produced none.

  Use inside `c:ObanClaude.Worker.handle_result/2` to branch on a typed result
  object. `outcome/1` is the convenience for the common `"outcome"` key.
  """
  @spec structured(Result.t()) :: map() | list() | nil
  def structured(%Result{} = result), do: Result.structured_output(result)

  @doc """
  Read the `"outcome"` string from a result's `structured_output`, when a
  `--json-schema` run produced one. Returns `nil` otherwise.

  Useful inside `c:ObanClaude.Worker.handle_result/2` to branch on a typed
  outcome (e.g. `"done"` vs `"blocked"`).
  """
  @spec outcome(Result.t()) :: String.t() | nil
  def outcome(%Result{} = result) do
    case structured(result) do
      %{"outcome" => o} when is_binary(o) -> o
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # private
  # ---------------------------------------------------------------------------

  defp build(args) do
    prompt = Map.fetch!(args, "prompt")

    query_opts =
      for key <- @passthrough, Map.has_key?(args, key) do
        {Map.fetch!(@passthrough_atoms, key), coerce(key, args[key])}
      end

    {prompt, query_opts}
  end

  # JSON args carry strings; map the atom-valued ones through their allowlist.
  defp coerce("permission_mode", value) when is_binary(value),
    do: from_allowlist("permission_mode", @permission_modes, value)

  defp coerce("effort", value) when is_binary(value),
    do: from_allowlist("effort", @efforts, value)

  defp coerce(_key, value), do: value

  defp from_allowlist(key, allowlist, value) do
    case Map.fetch(allowlist, value) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError,
              "unknown #{key} #{inspect(value)}; " <>
                "expected one of #{inspect(Map.keys(allowlist))}"
    end
  end

  defp emit({:ok, %Result{} = r}, start, args) do
    :telemetry.execute(
      [:oban_claude, :run, :stop],
      %{duration: System.monotonic_time() - start, cost_usd: r.cost_usd || 0.0},
      %{result: r, args: args}
    )
  end

  defp emit({:error, %Error{} = e}, start, args) do
    :telemetry.execute(
      [:oban_claude, :run, :exception],
      %{duration: System.monotonic_time() - start},
      %{error: e, args: args}
    )
  end

  # Telemetry must never crash the run: ignore anything off the typed contract.
  defp emit(_outcome, _start, _args), do: :ok
end
