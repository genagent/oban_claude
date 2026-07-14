defmodule ObanClaude.ArgsTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Result
  alias ObanClaude.Args

  describe "new/1" do
    test "builds a string-keyed map from atom-keyed opts" do
      assert Args.new(prompt: "hi", working_dir: "/repo") == %{
               "prompt" => "hi",
               "working_dir" => "/repo"
             }
    end

    test "keeps native number and list values" do
      args = Args.new(prompt: "x", max_turns: 3, allowed_tools: ["Read", "Grep"])

      assert args["max_turns"] == 3
      assert args["allowed_tools"] == ["Read", "Grep"]
    end

    test "serializes the atom-valued enums to their JSON string form" do
      args = Args.new(prompt: "x", permission_mode: :plan, effort: :high)

      assert args["permission_mode"] == "plan"
      assert args["effort"] == "high"
    end

    test "requires a prompt" do
      assert_raise NimbleOptions.ValidationError, ~r/required :prompt option not found/, fn ->
        Args.new(model: "sonnet")
      end
    end

    test "rejects a non-string prompt" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :prompt/, fn ->
        Args.new(prompt: :not_a_string)
      end
    end

    test "raises on an unknown key" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:workingdir\]/, fn ->
        Args.new(prompt: "x", workingdir: "/typo")
      end
    end

    test "raises on an out-of-vocabulary permission_mode" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :permission_mode/, fn ->
        Args.new(prompt: "x", permission_mode: :nope)
      end
    end

    test "raises on an out-of-vocabulary effort" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :effort/, fn ->
        Args.new(prompt: "x", effort: :turbo)
      end
    end
  end

  describe "defaults/1" do
    test "builds a prompt-less map for worker :args" do
      assert Args.defaults(
               working_dir: "/repo",
               model: "sonnet",
               permission_mode: :bypass_permissions
             ) ==
               %{
                 "working_dir" => "/repo",
                 "model" => "sonnet",
                 "permission_mode" => "bypass_permissions"
               }
    end

    test "an empty defaults map is valid" do
      assert Args.defaults() == %{}
    end

    test "still allows a prompt if given" do
      assert Args.defaults(prompt: "fixed") == %{"prompt" => "fixed"}
    end

    test "still validates unknown keys and enum values" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:nope\]/, fn ->
        Args.defaults(nope: 1)
      end

      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :permission_mode/, fn ->
        Args.defaults(permission_mode: :wild)
      end
    end
  end

  describe ":meta" do
    test "merges metadata into the args map, stringifying keys" do
      assert Args.new(prompt: "x", meta: %{"issue" => "173", number: 42}) == %{
               "prompt" => "x",
               "issue" => "173",
               "number" => 42
             }
    end

    test "explicit claude options win over a colliding meta key" do
      args = Args.new(prompt: "x", model: "sonnet", meta: %{"model" => "should-lose"})

      assert args["model"] == "sonnet"
    end

    test "works with defaults/1 too" do
      assert Args.defaults(meta: %{"queue" => "issues"}) == %{"queue" => "issues"}
    end
  end

  describe "keys/0" do
    test "lists the accepted option keys" do
      keys = Args.keys()

      assert is_list(keys) and Enum.all?(keys, &is_atom/1)
      assert :prompt in keys
      assert :worktree in keys
      assert :meta in keys
    end
  end

  describe "worktree" do
    test "true builds an ephemeral-worktree flag" do
      assert Args.new(prompt: "x", worktree: true) == %{"prompt" => "x", "worktree" => true}
    end

    test "a string builds a named worktree" do
      assert Args.new(prompt: "x", worktree: "issue-173")["worktree"] == "issue-173"
    end

    test "is available in defaults/1 for blanket per-worker isolation" do
      assert Args.defaults(working_dir: "/repo", worktree: true) == %{
               "working_dir" => "/repo",
               "worktree" => true
             }
    end

    test "rejects a non-boolean, non-string worktree" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :worktree/, fn ->
        Args.new(prompt: "x", worktree: 5)
      end
    end
  end

  describe "hermetic" do
    test ":full and :project serialize to their string wire form" do
      assert Args.new(prompt: "x", hermetic: :full)["hermetic"] == "full"
      assert Args.new(prompt: "x", hermetic: :project)["hermetic"] == "project"
    end

    test "is available in defaults/1 for a reproducible per-worker seal" do
      assert Args.defaults(working_dir: "/repo", hermetic: :full) == %{
               "working_dir" => "/repo",
               "hermetic" => "full"
             }
    end

    test "rejects a scope outside the vocabulary" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :hermetic/, fn ->
        Args.new(prompt: "x", hermetic: :bare)
      end
    end
  end

  describe "round-trip through run/2" do
    test "every emitted key survives build/1 and the enums reconstruct as atoms" do
      pid = self()

      qf = fn prompt, opts ->
        send(pid, {:queried, prompt, opts})
        {:ok, %Result{result: "", is_error: false}}
      end

      Args.new(
        prompt: "do it",
        model: "sonnet",
        permission_mode: :plan,
        effort: :high,
        hermetic: :full,
        allowed_tools: ["Read"],
        worktree: "issue-5"
      )
      |> ObanClaude.run(query_fun: qf)

      assert_received {:queried, "do it", opts}
      assert opts[:model] == "sonnet"
      assert opts[:permission_mode] == :plan
      assert opts[:effort] == :high
      assert opts[:hermetic] == :full
      assert opts[:allowed_tools] == ["Read"]
      assert opts[:worktree] == "issue-5"
    end

    test "meta keys are carried in the args but ignored by the query build" do
      pid = self()

      qf = fn _prompt, opts ->
        send(pid, {:queried, opts})
        {:ok, %Result{result: "", is_error: false}}
      end

      args = Args.new(prompt: "x", meta: %{"issue" => "173"})
      assert args["issue"] == "173"

      ObanClaude.run(args, query_fun: qf)
      assert_received {:queried, opts}
      refute Keyword.has_key?(opts, :issue)
    end
  end
end
