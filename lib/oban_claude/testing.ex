defmodule ObanClaude.Testing do
  @moduledoc """
  Build the values a `:query_fun` returns, without knowing `claude_wrapper`'s
  struct shapes.

  `ObanClaude.run/2` and `ObanClaude.Worker` call claude through a `:query_fun`
  (`t:ObanClaude.query_fun/0`): a 2-arity `(prompt, opts)` returning
  `{:ok, %ClaudeWrapper.Result{}}` or `{:error, %ClaudeWrapper.Error{}}`. In a
  test you pass a stub `:query_fun` so no real (paid) claude call happens.

  Hand-writing that stub means knowing wrapper internals: success is a
  `%Result{is_error: false}`; structured output lives at
  `extra["structured_output"]` (where `ObanClaude.structured/1` and
  `ObanClaude.outcome/1` read it); a failure carries a `%Error{kind: ...}` from
  claude_wrapper's kind vocabulary. This module is those stubs, written once, so
  a shift in that representation surfaces here rather than silently in every
  consumer's tests.

  ## Value builders

  Return the bare wrapper structs -- for a hand-written `:query_fun`, or to feed
  `handle_result/2` / `ObanClaude.structured/1` directly in a unit test:

    * `result/1` -- a success `%Result{}`
    * `structured_result/2` -- a `%Result{}` carrying structured output
    * `error/2` -- an `%Error{}` of a given kind

  ## query_fun builders

  Return a ready `:query_fun` (a 2-arity function):

    * `respond/1` -- always succeeds with a result (or a plain string)
    * `fail/1` -- always fails with an error (or a plain kind atom)
    * `sequence/1` -- returns each scripted value in turn, for retry tests

  ## Examples

  Through the full seam with `ObanClaude.run/2`:

      import ObanClaude.Testing

      test "a clean result classifies to {:ok, result}" do
        assert {:ok, %Result{result: "done"}} =
                 ObanClaude.run(%{"prompt" => "x"}, query_fun: respond("done"))
      end

      test "an auth failure cancels" do
        assert {{:cancel, :auth}, _} =
                 ObanClaude.run(%{"prompt" => "x"}, query_fun: fail(:auth))
      end

  Structured output a `handle_result/2` can read back:

      test "reads the structured verdict" do
        result = structured_result(%{"outcome" => "blocked"})
        assert ObanClaude.outcome(result) == "blocked"
      end

  A worker's retry path, scripting one failure then a success:

      qf = sequence([error(:auth, reason: :rate_limit), "done"])
      assert {{:error, :rate_limit}, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)
      assert {:ok, %Result{result: "done"}} = ObanClaude.run(%{"prompt" => "x"}, query_fun: qf)

  > #### Only a `:query_fun` runtime value {: .info}
  >
  > `respond/1`, `fail/1`, and `sequence/1` return function *values*, so pass
  > them to `ObanClaude.run/2` (or a worker's `perform`) at runtime. The
  > `use ObanClaude.Worker, query_fun: ...` option is captured at compile time
  > and needs a function *capture* (`&Mod.fun/2`) -- have that named function
  > build its return with `result/1`/`error/2` instead.
  """

  alias ClaudeWrapper.{Error, Result}

  @typedoc "What `respond/1` (and `sequence/1`) accept: a `%Result{}` or a plain result string."
  @type respondable :: Result.t() | String.t()

  @typedoc "What `fail/1` (and `sequence/1`) accept: an `%Error{}` or a plain error-kind atom."
  @type failable :: Error.t() | Error.kind()

  @doc """
  A success `%ClaudeWrapper.Result{}`.

  Pass a plain string for the result text, or a keyword list to set other fields
  (`:result`, `:cost_usd`, `:num_turns`, `:session_id`, `:duration_ms`).

      ObanClaude.Testing.result("done")
      ObanClaude.Testing.result(result: "done", cost_usd: 0.01, num_turns: 2)
  """
  @spec result(String.t() | keyword()) :: Result.t()
  def result(text_or_opts \\ "")
  def result(text) when is_binary(text), do: %Result{result: text, is_error: false}
  def result(opts) when is_list(opts), do: struct(%Result{is_error: false}, opts)

  @doc """
  A success `%Result{}` carrying `data` as its structured output.

  `data` is planted at `extra["structured_output"]`, exactly where
  `ObanClaude.structured/1` and `ObanClaude.outcome/1` read it. `opts` sets the
  other `Result` fields, as in `result/1`.

      ObanClaude.Testing.structured_result(%{"outcome" => "blocked"})
      ObanClaude.Testing.structured_result(%{"pr" => 42}, cost_usd: 0.03)
  """
  @spec structured_result(map() | list(), keyword()) :: Result.t()
  def structured_result(data, opts \\ [])
      when (is_map(data) or is_list(data)) and is_list(opts) do
    opts |> result() |> Map.update!(:extra, &Map.put(&1, "structured_output", data))
  end

  @doc """
  An error `%ClaudeWrapper.Error{}` of `kind`.

  `opts` are forwarded to `ClaudeWrapper.Error.new/2` (`:reason`, `:message`,
  `:exit_code`, `:stdout`, `:stderr`).

      ObanClaude.Testing.error(:timeout)
      ObanClaude.Testing.error(:auth, reason: :rate_limit)
  """
  @spec error(Error.kind(), keyword()) :: Error.t()
  def error(kind, opts \\ []) when is_atom(kind), do: Error.new(kind, opts)

  @doc """
  A `:query_fun` that always succeeds, returning `{:ok, result}`.

  `resp` is a `%Result{}` (from `result/1` or `structured_result/2`) or a plain
  string (shorthand for `result(string)`).

      ObanClaude.run(args, query_fun: ObanClaude.Testing.respond("done"))
  """
  @spec respond(respondable()) :: ObanClaude.query_fun()
  def respond(resp) do
    ok = {:ok, to_result(resp)}
    fn _prompt, _opts -> ok end
  end

  @doc """
  A `:query_fun` that always fails, returning `{:error, error}`.

  `err` is an `%Error{}` (from `error/2`) or a plain kind atom (shorthand for
  `error(kind)`).

      ObanClaude.run(args, query_fun: ObanClaude.Testing.fail(:auth))
  """
  @spec fail(failable()) :: ObanClaude.query_fun()
  def fail(err) do
    error = {:error, to_error(err)}
    fn _prompt, _opts -> error end
  end

  @doc """
  A `:query_fun` that returns each of `values` in turn: call 1 gets the first,
  call 2 the second, and so on. For retry tests, where a worker's first attempt
  fails and a later one succeeds.

  Each value is coerced as in `respond/1`/`fail/1`: a `%Result{}` or string
  becomes `{:ok, ...}`; an `%Error{}` or kind atom becomes `{:error, ...}`.
  Raises once the script is exhausted, so a test that runs more attempts than it
  scripted fails loudly rather than silently reusing the last value.

      # attempt 1 rate-limited, attempt 2 succeeds
      qf = ObanClaude.Testing.sequence([ObanClaude.Testing.error(:auth, reason: :rate_limit), "done"])

  Backed by an `Agent` linked to the calling process, so call it from the test
  process (not a compile-time `use` default).
  """
  @spec sequence([respondable() | failable()]) :: ObanClaude.query_fun()
  def sequence(values) when is_list(values) do
    scripted = Enum.map(values, &coerce/1)
    {:ok, agent} = Agent.start_link(fn -> scripted end)
    count = length(values)

    fn _prompt, _opts -> next_scripted(agent, count) end
  end

  # Pop the next scripted return, raising in the CALLER (not inside the Agent)
  # once the script is exhausted, so it surfaces as a normal error.
  defp next_scripted(agent, count) do
    case Agent.get_and_update(agent, &pop/1) do
      {:queued, value} ->
        value

      :exhausted ->
        raise "ObanClaude.Testing.sequence/1 exhausted: scripted #{count} " <>
                "response(s) but the query_fun was called again"
    end
  end

  defp pop([next | rest]), do: {{:queued, next}, rest}
  defp pop([]), do: {:exhausted, []}

  defp to_result(%Result{} = result), do: result
  defp to_result(text) when is_binary(text), do: result(text)

  defp to_error(%Error{} = error), do: error
  defp to_error(kind) when is_atom(kind), do: error(kind)

  # A bare atom is an error kind; a string is a result. Anything already a
  # struct keeps its ok/error sense.
  defp coerce(%Result{} = result), do: {:ok, result}
  defp coerce(%Error{} = error), do: {:error, error}
  defp coerce(text) when is_binary(text), do: {:ok, result(text)}
  defp coerce(kind) when is_atom(kind), do: {:error, error(kind)}
end
