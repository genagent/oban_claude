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
    * `--json-schema` -- path/string for a structured-output run
    * `--add-dir`, `--allowed-tools`, `--disallowed-tools`, `--mcp-config` --
      repeatable (pass the flag once per value)

  Output flag:

    * `--json` -- print a machine-readable JSON summary instead of text
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
    add_dir: [:string, :keep],
    allowed_tools: [:string, :keep],
    disallowed_tools: [:string, :keep],
    mcp_config: [:string, :keep],
    json: :boolean
  ]

  @aliases [m: :model, w: :working_dir, p: :permission_mode]

  @list_keys [:add_dir, :allowed_tools, :disallowed_tools, :mcp_config]
  @atom_keys [:permission_mode, :effort]

  @impl Mix.Task
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:claude_wrapper)
    {json?, args} = build(argv)
    args |> ObanClaude.run() |> print(json?)
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

    {json?, ObanClaude.Args.new(args_kw)}
  end

  # The prompt is `--prompt` or the first positional argument.
  defp put_prompt(opts, positional) do
    case {opts[:prompt], positional} do
      {nil, [prompt | _]} -> Keyword.put(opts, :prompt, prompt)
      _ -> opts
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

  # permission_mode / effort are enums the builder expects as atoms.
  defp coerce_atoms(opts) do
    Enum.map(opts, fn
      {key, value} when key in @atom_keys and is_binary(value) -> {key, String.to_atom(value)}
      pair -> pair
    end)
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

  defp print({oban_return, %ClaudeWrapper.Result{} = result}, true) do
    %{
      verdict: inspect(oban_return),
      result: result.result,
      cost_usd: result.cost_usd,
      session_id: result.session_id,
      duration_ms: result.duration_ms,
      num_turns: result.num_turns,
      structured: ObanClaude.structured(result)
    }
    |> encode_json()
    |> Mix.shell().info()
  end

  defp print({oban_return, %ClaudeWrapper.Error{} = error}, true) do
    %{verdict: inspect(oban_return), error_kind: error.kind, reason: inspect(error.reason)}
    |> encode_json()
    |> Mix.shell().info()
  end

  defp print({oban_return, %ClaudeWrapper.Result{} = result}, false) do
    shell = Mix.shell()
    shell.info("verdict: #{inspect(oban_return)}")
    shell.info("")
    shell.info(result.result || "")

    meta =
      [
        cost: result.cost_usd && "$#{result.cost_usd}",
        turns: result.num_turns,
        duration_ms: result.duration_ms,
        session: result.session_id
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{v}" end)

    if meta != "", do: shell.info("\n" <> meta)

    case ObanClaude.structured(result) do
      nil -> :ok
      structured -> shell.info("\nstructured:\n" <> encode_json(structured))
    end
  end

  defp print({oban_return, %ClaudeWrapper.Error{} = error}, false) do
    shell = Mix.shell()
    shell.info("verdict: #{inspect(oban_return)}")
    shell.error("error [#{error.kind}]: #{inspect(error.reason)}")
  end

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
