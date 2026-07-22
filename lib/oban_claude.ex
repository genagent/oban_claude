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
      * `:job` -- a slim map `%{id, queue, worker, attempt, max_attempts, meta}`
        for the `Oban.Job`, or `nil` when `run/2` was called without `:job`

  ### `[:oban_claude, :run, :exception]`

  Emitted when the query returns `{:error, _}` -- both a typed
  `%ClaudeWrapper.Error{}` and an off-contract error term (which the classifier
  cancels, so it still surfaces here).

    * Measurements:
      * `:duration` -- wall time of the query in native time units
      * `:cost_usd` -- the run's spend when the error carries one (a rail-stop
        `:max_budget_exceeded` / `:max_turns_exceeded` reason map does; `0.0`
        otherwise, including every off-contract term). Summing `:cost_usd` across
        *both* events gives a complete spend total.
    * Metadata:
      * `:error` -- the `%ClaudeWrapper.Error{}` struct, or the raw error term on
        the off-contract path
      * `:args` -- the string-keyed args map passed to `run/2`
      * `:job` -- as above

  > #### Data handling {: .warning}
  >
  > `:args` (prompt, system prompt, `:meta`), `:result`, and `:error` (which can
  > embed raw CLI stdout/stderr) all ride on these events. Redact before shipping
  > telemetry to a log aggregator.
  """

  alias ClaudeWrapper.{Error, Result}

  @typedoc """
  An `c:Oban.Worker.perform/1` return value. `:snooze` accepts Oban's full
  `t:Oban.Period.t/0` -- a `pos_integer` of seconds or a `{n, unit}` tuple. The
  default classifier (`ObanClaude.Outcome`) never returns `:snooze` (it would
  bypass `max_attempts`); a `:classifier` override may.
  """
  @type oban_return ::
          :ok | {:ok, term} | {:error, term} | {:cancel, term} | {:snooze, Oban.Period.t()}

  @typedoc """
  What `ClaudeWrapper.query/2` (or a custom `:query_fun`) returns: a typed
  `%Result{}`, or a typed `%Error{}` (an arbitrary `term()` only off the
  documented contract).
  """
  @type wrapper_outcome :: {:ok, Result.t()} | {:error, Error.t() | term()}

  @typedoc """
  Maps a `t:wrapper_outcome/0` onto the `{oban_return, payload}` envelope. The
  first element MUST be a valid `t:oban_return/0`; `run/2` raises otherwise. A
  common mistake is a flat `{:cancel, reason}` -- that is a bare verdict, not
  the `{verdict, payload}` envelope the `ObanClaude.Worker` path unwraps.
  """
  @type classifier :: (wrapper_outcome() -> {oban_return(), term()})

  @typedoc "The claude entrypoint: `(prompt, query_opts) -> t:wrapper_outcome/0`."
  @type query_fun :: (String.t(), keyword() -> wrapper_outcome())

  # Args-map keys passed straight through to `ClaudeWrapper.query/2`. Kept a
  # superset of `ObanClaude.Args`'s curated keys, or a key the constructor emits
  # would be silently dropped when `build/1` assembles the query opts.
  #
  # `binary` (a claude CLI path) rides through for per-worker version pinning.
  # The session keys (`resume`, `session_id`, `no_session_persistence`,
  # `fork_session`) enable the resume-after-rail-stop recipe (read the
  # `session_id` off the rail-stop `%Error{}` in `handle_error/3`, then enqueue a
  # follow-on job with `resume:` + the same named worktree). All are JSON-clean
  # strings/booleans, so they need no coercion. `continue_session` is
  # deliberately excluded: `--continue` resumes the host's *most recent* session,
  # which cross-contaminates under concurrent workers; use explicit `resume:`.
  # The `*_file` / `permission_prompt_tool` / `max_thinking_tokens` keys are the
  # one-shot query flags claude_wrapper 0.14.0 exposed: prompt-from-file (dodges
  # ARG_MAX on a large system prompt), a custom permission-gating MCP tool, and a
  # thinking-token cap. All JSON-clean strings/ints, so no coercion.
  # The sibling wrapper key `:env` is deliberately NOT surfaced: env vars in the
  # args map would sit plaintext in the oban_jobs table (a secrets-at-rest
  # hazard) -- resolve env inside the run instead.
  @passthrough ~w(model max_turns max_budget_usd working_dir permission_mode timeout
                  system_prompt append_system_prompt fallback_model add_dir json_schema
                  allowed_tools disallowed_tools mcp_config effort agent worktree hermetic
                  binary resume session_id no_session_persistence fork_session
                  system_prompt_file append_system_prompt_file permission_prompt_tool
                  max_thinking_tokens)

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

  # `hermetic` is the third atom-valued key: the config-seal scope
  # (`ClaudeWrapper.Query.hermetic/2`) is `:full` or `:project`, but arrives as a
  # JSON string. Same allowlist treatment as `permission_mode` and `effort`.
  @hermetic_scopes ~w(full project) |> Map.new(&{&1, String.to_atom(&1)})

  @doc """
  Run a claude job from a string-keyed `args` map.

  Returns `{oban_return, %Result{} | %Error{}}` so a caller can both act on the
  Oban verdict and inspect the underlying run (cost, session id, structured
  output). `:prompt` is required; a curated subset of `ClaudeWrapper.query/2`
  options (the keys in the `ObanClaude.Args` options table) is forwarded, and any
  other key in the map is silently ignored.

  Options:

    * `:classifier` -- a `t:classifier/0`: a 1-arity fun mapping the claude
      call's outcome onto the `{oban_return, payload}` envelope. The first
      element is the Oban verdict; `run/2` raises `ArgumentError` if it is not a
      valid `t:oban_return/0` (guarding the flat-`{:cancel, reason}` mistake
      that Oban would otherwise silently treat as success). Defaults to
      `&ObanClaude.Outcome.classify/1`.
    * `:query_fun` -- a `t:query_fun/0`, the claude entrypoint. Defaults to
      `&ClaudeWrapper.query/2`. Override to stub claude in tests, or to route
      through a different wrapper entrypoint.
    * `:job` -- the `Oban.Job` this run belongs to. Its identity (`id`, `queue`,
      `worker`, `attempt`, `meta`) rides along in both telemetry events'
      `:job` metadata for cost attribution. `ObanClaude.Worker` passes it
      automatically; bare `run/2` callers may omit it (`:job` is then `nil`).
  """
  @spec run(
          ObanClaude.Args.t(),
          [{:classifier, classifier()} | {:query_fun, query_fun()} | {:job, Oban.Job.t()}]
        ) ::
          {oban_return(), Result.t() | Error.t() | term()}
  def run(args, opts \\ []) when is_map(args) do
    classifier = Keyword.get(opts, :classifier, &ObanClaude.Outcome.classify/1)
    query_fun = Keyword.get(opts, :query_fun, &ClaudeWrapper.query/2)
    job = Keyword.get(opts, :job)
    {prompt, query_opts} = build(args)

    start = System.monotonic_time()
    emit_start(args, job)
    outcome = query_fun.(prompt, query_opts)
    emit(outcome, start, args, job)

    outcome |> classifier.() |> validate_classified!(classifier)
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

  @doc """
  Read the claude session id from a run's payload, or `nil` if there is none.

  The handle lives in two different places depending on the outcome, and this
  reader hides that split so callers never touch `claude_wrapper` internals:

    * on a success (or `is_error` `%Result{}`), it is `result.session_id`;
    * on a rail-stop `%Error{}` (`:max_turns_exceeded` / `:max_budget_exceeded`),
      it is `error.reason.session_id`.

  Use it inside `c:ObanClaude.Worker.handle_error/3` to enqueue a `resume:` job
  after a rail stop. Any other error shape (an atom reason, a missing field)
  yields `nil`.
  """
  @spec session_id(Result.t() | Error.t() | term()) :: String.t() | nil
  def session_id(%Result{session_id: sid}), do: sid
  def session_id(%Error{reason: %{session_id: sid}}), do: sid
  def session_id(_), do: nil

  @doc """
  Read the run's cost in USD from a run's payload, or `nil` if unavailable.

  Like `session_id/1`, it hides the success-vs-rail-stop shape split:
  `result.cost_usd` on a `%Result{}`, `error.reason.cost_usd` on a rail-stop
  `%Error{}`. Use it in `c:ObanClaude.Worker.handle_error/3` to record spend
  before enqueuing a resume job.
  """
  @spec cost_usd(Result.t() | Error.t() | term()) :: float() | nil
  def cost_usd(%Result{cost_usd: cost}), do: cost
  def cost_usd(%Error{reason: %{cost_usd: cost}}), do: cost
  def cost_usd(_), do: nil

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

  defp coerce("hermetic", value) when is_binary(value),
    do: from_allowlist("hermetic", @hermetic_scopes, value)

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

  # A classifier must return the `{oban_return, payload}` envelope, its first
  # element a valid `t:oban_return/0`. Without this guard a malformed verdict
  # (classically a flat `{:cancel, reason}`, whose first element is the bare
  # atom `:cancel`) flows through `ObanClaude.Worker.perform/1` as a bare atom;
  # Oban's executor has no clause for it, logs a warning, and records the job as
  # SUCCESS -- silently marking a failed, paid run complete. Raise instead.
  defp validate_classified!(classified, classifier) do
    if valid_return?(classified) do
      classified
    else
      raise ArgumentError, """
      classifier #{inspect(classifier)} returned #{inspect(classified)}, which \
      is not the required {oban_return, payload} envelope.

      The first element must be a valid Oban verdict -- :ok, {:ok, term}, \
      {:error, term}, {:cancel, term}, or {:snooze, period}. A common mistake is \
      returning a flat verdict such as {:cancel, reason}; wrap it with the \
      payload instead: {{:cancel, reason}, error}.
      """
    end
  end

  defp valid_return?({:ok, _payload}), do: true
  defp valid_return?({{:ok, _}, _payload}), do: true
  defp valid_return?({{:error, _}, _payload}), do: true
  defp valid_return?({{:cancel, _}, _payload}), do: true
  defp valid_return?({{:snooze, n}, _payload}) when is_integer(n) and n > 0, do: true
  defp valid_return?({{:snooze, {n, _unit}}, _payload}) when is_integer(n) and n > 0, do: true
  defp valid_return?(_other), do: false

  # The span start: consumers that need state-of-the-world BEFORE the claude
  # subprocess runs (worktree tripwires, live "turn started" displays) hook
  # here; stop/exception carry the outcome as before.
  defp emit_start(args, job) do
    :telemetry.execute(
      [:oban_claude, :run, :start],
      %{system_time: System.system_time()},
      %{args: args, job: job_meta(job)}
    )
  end

  defp emit({:ok, %Result{} = r}, start, args, job) do
    :telemetry.execute(
      [:oban_claude, :run, :stop],
      %{duration: System.monotonic_time() - start, cost_usd: r.cost_usd || 0.0},
      %{result: r, args: args, job: job_meta(job)}
    )
  end

  defp emit({:error, %Error{} = e}, start, args, job) do
    :telemetry.execute(
      [:oban_claude, :run, :exception],
      %{duration: System.monotonic_time() - start, cost_usd: error_cost(e)},
      %{error: e, args: args, job: job_meta(job)}
    )
  end

  # An off-contract error term (not a typed %Error{}) still cancels the job in
  # the classifier, so it must still surface to telemetry. Emit :exception with
  # the raw term as `:error` (measurements carry no cost -- there is no typed
  # result to read one from).
  defp emit({:error, other}, start, args, job) do
    :telemetry.execute(
      [:oban_claude, :run, :exception],
      %{duration: System.monotonic_time() - start, cost_usd: 0.0},
      %{error: other, args: args, job: job_meta(job)}
    )
  end

  # Telemetry must never crash the run: ignore anything else off the typed contract.
  defp emit(_outcome, _start, _args, _job), do: :ok

  # A slim, cost-attribution-oriented view of the job for telemetry metadata.
  # `nil` for bare `run/2` callers that pass no `:job`.
  defp job_meta(%Oban.Job{} = job) do
    %{
      id: job.id,
      queue: job.queue,
      worker: job.worker,
      attempt: job.attempt,
      max_attempts: job.max_attempts,
      meta: job.meta
    }
  end

  defp job_meta(_), do: nil

  # Rail-stop errors (`:max_budget_exceeded` / `:max_turns_exceeded`) carry the
  # run's real spend in their reason map -- surface it so a dashboard summing
  # `:stop` cost_usd does not undercount by exactly the capped (priciest) runs.
  defp error_cost(%Error{reason: %{cost_usd: c}}) when is_number(c), do: c
  defp error_cost(_), do: 0.0
end
