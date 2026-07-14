defmodule ObanClaude.TestingTest do
  use ExUnit.Case, async: true

  import ObanClaude.Testing

  alias ClaudeWrapper.{Error, Result}

  describe "result/1" do
    test "a bare string is the result text of a non-error result" do
      assert result("done") == %Result{result: "done", is_error: false}
    end

    test "defaults to an empty, non-error result" do
      assert result() == %Result{result: "", is_error: false}
    end

    test "a keyword list sets the other Result fields" do
      r = result(result: "done", cost_usd: 0.01, num_turns: 2)

      assert r.result == "done"
      assert r.cost_usd == 0.01
      assert r.num_turns == 2
      assert r.is_error == false
    end
  end

  describe "structured_result/2" do
    test "plants data where ObanClaude.structured/1 and outcome/1 read it" do
      r = structured_result(%{"outcome" => "blocked", "why" => "locked file"})

      assert ObanClaude.structured(r) == %{"outcome" => "blocked", "why" => "locked file"}
      assert ObanClaude.outcome(r) == "blocked"
    end

    test "carries the other Result fields through opts" do
      r = structured_result(%{"pr" => 42}, cost_usd: 0.03, result: "opened PR")

      assert ObanClaude.structured(r) == %{"pr" => 42}
      assert r.cost_usd == 0.03
      assert r.result == "opened PR"
    end
  end

  describe "error/2" do
    test "builds an Error of the given kind" do
      assert error(:timeout) == %Error{kind: :timeout}
    end

    test "forwards opts (reason, message) to Error.new/2" do
      e = error(:auth, reason: :rate_limit)

      assert e.kind == :auth
      assert e.reason == :rate_limit
    end
  end

  describe "respond/1" do
    test "a string builds a query_fun that succeeds through run/2" do
      assert {:ok, %Result{result: "done"}} =
               ObanClaude.run(%{"prompt" => "x"}, query_fun: respond("done"))
    end

    test "accepts a prebuilt %Result{} (e.g. from structured_result/2)" do
      qf = respond(structured_result(%{"outcome" => "blocked"}))

      assert {:ok, result} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
      assert ObanClaude.outcome(result) == "blocked"
    end
  end

  describe "fail/1" do
    test "a kind atom builds a query_fun that fails, classified by the default mapping" do
      assert {{:cancel, :auth}, %Error{kind: :auth}} =
               ObanClaude.run(%{"prompt" => "x"}, query_fun: fail(:auth))
    end

    test "accepts a prebuilt %Error{} (kind + reason), so the classifier can branch on it" do
      qf = fail(error(:auth, reason: :rate_limit))

      # :auth + :rate_limit retries (bounded), rather than the plain :auth cancel.
      assert {{:error, :rate_limit}, %Error{reason: :rate_limit}} =
               ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
    end
  end

  describe "sequence/1" do
    test "returns each scripted value in turn (fail then succeed, a retry path)" do
      qf = sequence([error(:auth, reason: :rate_limit), "done"])

      assert {{:error, :rate_limit}, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
      assert {:ok, %Result{result: "done"}} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
    end

    test "coerces mixed structs and shorthands" do
      qf = sequence([result("first"), :timeout, structured_result(%{"n" => 1})])

      assert {:ok, %Result{result: "first"}} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
      assert {{:error, :timeout}, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
      assert {:ok, r} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
      assert ObanClaude.structured(r) == %{"n" => 1}
    end

    test "raises when the script is exhausted rather than reusing the last value" do
      qf = sequence(["only one"])

      assert {:ok, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)

      assert_raise RuntimeError, ~r/exhausted/, fn ->
        ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
      end
    end
  end
end
