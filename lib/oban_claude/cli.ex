defmodule ObanClaude.CLI do
  @moduledoc false
  # Shared core for the `mix oban_claude` command tree (see `Mix.Tasks.ObanClaude`
  # and the `ObanClaude.CLI.*` command modules). Holds:
  #
  #   * `claude_options/0` -- a macro emitting the argument/option declarations
  #     shared by the `run` and `args` commands (one prompt + the ObanClaude.Args
  #     vocabulary), so the two stay in lockstep from a single definition;
  #   * `to_args/1` -- cheer's parsed map -> the validated `ObanClaude.Args`
  #     string map (the single validation source of truth stays `Args.new/1`);
  #   * `render/2` + `emit/2` -- the output layer, text and `--json`.
  #
  # Kept out of the command modules (and public-but-`@doc false`) so the parsing
  # and rendering are unit-testable without a paid claude call.

  # Enum flags the builder wants as atoms; cheer validates the vocabulary via
  # `:choices`, then we coerce the chosen string to its atom with
  # `to_existing_atom` (safe: choices guarantee a compile-time atom).
  @enum_keys [:permission_mode, :effort, :hermetic]

  # cheer control/structural keys that are not ObanClaude.Args options.
  @control_keys [:json, :rest, :prompt]

  @permission_modes ~w(default accept_edits bypass_permissions dont_ask plan auto)
  @efforts ~w(low medium high xhigh max)
  @hermetic_scopes ~w(full project true)

  @doc false
  # The prompt argument + every ObanClaude.Args claude option (minus :meta, an
  # Oban-queue concern). Expanded inside a `command do ... end` block by the `run`
  # and `args` commands. `:choices` on the enums gives clean usage errors and
  # shell completion; `Args.new/1` re-validates as defense in depth.
  defmacro claude_options do
    quote do
      argument(:prompt, type: :string, required: true, help: "The claude prompt.")

      option(:model, type: :string, short: :m, help: ~S|Model name, e.g. "sonnet".|)
      option(:fallback_model, type: :string, help: "Model to fall back to.")
      option(:working_dir, type: :string, short: :w, help: "Directory claude runs in.")
      option(:binary, type: :string, help: "Path to the claude CLI binary (version pinning).")
      option(:system_prompt, type: :string, help: "Replace claude's system prompt.")
      option(:append_system_prompt, type: :string, help: "Append to claude's system prompt.")
      option(:agent, type: :string, help: "Named agent/subagent to run as.")

      option(:permission_mode,
        type: :string,
        short: :p,
        choices: unquote(@permission_modes),
        help: "How claude handles tool-permission prompts."
      )

      option(:effort, type: :string, choices: unquote(@efforts), help: "Reasoning effort level.")

      option(:max_turns, type: :integer, help: "Cap on agent turns.")
      option(:timeout, type: :integer, help: "Subprocess timeout in milliseconds.")
      option(:max_budget_usd, type: :float, help: "Cost ceiling for the run, in USD.")

      option(:json_schema,
        type: :string,
        help: ~S|Inline JSON Schema string for structured output (not a file path).|
      )

      option(:worktree,
        type: :string,
        help: ~S|Git worktree: "true"/"false", or a name (e.g. issue-42) for a reusable one.|
      )

      option(:hermetic,
        type: :string,
        choices: unquote(@hermetic_scopes),
        help: ~S|Seal ambient config: "full", "project", or "true" (alias for full).|
      )

      option(:add_dir, type: :string, multi: true, help: "Extra accessible dir (repeatable).")
      option(:allowed_tools, type: :string, multi: true, help: "Allowed tool (repeatable).")
      option(:disallowed_tools, type: :string, multi: true, help: "Disallowed tool (repeatable).")
      option(:mcp_config, type: :string, multi: true, help: "MCP config file path (repeatable).")

      option(:resume, type: :string, help: "Resume a prior claude session by id (--resume).")
      option(:session_id, type: :string, help: "Pin the session id (--session-id).")

      option(:no_session_persistence,
        type: :boolean,
        help: "Do not persist the session transcript."
      )

      option(:fork_session, type: :boolean, help: "Fork a new session from the resumed one.")
    end
  end

  @doc false
  # cheer's parsed map -> the validated ObanClaude.Args string map. Drops cheer
  # control keys and absent/empty values, coerces the enum + worktree flags, then
  # hands the rest to `Args.new/1` (the authoritative validator). The prompt is
  # threaded back in by the caller (it is a positional argument, not an option).
  @spec to_args(map()) :: ObanClaude.Args.t()
  def to_args(parsed) do
    prompt = Map.get(parsed, :prompt)

    opts =
      parsed
      |> Map.drop(@control_keys)
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
      |> Enum.map(&coerce/1)

    opts = if prompt, do: [{:prompt, prompt} | opts], else: opts

    build_validated(opts)
  end

  # `Args.new/1` raises a NimbleOptions.ValidationError whose useful line is
  # buried in an exception dump; surface just the message as a clean Mix error.
  defp build_validated(opts) do
    ObanClaude.Args.new(opts)
  rescue
    e in NimbleOptions.ValidationError -> Mix.raise(Exception.message(e))
  end

  defp coerce({key, value}) when key in @enum_keys and is_binary(value),
    do: {key, to_enum_atom!(key, value)}

  # `--worktree` is boolean-or-string: the words become the booleans (ephemeral /
  # none), any other value is a named worktree.
  defp coerce({:worktree, "true"}), do: {:worktree, true}
  defp coerce({:worktree, "false"}), do: {:worktree, false}
  defp coerce(pair), do: pair

  defp to_enum_atom!(key, value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError ->
      Mix.raise("invalid --#{String.replace(to_string(key), "_", "-")} value #{inspect(value)}")
  end

  # ---------------------------------------------------------------------------
  # output
  # ---------------------------------------------------------------------------

  @doc false
  # Render + write a run outcome, returning whether it succeeded (the caller maps
  # that to the process exit code). JSON always goes to stdout (scripts pipe it);
  # a text-mode failure goes to stderr.
  @spec emit({ObanClaude.oban_return(), term()}, boolean()) :: boolean()
  def emit(outcome, json?) do
    text = render(outcome, json?)
    ok? = success?(outcome)
    if json? or ok?, do: Mix.shell().info(text), else: Mix.shell().error(text)
    ok?
  end

  @doc false
  @spec success?({ObanClaude.oban_return(), term()}) :: boolean()
  def success?({:ok, _payload}), do: true
  def success?({{:ok, _}, _payload}), do: true
  def success?(_), do: false

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

  @doc false
  # OTP's built-in JSON encoder (OTP 27+); no dependency needed. Normalize first
  # because the encoder maps only the atom `:null` to JSON `null` -- an Elixir
  # `nil` would otherwise encode as the string "nil".
  @spec encode_json(term()) :: String.t()
  def encode_json(term), do: term |> json_normalize() |> :json.encode() |> IO.iodata_to_binary()

  defp json_normalize(nil), do: :null

  defp json_normalize(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, json_normalize(v)} end)

  defp json_normalize(list) when is_list(list), do: Enum.map(list, &json_normalize/1)
  defp json_normalize(other), do: other
end
