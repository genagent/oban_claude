defmodule ObanClaude.Worker do
  @moduledoc """
  Define an Oban worker that runs a claude job.

  A worker is a task definition; a job is one instance of it. The claude args are
  a merge of worker-level defaults (`:args`) and the per-job args, the job winning
  on conflicts. That spans a spectrum from one mechanism:

    * no defaults -> the job carries everything (a bare Oban-to-claude passthrough)
    * fixed config in the worker, the variable input in the job (the common case)
    * everything in the worker, an empty job -> a routine, e.g. scheduled with
      `Oban.Plugins.Cron`

  ## Example

      defmodule MyApp.PrReview do
        use ObanClaude.Worker,
          queue: :review,
          max_attempts: 3,
          args: ObanClaude.Args.defaults(model: "sonnet", system_prompt: "Review the pull request.")

        @impl ObanClaude.Worker
        def handle_result(result, _job) do
          case ObanClaude.outcome(result) do
            "blocked" -> {:cancel, :blocked}
            _ -> :ok
          end
        end
      end

      # the job is just the instance:
      MyApp.PrReview.new(ObanClaude.Args.new(prompt: "PR #4321: " <> diff))
      |> Oban.insert()

  `use ObanClaude.Worker` accepts every `Oban.Worker` option (`:queue`,
  `:max_attempts`, `:unique`, `:priority`, ...) plus:

    * `:args` -- a map of default claude args, merged under each job's args (the
      job wins). Defaults to `%{}`. Build it with `ObanClaude.Args.defaults/1`
      (prompt-optional; evaluates at compile time) or write the string map
      directly. It may reference module attributes defined before `use`.
    * `:classifier` -- a `t:ObanClaude.classifier/0`, the outcome -> Oban-return
      mapping (see `ObanClaude.Outcome`), forwarded to `ObanClaude.run/2`. It
      must return the `{oban_return, payload}` envelope (e.g.
      `{{:cancel, :blocked}, error}`), not a flat verdict like `{:cancel, :blocked}` --
      `run/2` raises on the latter, which Oban would otherwise treat as success.
    * `:query_fun` -- a `t:ObanClaude.query_fun/0`, the claude entrypoint
      (defaults to `&ClaudeWrapper.query/2`), forwarded to `ObanClaude.run/2`;
      override to stub claude in tests.

  It injects a `perform/1` that merges the worker defaults under the job args, runs
  `ObanClaude.run/2`, calls `c:handle_result/2` on success, and passes a
  claude-level `{:error,...}` / `{:cancel,...}` / `{:snooze,...}` straight through
  to Oban. Both `perform/1` and `handle_result/2` are overridable.
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
    {oc_opts, oban_opts} = Keyword.split(opts, [:classifier, :query_fun, :args])
    {default_args, run_opts} = Keyword.pop(oc_opts, :args, Macro.escape(%{}))

    quote location: :keep do
      use Oban.Worker, unquote(oban_opts)
      @behaviour ObanClaude.Worker

      @oban_claude_opts unquote(run_opts)
      @oban_claude_default_args unquote(default_args)

      @impl Oban.Worker
      def perform(%Oban.Job{args: args} = job) do
        merged = Map.merge(@oban_claude_default_args, args)

        case ObanClaude.run(merged, @oban_claude_opts) do
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
