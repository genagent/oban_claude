defmodule ObanClaude.CLITest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Error, Result}
  alias Mix.Tasks.ObanClaude, as: RootTask
  alias ObanClaude.CLI
  alias ObanClaude.CLI.Doctor

  # to_args/1 receives cheer's parsed map (atom keys); it maps to the validated
  # ObanClaude.Args string map. These mirror the old build_args tests one layer
  # down (cheer owns argv -> parsed map; the end-to-end tests below cover that).
  describe "to_args/1" do
    test "maps scalar options to the builder vocabulary" do
      assert CLI.to_args(%{prompt: "x", model: "sonnet", working_dir: "/repo", max_turns: 3}) ==
               %{"prompt" => "x", "model" => "sonnet", "working_dir" => "/repo", "max_turns" => 3}
    end

    test "coerces the enum options through atoms to their wire strings" do
      args = CLI.to_args(%{prompt: "x", permission_mode: "plan", effort: "high"})

      assert args["permission_mode"] == "plan"
      assert args["effort"] == "high"
    end

    test "keeps repeated (multi) list options as lists" do
      assert CLI.to_args(%{prompt: "x", allowed_tools: ["Read", "Grep"]})["allowed_tools"] ==
               ["Read", "Grep"]
    end

    test "drops empty (unset) multi lists rather than forwarding []" do
      refute Map.has_key?(CLI.to_args(%{prompt: "x", allowed_tools: []}), "allowed_tools")
    end

    test "parses --worktree true/false as a boolean, else a named worktree" do
      assert CLI.to_args(%{prompt: "x", worktree: "true"})["worktree"] == true
      assert CLI.to_args(%{prompt: "x", worktree: "false"})["worktree"] == false
      assert CLI.to_args(%{prompt: "x", worktree: "issue-5"})["worktree"] == "issue-5"
    end

    test "maps --hermetic to the seal scope (and true as an alias for full)" do
      assert CLI.to_args(%{prompt: "x", hermetic: "full"})["hermetic"] == "full"
      assert CLI.to_args(%{prompt: "x", hermetic: "project"})["hermetic"] == "project"
      assert CLI.to_args(%{prompt: "x", hermetic: "true"})["hermetic"] == true
    end

    test "carries the session keys through" do
      args =
        CLI.to_args(%{
          prompt: "x",
          resume: "sess-1",
          session_id: "sess-2",
          no_session_persistence: true,
          fork_session: true
        })

      assert args["resume"] == "sess-1"
      assert args["session_id"] == "sess-2"
      assert args["no_session_persistence"] == true
      assert args["fork_session"] == true
    end

    test "raises a clean Mix error (not a NimbleOptions dump) when the prompt is missing" do
      assert_raise Mix.Error, ~r/prompt/, fn -> CLI.to_args(%{model: "sonnet"}) end
    end
  end

  describe "render/2 (output layer)" do
    test "text mode renders a success verdict, the result, and a meta line" do
      out = CLI.render({:ok, %Result{result: "done", is_error: false, cost_usd: 0.01}}, false)
      assert out =~ "verdict: :ok"
      assert out =~ "done"
      assert out =~ "cost=$0.01"
    end

    test "json mode emits a structured verdict, not an Elixir tuple string" do
      json = CLI.render({{:cancel, :auth}, %Error{kind: :auth, reason: :invalid}}, true)
      decoded = :json.decode(json)
      assert decoded["verdict"] == "cancel"
      assert decoded["reason"] == "auth"
      assert decoded["error_kind"] == "auth"
    end

    test "json success verdict is machine-clean" do
      json = CLI.render({:ok, %Result{result: "hi", is_error: false, cost_usd: 0.02}}, true)
      decoded = :json.decode(json)
      assert decoded["verdict"] == "ok"
      assert decoded["result"] == "hi"
      assert decoded["cost_usd"] == 0.02
    end

    test "renders defensively for an off-contract payload (neither Result nor Error)" do
      out = CLI.render({{:cancel, :weird}, :not_a_struct}, false)
      assert out =~ "verdict: {:cancel, :weird}"
      assert out =~ ":not_a_struct"
    end
  end

  # Drives the real command tree via Cheer.Test (no subprocess, no paid call).
  # The `args` command is the vehicle: it exercises argv -> parse -> to_args ->
  # print end to end without a claude call.
  describe "the command tree (via Cheer.Test)" do
    setup do
      # so the command's Mix.shell().info reaches captured stdout, not a mailbox.
      shell = Mix.shell()
      Mix.shell(Mix.Shell.IO)
      on_exit(fn -> Mix.shell(shell) end)
    end

    test "`args` parses flags, builds, and prints the validated map" do
      result =
        Cheer.Test.run(RootTask, [
          "args",
          "summarize the repo",
          "--model",
          "sonnet",
          "--allowed-tools",
          "Read",
          "--allowed-tools",
          "Grep"
        ])

      assert result.return == :ok
      assert result.output =~ "summarize the repo"
      assert result.output =~ "sonnet"
      assert result.output =~ "Read"
      assert result.output =~ "Grep"
    end

    test "`args --json` prints a JSON args map" do
      result = Cheer.Test.run(RootTask, ["args", "hi", "--max-turns", "3", "--json"])

      assert result.return == :ok
      decoded = :json.decode(String.trim(result.output))
      assert decoded["prompt"] == "hi"
      assert decoded["max_turns"] == 3
    end

    test "a bare invocation is a usage failure (a subcommand is required)" do
      assert Cheer.Test.run(RootTask, []).return == {:error, :usage}
    end

    test "an unknown flag is a usage failure" do
      assert Cheer.Test.run(RootTask, ["run", "--nope"]).return == {:error, :usage}
    end

    test "an out-of-vocabulary enum choice is a usage failure (cheer :choices)" do
      assert Cheer.Test.run(RootTask, ["args", "hi", "--permission-mode", "wild"]).return ==
               {:error, :usage}
    end

    test "a missing prompt argument is a usage failure" do
      assert Cheer.Test.run(RootTask, ["args", "--model", "sonnet"]).return ==
               {:error, :usage}
    end
  end

  describe "Doctor.report/1" do
    test "all checks ok -> a ready report" do
      {text, ok?} =
        Doctor.report([
          {"claude binary + version", {:ok, %{version: "1.2.3"}}},
          {"authentication", {:ok, %{status: "authenticated"}}}
        ])

      assert ok?
      assert text =~ "claude environment OK"
      assert text =~ "[ok]"
    end

    test "any failed check -> not-ready, and ok? is false" do
      {text, ok?} =
        Doctor.report([
          {"claude binary + version", {:ok, %{version: "1.2.3"}}},
          {"authentication", {:error, :not_logged_in}}
        ])

      refute ok?
      assert text =~ "NOT ready"
      assert text =~ "[FAIL]"
      assert text =~ "not_logged_in"
    end

    test "json_report/2 is machine-clean" do
      json =
        Doctor.json_report(
          [{"authentication", {:error, :not_logged_in}}],
          false
        )

      decoded = :json.decode(json)
      assert decoded["ok"] == false
      assert [%{"name" => "authentication", "status" => "error"}] = decoded["checks"]
    end
  end
end
