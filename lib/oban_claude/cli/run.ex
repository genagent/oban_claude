defmodule ObanClaude.CLI.Run do
  @moduledoc false
  # `mix oban_claude run` -- the one-shot, queueless counterpart to the Oban
  # worker. CLI flags parse into the same `ObanClaude.Args.new/1` vocabulary, run
  # through `ObanClaude.run/2`, and the `{oban_return, result}` verdict prints.

  use Cheer.Command
  require ObanClaude.CLI

  command "run" do
    about("Fire a single claude run (no queue, no database).")

    long_about("""
    Parse CLI flags into the ObanClaude.Args vocabulary, run one claude call via
    ObanClaude.run/2, and print the {oban_return, result} verdict. Makes a real
    (billable) claude call using the CLI's own authentication. The task exits
    non-zero when the verdict is {:error, _} or {:cancel, _}.
    """)

    ObanClaude.CLI.claude_options()

    option(:json, type: :boolean, help: "Print a machine-readable JSON summary instead of text.")
  end

  @impl Cheer.Command
  def run(args, _raw) do
    {:ok, _} = Application.ensure_all_started(:claude_wrapper)
    {json?, args} = Map.pop(args, :json, false)

    outcome = args |> ObanClaude.CLI.to_args() |> ObanClaude.run()

    if ObanClaude.CLI.emit(outcome, json?), do: :ok, else: {:error, :run_failed}
  end
end
