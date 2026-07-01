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
        allowed_tools: ["Read"]
      )
      |> ObanClaude.run(query_fun: qf)

      assert_received {:queried, "do it", opts}
      assert opts[:model] == "sonnet"
      assert opts[:permission_mode] == :plan
      assert opts[:effort] == :high
      assert opts[:allowed_tools] == ["Read"]
    end
  end
end
