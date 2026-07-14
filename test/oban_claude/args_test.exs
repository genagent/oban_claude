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

    test "a meta key colliding with a claude option raises (no silent escalation)" do
      assert_raise ArgumentError, ~r/collides with the claude option/, fn ->
        Args.new(prompt: "x", model: "sonnet", meta: %{"model" => "should-lose"})
      end
    end

    test "a meta key colliding with prompt raises" do
      assert_raise ArgumentError, ~r/collides with the claude option/, fn ->
        Args.new(prompt: "x", meta: %{"prompt" => "smuggled"})
      end
    end

    test "a non-JSON-encodable meta value raises at build time, naming the key" do
      assert_raise ArgumentError, ~r/"range" is not JSON-encodable/, fn ->
        Args.new(prompt: "x", meta: %{"range" => {1, 5}})
      end
    end

    test "JSON-clean meta values (numbers, booleans, nested maps/lists) are accepted" do
      assert Args.new(prompt: "x", meta: %{"n" => 42, "ok" => true, "nested" => %{"a" => [1, 2]}}) ==
               %{"prompt" => "x", "n" => 42, "ok" => true, "nested" => %{"a" => [1, 2]}}
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

    test "accepts true as an alias for :full (parity with the raw-map path)" do
      assert Args.new(prompt: "x", hermetic: true)["hermetic"] == true
    end

    test "rejects a scope outside the vocabulary" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :hermetic/, fn ->
        Args.new(prompt: "x", hermetic: :bare)
      end
    end
  end

  describe "session continuity (#73)" do
    test "resume/session_id accept strings; the two flags accept booleans" do
      args =
        Args.new(
          prompt: "x",
          resume: "sess-1",
          session_id: "sess-2",
          no_session_persistence: true,
          fork_session: true
        )

      assert args["resume"] == "sess-1"
      assert args["session_id"] == "sess-2"
      assert args["no_session_persistence"] == true
      assert args["fork_session"] == true
    end

    test "reject wrong types" do
      assert_raise NimbleOptions.ValidationError, ~r/invalid value for :resume/, fn ->
        Args.new(prompt: "x", resume: 123)
      end

      assert_raise NimbleOptions.ValidationError,
                   ~r/invalid value for :no_session_persistence/,
                   fn -> Args.new(prompt: "x", no_session_persistence: "yes") end
    end

    test "continue_session is deliberately NOT accepted (host-scoped, unsafe under concurrency)" do
      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:continue_session\]/, fn ->
        Args.new(prompt: "x", continue_session: true)
      end
    end

    test "available in defaults/1 for a per-worker fire-and-forget seal" do
      assert Args.defaults(no_session_persistence: true) == %{"no_session_persistence" => true}
    end
  end

  describe "add_dir" do
    test "accepts a list of paths" do
      assert Args.new(prompt: "x", add_dir: ["/a", "/b"])["add_dir"] == ["/a", "/b"]
    end

    test "accepts a single path string (parity with the raw-map and query paths)" do
      assert Args.new(prompt: "x", add_dir: "/a")["add_dir"] == "/a"
    end
  end

  describe "round-trip through run/2" do
    test "EVERY Args key (minus :meta) survives build/1 into the query opts" do
      # A valid value for every builder option. The equality assertion below
      # forces this list to stay exhaustive: add a key to the schema and this
      # test fails until it is represented here -- which is the whole guard, so a
      # key added to Args but not @passthrough can never be silently dropped.
      opts = [
        prompt: "do it",
        model: "sonnet",
        fallback_model: "haiku",
        working_dir: "/repo",
        binary: "/opt/claude/1.2.3/claude",
        add_dir: ["/x"],
        system_prompt: "sys",
        append_system_prompt: "more",
        system_prompt_file: "/sp.txt",
        append_system_prompt_file: "/asp.txt",
        permission_prompt_tool: "mcp__gate__approve",
        max_thinking_tokens: 4096,
        permission_mode: :plan,
        allowed_tools: ["Read"],
        disallowed_tools: ["WebFetch"],
        mcp_config: ["/mcp.json"],
        agent: "reviewer",
        effort: :high,
        max_turns: 3,
        max_budget_usd: 2.0,
        timeout: 60_000,
        json_schema: ~s({"type":"object"}),
        worktree: "issue-5",
        hermetic: :full,
        resume: "sess-1",
        session_id: "sess-2",
        no_session_persistence: true,
        fork_session: true
      ]

      assert Enum.sort(Keyword.keys(opts)) == Enum.sort(Args.keys() -- [:meta])

      pid = self()

      qf = fn prompt, query_opts ->
        send(pid, {:queried, prompt, query_opts})
        {:ok, %Result{result: "", is_error: false}}
      end

      opts |> Args.new() |> ObanClaude.run(query_fun: qf)

      assert_received {:queried, "do it", query_opts}

      # Every non-prompt key reached the query opts -- nothing silently dropped.
      for key <- Keyword.keys(opts), key != :prompt do
        assert Keyword.has_key?(query_opts, key), "build/1 dropped #{inspect(key)}"
      end

      # And the enums reconstruct as atoms.
      assert query_opts[:permission_mode] == :plan
      assert query_opts[:effort] == :high
      assert query_opts[:hermetic] == :full
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
