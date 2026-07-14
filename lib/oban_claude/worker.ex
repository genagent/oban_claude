defmodule ObanClaude.Worker do
  @moduledoc """
  Define an Oban worker that runs a claude job.

  A worker is a task definition; a job is one instance of it. The claude args are
  a merge of worker-level defaults (`:args`) and the per-job args, the job winning
  on conflicts -- except worker-level `:pinned_args`, which win over the job (a
  guardrail for keys a job must not override). That spans a spectrum from one
  mechanism:

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
      directly. It may reference module attributes defined before `use`. Keys
      must be strings (atom keys raise at compile time -- they would otherwise be
      silently dropped by the string-keyed merge).
    * `:pinned_args` -- a map of claude args merged *over* each job's args, so
      these keys are worker-invariant (they win even when a job supplies the same
      key). Defaults to `%{}`; same build/key rules as `:args`. Precedence is
      `pinned_args > job args > args`. Use it to pin security-relevant keys a job
      must not override -- `permission_mode`, `mcp_config`, `max_budget_usd`,
      tool allow/deny lists -- which matters when job args come from an external
      or semi-trusted source (a webhook, an exposed enqueue API).
    * `:classifier` -- a `t:ObanClaude.classifier/0`, the outcome -> Oban-return
      mapping (see `ObanClaude.Outcome`), forwarded to `ObanClaude.run/2`. It
      must return the `{oban_return, payload}` envelope (e.g.
      `{{:cancel, :blocked}, error}`), not a flat verdict like `{:cancel, :blocked}` --
      `run/2` raises on the latter, which Oban would otherwise treat as success.
    * `:query_fun` -- a `t:ObanClaude.query_fun/0`, the claude entrypoint
      (defaults to `&ClaudeWrapper.query/2`), forwarded to `ObanClaude.run/2`;
      override to stub claude in tests.

  It injects a `perform/1` that merges the args (`pinned_args > job > args`), runs
  `ObanClaude.run/2`, calls `c:handle_result/2` on success, and routes every
  non-`:ok` verdict (`{:error,...}` / `{:cancel,...}` / `{:snooze,...}`) through
  `c:handle_error/3` with the run's payload (default: pass the verdict straight to
  Oban). A deterministic args fault (a missing prompt, an unknown
  `permission_mode`) becomes `{:cancel, {:invalid_args, message}}` rather than a
  raise, so a malformed stored job dead-letters at once instead of retrying to
  exhaustion (the message omits the arg values). `perform/1`, `handle_result/2`,
  and `handle_error/3` are all overridable.
  """

  alias ClaudeWrapper.{Error, Result}

  @doc """
  Called with the successful `%ClaudeWrapper.Result{}` and the `Oban.Job`.

  Return any `t:ObanClaude.oban_return/0`. The default returns `:ok`. Override to
  branch on `ObanClaude.outcome/1`, persist `result.cost_usd` / `result.session_id`,
  or enqueue a follow-on effector job (the "dispose" half of propose/dispose).
  """
  @callback handle_result(Result.t(), Oban.Job.t()) :: ObanClaude.oban_return()

  @doc """
  Called on every **non-`:ok`** verdict, with the classifier's Oban return, the
  run's payload, and the `Oban.Job`. The error-path mirror of `handle_result/2`.

  The default returns `oban_return` unchanged -- so a worker that does not
  override it behaves exactly as before (the verdict passes straight to Oban).
  Override it to react to the failure with the payload in hand, which `run/2`'s
  return would otherwise drop:

    * read `ObanClaude.session_id/1` / `ObanClaude.cost_usd/1` off a rail-stop
      `%Error{}` to persist spend and enqueue a `resume:` continuation (see the
      "session-resume handoff" pattern in the Agent worker patterns guide);
    * make the verdict job-aware -- e.g. bound a snooze on a `job.meta` counter,
      or dead-letter on the final `job.attempt`.

  Return any `t:ObanClaude.oban_return/0`. Returning `oban_return` unchanged
  keeps the classifier's decision; returning a different verdict overrides it.
  Unlike `handle_result/2`, this fires for `{:error, _}`, `{:cancel, _}`, and
  `{:snooze, _}` -- the verdict is the first argument so a clause can match on it.
  """
  @callback handle_error(
              ObanClaude.oban_return(),
              Error.t() | Result.t() | term(),
              Oban.Job.t()
            ) :: ObanClaude.oban_return()

  defmacro __using__(opts) do
    {oc_opts, oban_opts} = Keyword.split(opts, [:classifier, :query_fun, :args, :pinned_args])
    {default_args, oc_opts} = Keyword.pop(oc_opts, :args, Macro.escape(%{}))
    {pinned_args, run_opts} = Keyword.pop(oc_opts, :pinned_args, Macro.escape(%{}))

    quote location: :keep do
      use Oban.Worker, unquote(oban_opts)
      @behaviour ObanClaude.Worker

      @oban_claude_opts unquote(run_opts)
      @oban_claude_default_args unquote(default_args)
      @oban_claude_pinned_args unquote(pinned_args)

      # Fail fast at compile time: worker arg maps must be string-keyed. Atom
      # keys would be silently dropped by the string-keyed merge/build (#75).
      ObanClaude.Worker.__validate_arg_keys__!(__MODULE__, :args, @oban_claude_default_args)
      ObanClaude.Worker.__validate_arg_keys__!(__MODULE__, :pinned_args, @oban_claude_pinned_args)

      @impl Oban.Worker
      def perform(%Oban.Job{args: args} = job) do
        # Precedence: pinned args (worker-invariant) > job args > plain defaults.
        merged =
          @oban_claude_default_args
          |> Map.merge(args)
          |> Map.merge(@oban_claude_pinned_args)

        case ObanClaude.Worker.__run__(merged, @oban_claude_opts, job) do
          {:ok, %ClaudeWrapper.Result{} = result} -> handle_result(result, job)
          {oban_return, payload} -> handle_error(oban_return, payload, job)
        end
      end

      @impl ObanClaude.Worker
      def handle_result(_result, _job), do: :ok

      @impl ObanClaude.Worker
      def handle_error(oban_return, _payload, _job), do: oban_return

      defoverridable handle_result: 2, handle_error: 3, perform: 1
    end
  end

  @doc false
  # Compile-time guard for `:args` / `:pinned_args`: their keys must be strings,
  # or the string-keyed merge in `perform/1` and `build/1` silently drops them.
  def __validate_arg_keys__!(module, opt, args) when is_map(args) do
    case Enum.reject(Map.keys(args), &is_binary/1) do
      [] ->
        :ok

      bad ->
        raise ArgumentError,
              "#{inspect(module)}: `#{opt}` keys must be strings, got non-string " <>
                "#{inspect(bad)}. Build the map with ObanClaude.Args.defaults/1 " <>
                "(atom keys in, string map out) rather than writing atom keys."
    end
  end

  @doc false
  # Runs `ObanClaude.run/2`, converting the deterministic build faults it raises
  # (a missing prompt, an unknown permission_mode/effort/hermetic) into an
  # immediate `{:cancel, {:invalid_args, message}}` (#75). Without this the raise
  # is a retryable failure, so Oban re-runs the job with the same broken args to
  # exhaustion -- and stores the raw args map (prompt, system prompt, meta) in
  # `oban_jobs.errors`. The message deliberately omits the arg values.
  def __run__(args, opts, job) do
    ObanClaude.run(args, Keyword.put(opts, :job, job))
  rescue
    e in KeyError -> {{:cancel, {:invalid_args, "missing required arg #{inspect(e.key)}"}}, e}
    e in ArgumentError -> {{:cancel, {:invalid_args, Exception.message(e)}}, e}
  end
end
