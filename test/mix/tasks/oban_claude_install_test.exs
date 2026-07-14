defmodule Mix.Tasks.ObanClaude.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp install do
    test_project()
    |> Igniter.compose_task("oban_claude.install", [])
  end

  test "creates a SQLite repo module" do
    install()
    |> assert_creates("lib/test/repo.ex", """
    defmodule Test.Repo do
      use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.SQLite3
    end
    """)
  end

  test "creates a sample worker on the :claude queue with an offline query_fun" do
    igniter = install()

    assert_creates(igniter, "lib/test/sample_claude_worker.ex")

    worker = source_content(igniter, "lib/test/sample_claude_worker.ex")
    assert worker =~ "use ObanClaude.Worker"
    assert worker =~ "queue: :claude"
    assert worker =~ "query_fun: &__MODULE__.demo_query/2"
    assert worker =~ "worktree: true"
    assert worker =~ "timeout: :timer.minutes(10)"
    assert worker =~ "max_attempts: 3"
  end

  test "creates the watch-demo module that logs telemetry and enqueues on boot" do
    igniter = install()

    assert_creates(igniter, "lib/test/oban_claude_demo.ex")

    demo = source_content(igniter, "lib/test/oban_claude_demo.ex")
    assert demo =~ "[:oban_claude, :run, :stop]"
    assert demo =~ "Test.SampleClaudeWorker.new("
    assert demo =~ "Oban.insert()"
    # enqueue moved out of init/1 so a pre-migrate boot doesn't crash the app
    assert demo =~ "handle_continue"
    # the :exception handler logs the error kind, not the whole struct
    assert demo =~ "run errored"
  end

  test "configures Oban with the Lite engine and merges the :claude queue" do
    config = install() |> source_content("config/config.exs")

    assert config =~ "Oban.Engines.Lite"
    assert config =~ "claude:"
    # the merge keeps oban.install's existing default queue rather than replacing it
    assert config =~ "default:"
    assert config =~ "ecto_repos"
  end

  # Igniter.Test exposes created/updated file bodies via the rewrite sources;
  # read one out of the applied igniter for content assertions.
  defp source_content(igniter, path) do
    igniter = Igniter.Test.apply_igniter!(igniter)
    Rewrite.source!(igniter.rewrite, path) |> Rewrite.Source.get(:content)
  end
end
