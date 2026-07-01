defmodule Mix.Tasks.ObanClaude.RunTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ObanClaude.Run

  describe "build_args/1" do
    test "takes the prompt from the first positional argument" do
      assert Run.build_args(["summarize the repo"]) == %{"prompt" => "summarize the repo"}
    end

    test "takes the prompt from --prompt" do
      assert Run.build_args(["--prompt", "hi"]) == %{"prompt" => "hi"}
    end

    test "maps scalar flags to the builder vocabulary" do
      args =
        Run.build_args(["x", "--model", "sonnet", "--working-dir", "/repo", "--max-turns", "3"])

      assert args == %{
               "prompt" => "x",
               "model" => "sonnet",
               "working_dir" => "/repo",
               "max_turns" => 3
             }
    end

    test "coerces the enum flags to their string wire form via atoms" do
      args = Run.build_args(["x", "--permission-mode", "plan", "--effort", "high"])

      assert args["permission_mode"] == "plan"
      assert args["effort"] == "high"
    end

    test "folds repeated list flags into a single list" do
      args = Run.build_args(["x", "--allowed-tools", "Read", "--allowed-tools", "Grep"])

      assert args["allowed_tools"] == ["Read", "Grep"]
    end

    test "parses --worktree true/false as a boolean, else a named worktree" do
      assert Run.build_args(["x", "--worktree", "true"])["worktree"] == true
      assert Run.build_args(["x", "--worktree", "false"])["worktree"] == false
      assert Run.build_args(["x", "--worktree", "issue-5"])["worktree"] == "issue-5"
    end

    test "honors short aliases" do
      assert Run.build_args(["x", "-m", "opus", "-p", "plan"]) == %{
               "prompt" => "x",
               "model" => "opus",
               "permission_mode" => "plan"
             }
    end

    test "raises on an unknown flag" do
      assert_raise Mix.Error, ~r/unknown or malformed option/, fn ->
        Run.build_args(["x", "--nope", "y"])
      end
    end

    test "raises (via the builder) on an out-of-vocabulary enum value" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :permission_mode/, fn ->
        Run.build_args(["x", "--permission-mode", "wild"])
      end
    end

    test "raises (via the builder) when the prompt is missing" do
      assert_raise NimbleOptions.ValidationError, ~r/required :prompt/, fn ->
        Run.build_args(["--model", "sonnet"])
      end
    end
  end
end
