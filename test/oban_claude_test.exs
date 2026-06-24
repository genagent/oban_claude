defmodule ObanClaudeTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Error, Result}
  alias ObanClaude.Outcome

  # NOTE: confirm the %Result{}/%Error{} field names against the installed
  # claude_wrapper before relying on these fixtures. See SPEC.md "Build-out".

  describe "Outcome.classify/1" do
    test "a clean result succeeds" do
      r = %Result{result: "hi", is_error: false}
      assert {:ok, ^r} = Outcome.classify({:ok, r})
    end

    test "an is_error result retries" do
      r = %Result{result: "", is_error: true}
      assert {{:error, :result_error}, ^r} = Outcome.classify({:ok, r})
    end

    test "timeout snoozes" do
      e = %Error{kind: :timeout}
      assert {{:snooze, _}, ^e} = Outcome.classify({:error, e})
    end

    test "auth / budget / max-turns / missing-binary cancel (no blind retry)" do
      for kind <- [:auth, :binary_not_found, :budget_exceeded, :max_turns_exceeded] do
        e = %Error{kind: kind}
        assert {{:cancel, ^kind}, ^e} = Outcome.classify({:error, e})
      end
    end

    test "other errors retry" do
      e = %Error{kind: :command_failed}
      assert {{:error, :command_failed}, ^e} = Outcome.classify({:error, e})
    end
  end

  describe "run/2" do
    test "classifies a clean result to {:ok, result}" do
      result = %Result{result: "hi", is_error: false}

      assert {:ok, ^result} =
               ObanClaude.run(%{"prompt" => "x"}, query_fun: fn _p, _o -> {:ok, result} end)
    end

    test "maps a claude error through the default classifier" do
      err = %Error{kind: :auth}

      assert {{:cancel, :auth}, ^err} =
               ObanClaude.run(%{"prompt" => "x"}, query_fun: fn _p, _o -> {:error, err} end)
    end

    test "passes the prompt and builds atom-keyed query opts from passthrough keys" do
      pid = self()

      qf = fn prompt, opts ->
        send(pid, {:queried, prompt, opts})
        {:ok, %Result{result: "", is_error: false}}
      end

      ObanClaude.run(%{"prompt" => "do it", "model" => "sonnet", "max_turns" => 3}, query_fun: qf)

      assert_received {:queried, "do it", opts}
      assert opts[:model] == "sonnet"
      assert opts[:max_turns] == 3
      assert Enum.all?(Keyword.keys(opts), &is_atom/1)
    end

    test "ignores args keys that are not passthrough opts" do
      pid = self()

      qf = fn _p, opts ->
        send(pid, {:opts, opts})
        {:ok, %Result{result: "", is_error: false}}
      end

      ObanClaude.run(%{"prompt" => "x", "not_an_option" => "ignored"}, query_fun: qf)

      assert_received {:opts, opts}
      refute Keyword.has_key?(opts, :not_an_option)
    end

    test "coerces permission_mode from a JSON string to the atom claude expects" do
      pid = self()

      qf = fn _p, opts ->
        send(pid, {:opts, opts})
        {:ok, %Result{result: "", is_error: false}}
      end

      ObanClaude.run(%{"prompt" => "x", "permission_mode" => "bypass_permissions"}, query_fun: qf)

      assert_received {:opts, opts}
      assert opts[:permission_mode] == :bypass_permissions
    end

    test "raises a helpful error on an unknown permission_mode" do
      qf = fn _p, _o -> {:ok, %Result{result: "", is_error: false}} end

      assert_raise ArgumentError, ~r/unknown permission_mode/, fn ->
        ObanClaude.run(%{"prompt" => "x", "permission_mode" => "nope"}, query_fun: qf)
      end
    end

    test "the :classifier option overrides the default mapping" do
      result = %Result{result: "hi", is_error: false}

      assert {:cancel, :always} =
               ObanClaude.run(%{"prompt" => "x"},
                 query_fun: fn _p, _o -> {:ok, result} end,
                 classifier: fn _ -> {:cancel, :always} end
               )
    end

    test "requires a prompt" do
      assert_raise KeyError, fn ->
        ObanClaude.run(%{}, query_fun: fn _p, _o -> {:ok, %Result{is_error: false}} end)
      end
    end
  end

  describe "structured/1 and outcome/1" do
    test "structured/1 returns the whole validated object" do
      object = %{"outcome" => "needs_review", "summary" => "looks risky"}
      r = %Result{result: "", is_error: false, extra: %{"structured_output" => object}}

      assert ObanClaude.structured(r) == object
    end

    test "outcome/1 reads structured_output.outcome" do
      r = %Result{
        result: "",
        is_error: false,
        extra: %{"structured_output" => %{"outcome" => "blocked"}}
      }

      assert ObanClaude.outcome(r) == "blocked"
    end

    test "both are nil when there is no structured output" do
      r = %Result{result: "x", is_error: false}
      assert ObanClaude.structured(r) == nil
      assert ObanClaude.outcome(r) == nil
    end
  end
end
