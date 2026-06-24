defmodule ObanClaude.LiveTest do
  # A real, paid claude call. Excluded by default (see test_helper.exs); run with:
  #
  #   mix test --only live
  #
  # Asserts MECHANICS only -- that the un-stubbed ClaudeWrapper.query/2 path
  # returns the {:ok, %Result{}} shape oban_claude maps. Never asserts model
  # content, which is non-deterministic.
  use ExUnit.Case, async: false

  @moduletag :live
  # Real calls are slower than the 60s ExUnit default.
  @moduletag timeout: 120_000

  alias ClaudeWrapper.Result

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
end
