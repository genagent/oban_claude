defmodule ObanClaude.Args do
  # The single source of truth for the builder's vocabulary: this schema both
  # validates `new/1` and generates the "## Options" table in the moduledoc
  # below. Every claude option is a batch-job-relevant subset of
  # `ClaudeWrapper.Query`. Keep those superset-consistent with `ObanClaude`'s
  # `@passthrough`, or a key the constructor emits would be silently dropped when
  # `run/2` builds query opts (the round-trip test guards this). `:meta` is the
  # one non-claude option: an arbitrary metadata map merged into the result.
  @schema [
    prompt: [
      type: :string,
      required: true,
      doc: "The claude prompt. The only required option for `new/1`."
    ],
    model: [type: :string, doc: "Model name, e.g. `\"sonnet\"` or `\"opus\"`."],
    fallback_model: [type: :string, doc: "Model to fall back to if the primary is unavailable."],
    working_dir: [type: :string, doc: "Directory claude runs in."],
    add_dir: [type: {:list, :string}, doc: "Extra directories claude may access."],
    system_prompt: [type: :string, doc: "Replace claude's system prompt."],
    append_system_prompt: [type: :string, doc: "Append to claude's system prompt."],
    permission_mode: [
      type: {:in, [:default, :accept_edits, :bypass_permissions, :dont_ask, :plan, :auto]},
      doc: "How claude handles tool-permission prompts."
    ],
    allowed_tools: [type: {:list, :string}, doc: "Whitelist of tools claude may use."],
    disallowed_tools: [type: {:list, :string}, doc: "Blacklist of tools claude may not use."],
    mcp_config: [type: {:list, :string}, doc: "MCP server config file paths."],
    agent: [type: :string, doc: "Named agent/subagent to run as."],
    effort: [
      type: {:in, [:low, :medium, :high, :xhigh, :max]},
      doc: "Reasoning effort level."
    ],
    max_turns: [type: :pos_integer, doc: "Cap on agent turns in the run."],
    max_budget_usd: [type: {:or, [:float, :integer]}, doc: "Cost ceiling for the run, in USD."],
    timeout: [type: :pos_integer, doc: "Subprocess timeout in milliseconds."],
    json_schema: [type: :string, doc: "A JSON schema string for structured output."],
    worktree: [
      type: {:or, [:boolean, :string]},
      doc:
        "Run in a git worktree (`--worktree`). `true` for an ephemeral worktree, " <>
          "a string for a named one (reusable across jobs -- e.g. `\"issue-173\"`). " <>
          "Requires `working_dir` to be a git repo. Recommended for full-auto workers " <>
          "that write to a repo -- set it in `defaults/1`."
    ],
    hermetic: [
      type: {:in, [:full, :project]},
      doc:
        "Seal the ambient `~/.claude` config so the run's surface is exactly what " <>
          "these args set (`--setting-sources`, `--strict-mcp-config`, " <>
          "`--exclude-dynamic-system-prompt-sections`; auth untouched). `:full` drops " <>
          "user + project + local ambient config; `:project` seals project + local but " <>
          "keeps the user's global `~/.claude`. Recommended in `defaults/1` for " <>
          "reproducible server runs that should not depend on the host's config."
    ],
    meta: [
      type: {:map, {:or, [:atom, :string]}, :any},
      doc:
        "Non-claude metadata merged into the args map untouched (keys stringified). " <>
          "For values `handle_result/2` or telemetry needs -- an issue number, a " <>
          "correlation id. Explicit claude options win on a key collision."
    ]
  ]

  @options_schema NimbleOptions.new!(@schema)

  # Same vocabulary as `@schema` but with `:prompt` optional -- for `defaults/1`,
  # which builds worker-level `:args` (the prompt-less case).
  @defaults_schema @schema
                   |> Keyword.update!(:prompt, &Keyword.delete(&1, :required))
                   |> NimbleOptions.new!()

  @moduledoc """
  Build a claude job's args map without knowing `claude_wrapper` or the CLI.

  `new/1` is the first-class front door: a keyword list with atom keys and native
  Elixir values in, the string-keyed JSON map Oban stores out. It is the
  preferred way to construct args; `ObanClaude.run/2` and `ObanClaude.Worker`
  still accept a raw string-keyed map directly as the low-level escape hatch.

      ObanClaude.Args.new(prompt: "summarize the repo",
                          working_dir: "/repo",
                          permission_mode: :plan)
      #=> %{"prompt" => "summarize the repo",
      #     "working_dir" => "/repo",
      #     "permission_mode" => "plan"}

  The result is a plain map, so it drops straight into a worker:

      MyApp.ClaudeJob.new(ObanClaude.Args.new(prompt: "...")) |> Oban.insert()

  ## Worker defaults

  `defaults/1` is the same builder with `:prompt` optional, for the worker's
  `:args` (the constant, prompt-less config). It evaluates at compile time, so it
  works directly in the `use`:

      use ObanClaude.Worker,
        queue: :claude,
        args: ObanClaude.Args.defaults(working_dir: ".", model: "sonnet",
                                       permission_mode: :bypass_permissions)

  ## Job metadata

  The `:meta` option carries non-claude values (an issue number, a correlation id)
  through to the Oban job args, where `handle_result/2` and telemetry can read
  them. It is merged untouched (keys stringified) and is not validated as a claude
  option:

      ObanClaude.Args.new(prompt: "...", meta: %{"issue" => "173"})
      #=> %{"prompt" => "...", "issue" => "173"}

  ## Validation

  Unlike the raw-map path (which forwards known keys and silently ignores the
  rest), the builder validates against the schema below: unknown keys raise, and
  each option's type (including the `:permission_mode` and `:effort` vocabularies)
  is checked. Errors surface at construction / enqueue time rather than when the
  job runs.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """

  @doc """
  Build a string-keyed args map from a keyword list of atom-keyed options.

  Validates `opts` against the schema documented above (see "Options"). Raises
  `NimbleOptions.ValidationError` on a missing `:prompt`, an unknown key, or a
  value of the wrong type. Returns the map Oban serializes as the job's args.
  """
  @spec new(keyword) :: %{required(String.t()) => term()}
  def new(opts) when is_list(opts) do
    opts |> NimbleOptions.validate!(@options_schema) |> to_map()
  end

  @doc """
  Build a worker-level defaults map: the same as `new/1`, but `:prompt` is
  optional (worker `:args` are the prompt-less config the per-job args fill in).

  Because it evaluates at compile time, it can be used directly in the worker's
  `use` (see "Worker defaults" above).
  """
  @spec defaults(keyword) :: %{optional(String.t()) => term()}
  def defaults(opts \\ []) when is_list(opts) do
    opts |> NimbleOptions.validate!(@defaults_schema) |> to_map()
  end

  @doc "The options the builder accepts."
  @spec keys() :: [atom()]
  def keys, do: Keyword.keys(@schema)

  # Validated opts -> the string-keyed map. `:meta` is pulled out and merged
  # (stringified) rather than emitted as a claude arg; explicit claude options
  # overlay it, so they win on a key collision.
  defp to_map(opts) do
    {meta, opts} = Keyword.pop(opts, :meta, %{})
    base = Map.new(opts, fn {key, value} -> {Atom.to_string(key), serialize(value)} end)
    Map.merge(stringify_keys(meta), base)
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # Enum options carry atoms; serialize to the JSON string wire form (`ObanClaude`
  # coerces them back to atoms when it builds the query opts). Everything else
  # (strings, numbers, lists of strings) is already JSON-clean.
  defp serialize(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp serialize(value), do: value
end
