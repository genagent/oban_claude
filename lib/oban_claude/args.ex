defmodule ObanClaude.Args do
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
  rest), `new/1` validates: `:prompt` is required, an unknown key raises, and the
  two atom-valued enums (`:permission_mode`, `:effort`) are checked against their
  vocabulary. Errors surface at construction / enqueue time rather than when the
  job runs.
  """

  # The curated vocabulary: atom keys the caller may pass, each a subset of
  # `ClaudeWrapper.Query`'s fields chosen as batch-job-relevant. `:prompt` is
  # required and handled separately; the rest are optional passthroughs. This set
  # must stay a superset-consistent match with `ObanClaude`'s `@passthrough`, or a
  # key emitted here would be silently dropped when `run/2` builds query opts.
  @string_keys ~w(prompt model working_dir system_prompt append_system_prompt
                  fallback_model json_schema agent)a
  @number_keys ~w(max_turns max_budget_usd timeout)a
  @list_keys ~w(add_dir allowed_tools disallowed_tools mcp_config)a
  @enum_keys ~w(permission_mode effort)a

  @keys @string_keys ++ @number_keys ++ @list_keys ++ @enum_keys

  # Atom-valued enums, validated here so a bad value fails at enqueue rather than
  # perform. Kept in sync with `ClaudeWrapper.Query`'s `permission_mode`/`effort`
  # types and with `ObanClaude`'s coerce allowlists (which map them back on run).
  @permission_modes ~w(default accept_edits bypass_permissions dont_ask plan auto)a
  @efforts ~w(low medium high xhigh max)a

  @enum_vocab %{permission_mode: @permission_modes, effort: @efforts}

  @doc """
  Build a string-keyed args map from a keyword list of atom-keyed options.

  `:prompt` (a string) is required. Every other key is optional and must be one of
  the curated keys; an unknown key raises `ArgumentError`. `:permission_mode` and
  `:effort` accept an atom from their vocabulary and raise on anything else.

  Returns the map Oban serializes as the job's args.
  """
  @spec new(keyword) :: %{required(String.t()) => term()}
  def new(opts) when is_list(opts) do
    validate_keys!(opts)
    validate_prompt!(opts)
    Enum.each(@enum_keys, &validate_enum!(opts, &1))

    Map.new(opts, fn {key, value} -> {Atom.to_string(key), serialize(key, value)} end)
  end

  @doc "The curated keys `new/1` accepts."
  @spec keys() :: [atom()]
  def keys, do: @keys

  defp validate_keys!(opts) do
    case Keyword.keys(opts) -- @keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown args key(s) #{inspect(unknown)}; expected one of #{inspect(@keys)}"
    end
  end

  defp validate_prompt!(opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, prompt} when is_binary(prompt) ->
        :ok

      {:ok, other} ->
        raise ArgumentError, ":prompt must be a string, got #{inspect(other)}"

      :error ->
        raise ArgumentError, ":prompt is required"
    end
  end

  defp validate_enum!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        vocab = Map.fetch!(@enum_vocab, key)

        unless value in vocab do
          raise ArgumentError,
                "unknown #{key} #{inspect(value)}; expected one of #{inspect(vocab)}"
        end

      :error ->
        :ok
    end
  end

  # Atom-valued enums serialize to strings (the JSON wire form); `ObanClaude`
  # coerces them back to atoms when it builds the query opts. Everything else
  # (strings, numbers, lists of strings) is already JSON-clean.
  defp serialize(key, value) when key in @enum_keys, do: Atom.to_string(value)
  defp serialize(_key, value), do: value
end
