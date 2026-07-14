defmodule Mix.Tasks.ObanClaude do
  @shortdoc "Run claude from the CLI: `mix oban_claude <run|doctor|args>`."

  @moduledoc """
  #{@shortdoc}

  A [`cheer`](https://hexdocs.pm/cheer) command tree over `ObanClaude`, so the
  CLI shares one declarative definition (parsing, validation, `--help`, and shell
  completion) across its subcommands:

    * `mix oban_claude run "<prompt>" [flags]` -- fire a single, queueless claude
      run and print the verdict (a real, billable call).
    * `mix oban_claude doctor` -- a fleet pre-flight check (binary present, usable
      version, authenticated); exits non-zero if the environment is not ready.
    * `mix oban_claude args "<prompt>" [flags]` -- build and print the validated
      `ObanClaude.Args` map from flags, without running claude (a dry run).

  Every `run` / `args` flag maps to an `ObanClaude.Args.new/1` option; the prompt
  is the first positional argument. `mix oban_claude <cmd> --help` shows the full
  flag list. Scaffolding a project is separate: `mix oban_claude.install` (an
  Igniter task).

  ## Examples

      mix oban_claude run "summarize the repo" --working-dir . --permission-mode plan
      mix oban_claude run "extract the facts" --json-schema "$(cat schema.json)" --json
      mix oban_claude args "review this" --model sonnet --allowed-tools Read
      mix oban_claude doctor
  """

  use Cheer.MixTask

  command "oban_claude" do
    about("Run claude from the command line.")
    subcommand_required(true)

    subcommand(ObanClaude.CLI.Run)
    subcommand(ObanClaude.CLI.Doctor)
    subcommand(ObanClaude.CLI.Args)
  end

  # Override the generated Mix entry point to map our leaf commands' failure
  # verdict onto a conventional nonzero exit (a failed run is exit 1; a usage
  # error stays the cheer/Mix idiom of exit 2).
  @impl Mix.Task
  def run(argv) do
    case Cheer.run(__MODULE__, argv, prog: "mix oban_claude") do
      {:error, :usage} -> exit({:shutdown, 2})
      {:error, :run_failed} -> exit({:shutdown, 1})
      _ -> :ok
    end
  end
end
