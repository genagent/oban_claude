defmodule ObanClaude.Worker do
  @moduledoc """
  Define an Oban worker that runs a claude job.

      defmodule MyApp.ClaudeJob do
        use ObanClaude.Worker, queue: :claude, max_attempts: 3

        # Optional: inspect the successful result and decide the final atom.
        # Default implementation just returns `:ok`.
        @impl ObanClaude.Worker
        def handle_result(result, _job) do
          case ObanClaude.outcome(result) do
            "blocked" -> {:cancel, :blocked}
            _ -> :ok
          end
        end
      end

  `use ObanClaude.Worker` accepts every `Oban.Worker` option (`:queue`,
  `:max_attempts`, `:unique`, `:priority`, ...) plus these, forwarded to
  `ObanClaude.run/2`:

    * `:classifier` -- the outcome -> Oban-return mapping (see `ObanClaude.Outcome`).
    * `:query_fun` -- the claude entrypoint (defaults to `&ClaudeWrapper.query/2`);
      override to stub claude in tests.

  It injects a `perform/1` that runs `ObanClaude.run/2` on the job args, calls
  `c:handle_result/2` on success, and passes a claude-level
  `{:error,...}` / `{:cancel,...}` / `{:snooze,...}` straight through to Oban.
  Both `perform/1` and `handle_result/2` are overridable.
  """

  alias ClaudeWrapper.Result

  @doc """
  Called with the successful `%ClaudeWrapper.Result{}` and the `Oban.Job`.

  Return any `t:ObanClaude.oban_return/0`. The default returns `:ok`. Override to
  branch on `ObanClaude.outcome/1`, persist `result.cost_usd` / `result.session_id`,
  or enqueue a follow-on effector job (the "dispose" half of propose/dispose).
  """
  @callback handle_result(Result.t(), Oban.Job.t()) :: ObanClaude.oban_return()

  defmacro __using__(opts) do
    {oc_opts, oban_opts} = Keyword.split(opts, [:classifier, :query_fun])

    quote location: :keep do
      use Oban.Worker, unquote(oban_opts)
      @behaviour ObanClaude.Worker

      @oban_claude_opts unquote(oc_opts)

      @impl Oban.Worker
      def perform(%Oban.Job{args: args} = job) do
        case ObanClaude.run(args, @oban_claude_opts) do
          {:ok, %ClaudeWrapper.Result{} = result} -> handle_result(result, job)
          {oban_return, _payload} -> oban_return
        end
      end

      @impl ObanClaude.Worker
      def handle_result(_result, _job), do: :ok

      defoverridable handle_result: 2, perform: 1
    end
  end
end
