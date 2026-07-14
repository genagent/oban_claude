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

    test "raises a clean Mix error (not a NimbleOptions dump) on a bad enum value" do
      assert_raise Mix.Error, ~r/permission.mode/, fn ->
        Run.build_args(["x", "--permission-mode", "wild"])
      end
    end

    test "raises a clean Mix error (not a NimbleOptions dump) when the prompt is missing" do
      assert_raise Mix.Error, ~r/prompt/, fn ->
        Run.build_args(["--model", "sonnet"])
      end
    end

    test "maps --hermetic to the seal scope (and true as an alias for full)" do
      assert Run.build_args(["x", "--hermetic", "full"])["hermetic"] == "full"
      assert Run.build_args(["x", "--hermetic", "project"])["hermetic"] == "project"
      assert Run.build_args(["x", "--hermetic", "true"])["hermetic"] == true
    end

    test "raises on multiple positional arguments (a forgotten shell quote)" do
      assert_raise Mix.Error, ~r/quote the prompt/, fn ->
        Run.build_args(["summarize", "the", "changes"])
      end
    end

    test "raises when --prompt is combined with a positional argument" do
      assert_raise Mix.Error, ~r/--prompt given together/, fn ->
        Run.build_args(["extra", "--prompt", "hi"])
      end
    end
  end

  describe "render/2 (output layer)" do
    alias ClaudeWrapper.{Error, Result}

    test "text mode renders a success verdict, the result, and a meta line" do
      out = Run.render({:ok, %Result{result: "done", is_error: false, cost_usd: 0.01}}, false)
      assert out =~ "verdict: :ok"
      assert out =~ "done"
      assert out =~ "cost=$0.01"
    end

    test "json mode emits a structured verdict, not an Elixir tuple string" do
      json = Run.render({{:cancel, :auth}, %Error{kind: :auth, reason: :invalid}}, true)
      decoded = :json.decode(json)
      assert decoded["verdict"] == "cancel"
      assert decoded["reason"] == "auth"
      assert decoded["error_kind"] == "auth"
    end

    test "json success verdict is machine-clean" do
      json = Run.render({:ok, %Result{result: "hi", is_error: false, cost_usd: 0.02}}, true)
      decoded = :json.decode(json)
      assert decoded["verdict"] == "ok"
      assert decoded["result"] == "hi"
      assert decoded["cost_usd"] == 0.02
    end

    test "renders defensively for an off-contract payload (neither Result nor Error)" do
      out = Run.render({{:cancel, :weird}, :not_a_struct}, false)
      assert out =~ "verdict: {:cancel, :weird}"
      assert out =~ ":not_a_struct"
    end
  end
end
