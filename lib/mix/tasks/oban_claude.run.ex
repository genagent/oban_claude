defmodule Mix.Tasks.ObanClaude.Run do
  @shortdoc "Fire a single claude run from the CLI (no queue, no database)."

  @moduledoc """
  #{@shortdoc}

  The engine-level, one-shot counterpart to the Oban queue: CLI flags parse into
  the same `ObanClaude.Args.new/1` vocabulary, run through `ObanClaude.run/2`, and
  the `{oban_return, result}` verdict is printed. No Oban, no repo, no app
  supervision -- just one claude call.

  ## Examples

      mix oban_claude.run "summarize the repo" --working-dir . --permission-mode plan
      mix oban_claude.run "review this" --model sonnet --allowed-tools Read --allowed-tools Grep
      mix oban_claude.run "extract the facts" --json-schema priv/schema.json --json

  This makes a real (billable) claude call and uses the `claude` CLI's own
  authentication.

  ## Options

  Every flag maps to an `ObanClaude.Args.new/1` option. The prompt is the first
  positional argument (or `--prompt`).

    * `--model`, `--fallback-model`, `--agent` -- strings
    * `--working-dir`, `--system-prompt`, `--append-system-prompt` -- strings
    * `--permission-mode` -- one of `default`, `accept_edits`, `bypass_permissions`,
      `dont_ask`, `plan`, `auto`
    * `--effort` -- one of `low`, `medium`, `high`, `xhigh`, `max`
    * `--max-turns`, `--timeout` -- integers
    * `--max-budget-usd` -- float
    * `--worktree` -- `true`/`false` for an ephemeral worktree, or a name for a
      named one (e.g. `--worktree issue-42`). Needs `--working-dir` to be a git repo.
    * `--hermetic` -- `full` or `project` (or `true`, an alias for `full`): seal
      the ambient `~/.claude` config for a reproducible run
    * `--json-schema` -- path/string for a structured-output run
    * `--add-dir`, `--allowed-tools`, `--disallowed-tools`, `--mcp-config` --
      repeatable (pass the flag once per value)

  Short aliases: `-m` (`--model`), `-w` (`--working-dir`), `-p` (`--permission-mode`).
  There is no `--meta` flag -- job metadata is an Oban-queue concern, not a
  one-shot CLI one.

  Output and exit status:

    * `--json` -- print a machine-readable JSON summary (a structured `verdict`
      plus result/error fields) instead of text.
    * The task exits non-zero when the run's verdict is `{:error, _}` or
      `{:cancel, _}`, so `mix oban_claude.run ... || handle_failure` works.
  """

  use Mix.Task

  # CLI switch -> OptionParser type. The list-valued ones use `:keep` so the flag
  # can be repeated; enum/number values are coerced in build_args/1.
  @switches [
    prompt: :string,
    model: :string,
    fallback_model: :string,
    working_dir: :string,
    system_prompt: :string,
    append_system_prompt: :string,
    agent: :string,
    permission_mode: :string,
    effort: :string,
    json_schema: :string,
    max_turns: :integer,
    timeout: :integer,
    max_budget_usd: :float,
    worktree: :string,
    hermetic: :string,
    add_dir: [:string, :keep],
    allowed_tools: [:string, :keep],
    disallowed_tools: [:string, :keep],
    mcp_config: [:string, :keep],
    json: :boolean
  ]

  @aliases [m: :model, w: :working_dir, p: :permission_mode]

  @list_keys [:add_dir, :allowed_tools, :disallowed_tools, :mcp_config]
  @atom_keys [:permission_mode, :effort, :hermetic]

  @impl Mix.Task
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:claude_wrapper)
    {json?, args} = build(argv)
    outcome = ObanClaude.run(args)
    outcome |> render(json?) |> emit(outcome, json?)
    unless success?(outcome), do: exit({:shutdown, 1})
  end

  @doc """
  Parse `argv` into a validated string-keyed args map (via `ObanClaude.Args.new/1`).

  Separated from `run/1` so the flag parsing and vocabulary mapping are testable
  without a claude call. Raises on an unknown flag, a bad value, or a missing
  prompt.
  """
  @spec build_args([String.t()]) :: %{required(String.t()) => term()}
  def build_args(argv) do
    {_json?, args} = build(argv)
    args
  end

  # ---------------------------------------------------------------------------
  # private
  # ---------------------------------------------------------------------------

  defp build(argv) do
    {parsed, positional, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    unless invalid == [] do
      Mix.raise("unknown or malformed option(s): #{format_invalid(invalid)}")
    end

    {json?, opts} = Keyword.pop(parsed, :json, false)

    args_kw =
      opts
      |> put_prompt(positional)
      |> group_lists()
      |> coerce_atoms()
      |> coerce_worktree()

    {json?, build_validated(args_kw)}
  end

  # `Args.new/1` raises a `NimbleOptions.ValidationError` whose useful line is
  # buried in an exception dump; surface just the message as a clean Mix error.
  defp build_validated(args_kw) do
    ObanClaude.Args.new(args_kw)
  rescue
    e in NimbleOptions.ValidationError -> Mix.raise(Exception.message(e))
  end

  # The prompt is `--prompt` or the single positional argument. Reject the
  # ambiguous cases loudly rather than fire a paid run on the wrong prompt: extra
  # positionals usually mean a forgotten shell quote.
  defp put_prompt(opts, positional) do
    case {Keyword.has_key?(opts, :prompt), positional} do
      {true, []} ->
        opts

      {true, _} ->
        Mix.raise("--prompt given together with positional argument(s); pass the prompt once")

      {false, [prompt]} ->
        Keyword.put(opts, :prompt, prompt)

      {false, []} ->
        opts

      {false, _many} ->
        Mix.raise(
          "multiple positional arguments; did you forget to quote the prompt? " <>
            ~s(e.g. mix oban_claude.run "summarize the recent changes")
        )
    end
  end

  # `:keep` switches arrive as repeated `{key, value}` pairs; fold each list key's
  # values into a single list so it matches the builder's `{:list, :string}` type.
  defp group_lists(opts) do
    {lists, scalars} = Keyword.split(opts, @list_keys)

    grouped =
      for key <- @list_keys, values = Keyword.get_values(lists, key), values != [] do
        {key, values}
      end

    scalars ++ grouped
  end

  # permission_mode / effort / hermetic are enums the builder expects as atoms.
  # Use `to_existing_atom` (the valid values are compile-time atoms) so arbitrary
  # CLI input cannot grow the atom table; an unknown value gets a clean error
  # rather than a raw ArgumentError. `Args.new/1` still validates the vocabulary.
  defp coerce_atoms(opts) do
    Enum.map(opts, fn
      {key, value} when key in @atom_keys and is_binary(value) -> {key, to_enum_atom!(key, value)}
      pair -> pair
    end)
  end

  defp to_enum_atom!(key, value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError ->
      Mix.raise("invalid --#{String.replace(to_string(key), "_", "-")} value #{inspect(value)}")
  end

  # `--worktree` is boolean-or-string: "true"/"false" become the booleans (an
  # ephemeral worktree / none), any other value is a named worktree.
  defp coerce_worktree(opts) do
    case Keyword.fetch(opts, :worktree) do
      {:ok, "true"} -> Keyword.put(opts, :worktree, true)
      {:ok, "false"} -> Keyword.put(opts, :worktree, false)
      _ -> opts
    end
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn
      {flag, nil} -> flag
      {flag, value} -> "#{flag}=#{value}"
    end)
  end

  # ---------------------------------------------------------------------------
  # output
  # ---------------------------------------------------------------------------

  # Write the rendered output, then run/1 sets the exit status. JSON always goes
  # to stdout (scripts pipe it); a text-mode failure goes to stderr.
  defp emit(text, outcome, json?) do
    if json? or success?(outcome), do: Mix.shell().info(text), else: Mix.shell().error(text)
  end

  defp success?({:ok, _payload}), do: true
  defp success?({{:ok, _}, _payload}), do: true
  defp success?(_), do: false

  @doc false
  # Render a run outcome to a printable string. A `@doc false` seam so the output
  # layer (JSON + text, every payload shape) is testable without a paid run.
  @spec render({ObanClaude.oban_return(), term()}, boolean()) :: String.t()
  def render({oban_return, %ClaudeWrapper.Result{} = result}, true) do
    oban_return
    |> verdict_json()
    |> Map.merge(%{
      result: result.result,
      cost_usd: result.cost_usd,
      session_id: result.session_id,
      duration_ms: result.duration_ms,
      num_turns: result.num_turns,
      structured: ObanClaude.structured(result)
    })
    |> encode_json()
  end

  def render({oban_return, %ClaudeWrapper.Error{} = error}, true) do
    oban_return
    |> verdict_json()
    |> Map.merge(%{error_kind: error.kind, error_reason: reason_string(error.reason)})
    |> encode_json()
  end

  def render({oban_return, %ClaudeWrapper.Result{} = result}, false) do
    meta =
      [
        cost: result.cost_usd && "$#{result.cost_usd}",
        turns: result.num_turns,
        duration_ms: result.duration_ms,
        session: result.session_id
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{v}" end)

    structured =
      case ObanClaude.structured(result) do
        nil -> ""
        s -> "\n\nstructured:\n" <> encode_json(s)
      end

    "verdict: #{inspect(oban_return)}\n\n#{result.result}" <>
      if(meta != "", do: "\n\n" <> meta, else: "") <> structured
  end

  def render({oban_return, %ClaudeWrapper.Error{} = error}, false) do
    "verdict: #{inspect(oban_return)}\nerror [#{error.kind}]: #{reason_string(error.reason)}"
  end

  # Defensive: a payload that is neither Result nor Error (reachable only via a
  # classifier contract violation) still renders instead of raising.
  def render({oban_return, payload}, _json?) do
    "verdict: #{inspect(oban_return)}\n#{inspect(payload)}"
  end

  # A structured verdict for --json consumers, instead of an Elixir tuple string.
  defp verdict_json(:ok), do: %{verdict: "ok"}
  defp verdict_json({:ok, _}), do: %{verdict: "ok"}
  defp verdict_json({:error, reason}), do: %{verdict: "error", reason: reason_string(reason)}
  defp verdict_json({:cancel, reason}), do: %{verdict: "cancel", reason: reason_string(reason)}
  defp verdict_json({:snooze, n}), do: %{verdict: "snooze", snooze: n}

  defp reason_string(reason) when is_atom(reason), do: to_string(reason)
  defp reason_string(reason), do: inspect(reason)

  # OTP's built-in JSON encoder (OTP 27+); no dependency needed. Normalize first
  # because the encoder maps only the atom `:null` to JSON `null` -- an Elixir
  # `nil` would otherwise encode as the string "nil".
  defp encode_json(term), do: term |> json_normalize() |> :json.encode() |> IO.iodata_to_binary()

  defp json_normalize(nil), do: :null

  defp json_normalize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, json_normalize(v)} end)

  defp json_normalize(list) when is_list(list), do: Enum.map(list, &json_normalize/1)
  defp json_normalize(other), do: other
end
