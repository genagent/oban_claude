# A worker whose handle_result/2 proves the override fired and saw a real
# %Result{}, by returning a verdict derived from it. Defined at the top level so
# the macro expands once, regardless of the :live tag.
defmodule ObanClaude.LiveTest.EchoWorker do
  use ObanClaude.Worker,
    queue: :live_test,
    max_attempts: 1,
    args: %{"model" => "haiku", "max_turns" => 3}

  @impl ObanClaude.Worker
  def handle_result(result, _job), do: {:cancel, {:handled, result.is_error}}
end

defmodule ObanClaude.LiveTest do
  # Real, paid claude calls. Excluded by default (see test_helper.exs); run with:
  #
  #   mix test --only live
  #
  # These assert the SEAM only -- the shape oban_claude maps, the json_schema ->
  # structured/1 round-trip, and the worker perform/1 path -- never model content,
  # which is non-deterministic. claude_wrapper already covers the CLI mechanics.
  use ExUnit.Case, async: false

  @moduletag :live
  # Real calls are slower than the 60s ExUnit default.
  @moduletag timeout: 120_000

  alias ClaudeWrapper.Result
  alias ObanClaude.LiveTest.EchoWorker

  test "run/2 maps a real claude call to {:ok, %Result{}}" do
    args = %{
      "prompt" => "Reply with exactly the word OK and nothing else.",
      "model" => "haiku",
      "max_turns" => 3
    }

    # Default query_fun -> the real ClaudeWrapper.query/2.
    assert {:ok, %Result{} = result} = ObanClaude.run(args)

    refute result.is_error
    assert is_binary(result.result) and result.result != ""

    IO.puts("""

    live result:
      result:     #{inspect(result.result)}
      cost_usd:   #{inspect(result.cost_usd)}
      num_turns:  #{inspect(result.num_turns)}
      session_id: #{inspect(result.session_id)}
    """)
  end

  test "run/2 round-trips structured output from a --json-schema run" do
    # An enum-constrained schema makes the result deterministic enough to assert.
    schema =
      Jason.encode!(%{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{"outcome" => %{"enum" => ["done"]}},
        "required" => ["outcome"]
      })

    args = %{
      "prompt" => "Set outcome to done.",
      "model" => "haiku",
      "max_turns" => 3,
      "json_schema" => schema
    }

    assert {:ok, %Result{} = result} = ObanClaude.run(args)
    refute result.is_error

    # The whole point: oban_claude reads the typed object back off the result.
    assert ObanClaude.outcome(result) == "done"
    assert match?(%{"outcome" => "done"}, ObanClaude.structured(result))
  end

  test "a worker's perform/1 runs a real call and reaches handle_result/2" do
    # Build a job directly (no Oban instance). perform/1 merges the worker
    # defaults under the job args, runs the real call, and calls handle_result/2,
    # which returns a verdict derived from the live %Result{}.
    job = %Oban.Job{args: %{"prompt" => "Reply with exactly the word OK."}}

    assert {:cancel, {:handled, false}} = EchoWorker.perform(job)
  end
end
