defmodule ObanClaude.Args do
  # The single source of truth for the builder's vocabulary: this schema both
  # validates `new/1` and generates the "## Options" table in the moduledoc
  # below. Every option is a batch-job-relevant subset of `ClaudeWrapper.Query`.
  # Keep it superset-consistent with `ObanClaude`'s `@passthrough`, or a key the
  # constructor emits would be silently dropped when `run/2` builds query opts
  # (the round-trip test in test/oban_claude/args_test.exs guards this).
  @schema [
    prompt: [
      type: :string,
      required: true,
      doc: "The claude prompt. The only required option."
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
    json_schema: [type: :string, doc: "A JSON schema string for structured output."]
  ]

  @options_schema NimbleOptions.new!(@schema)

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

  Unlike the raw-map path (which forwards known keys and silently ignores the
  rest), `new/1` validates against the schema below: `:prompt` is required, an
  unknown key raises, and each option's type (including the `:permission_mode`
  and `:effort` vocabularies) is checked. Errors surface at construction /
  enqueue time rather than when the job runs.

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
    opts
    |> NimbleOptions.validate!(@options_schema)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), serialize(value)} end)
  end

  @doc "The options `new/1` accepts."
  @spec keys() :: [atom()]
  def keys, do: Keyword.keys(@schema)

  # Enum options carry atoms; serialize to the JSON string wire form (`ObanClaude`
  # coerces them back to atoms when it builds the query opts). Everything else
  # (strings, numbers, lists of strings) is already JSON-clean.
  defp serialize(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp serialize(value), do: value
end
