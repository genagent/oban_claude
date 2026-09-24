defmodule ObanClaude.CLI.Doctor do
  @moduledoc false
  # `mix oban_claude doctor` -- a fleet pre-flight check: is the claude CLI
  # present and a usable version, and is it authenticated? Wraps claude_wrapper's
  # own version/auth_status probes and exits non-zero if any check fails, so it
  # can gate a deploy before workers start firing paid runs.

  use Cheer.Command

  command "doctor" do
    about("Check the claude CLI is present, a usable version, and authenticated.")

    long_about("""
    Runs claude_wrapper's version and authentication probes and prints a report.
    Exits non-zero if any check fails, so `mix oban_claude doctor` can gate a
    fleet deploy. Makes no paid claude calls.
    """)

    option(:json, type: :boolean, help: "Print the report as JSON.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    {:ok, _} = Application.ensure_all_started(:claude_wrapper)
    json? = Map.get(args, :json, false)

    checks = [
      {"claude binary + version", ClaudeWrapper.version()},
      {"authentication", auth_check(ClaudeWrapper.auth_status())}
    ]

    {text, ok?} = report(checks)

    cond do
      json? -> Mix.shell().info(json_report(checks, ok?))
      ok? -> Mix.shell().info(text)
      true -> Mix.shell().error(text)
    end

    if ok?, do: :ok, else: {:error, :run_failed}
  end

  @doc false
  # Interprets `ClaudeWrapper.auth_status/0` for the gate: `{:ok, _}` only when the
  # status says logged in. Pure, so it is testable without a claude binary.
  @spec auth_check({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def auth_check({:ok, %{logged_in: true} = info}), do: {:ok, info}

  # Temporary fallback for genagent/claude_wrapper_ex#252: claude CLI 2.1.273
  # emits camelCase (`loggedIn`) and claude_wrapper 0.14.0 reads snake_case, so
  # the typed `logged_in` is false on a logged-in machine. Remove this clause
  # when the wrapper dependency is bumped to a release with the fix.
  def auth_check({:ok, %{extra: %{"loggedIn" => true}} = info}), do: {:ok, info}

  def auth_check({:ok, info}) when is_map(info), do: {:error, {:not_logged_in, info}}
  def auth_check({:ok, raw}), do: {:error, {:auth_status_unknown, raw}}
  def auth_check({:error, _reason} = error), do: error

  @doc false
  # A list of `{label, {:ok, info} | {:error, reason}}` -> `{report_text, ok?}`.
  # Pure, so the report layer is testable without a claude binary.
  @spec report([{String.t(), {:ok, term()} | {:error, term()}}]) :: {String.t(), boolean()}
  def report(checks) do
    ok? = Enum.all?(checks, fn {_label, result} -> match?({:ok, _}, result) end)

    lines =
      Enum.map_join(checks, "\n", fn
        {label, {:ok, info}} -> "  [ok]   #{label}: #{format_info(info)}"
        {label, {:error, reason}} -> "  [FAIL] #{label}: #{inspect(reason)}"
      end)

    header = if ok?, do: "claude environment OK", else: "claude environment NOT ready"
    {header <> "\n" <> lines, ok?}
  end

  @doc false
  @spec json_report([{String.t(), {:ok, term()} | {:error, term()}}], boolean()) :: String.t()
  def json_report(checks, ok?) do
    %{
      ok: ok?,
      checks:
        Enum.map(checks, fn
          {label, {:ok, info}} -> %{name: label, status: "ok", info: normalize(info)}
          {label, {:error, reason}} -> %{name: label, status: "error", reason: inspect(reason)}
        end)
    }
    |> ObanClaude.CLI.encode_json()
  end

  defp format_info(info) when is_map(info),
    do: info |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

  defp format_info(info) when is_binary(info), do: info
  defp format_info(info), do: inspect(info)

  # JSON-safe view of an :ok info payload: a map of string keys, else a string.
  defp normalize(info) when is_map(info),
    do: Map.new(info, fn {k, v} -> {to_string(k), to_string_safe(v)} end)

  defp normalize(info), do: to_string_safe(info)

  defp to_string_safe(v) when is_binary(v) or is_number(v) or is_boolean(v), do: v
  defp to_string_safe(v), do: inspect(v)
end
