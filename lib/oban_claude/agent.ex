defmodule ObanClaude.Agent do
  @moduledoc """
  A facade over long-lived agent processes whose turns run as Oban jobs.

  > #### Experimental {: .warning}
  >
  > The agent layer is the stateful floor above the stateless `ObanClaude`
  > seam. It is opt-in (nothing runs unless `ObanClaude.Agent.Supervisor` is
  > in your tree) and experimental: the API may change, and the layer may
  > move to a sibling package.

  One agent is one `ObanClaude.Agent.Instance` (`:gen_statem`) registered
  under a caller-chosen id. A prompt does not block on claude: it enqueues an
  `ObanClaude.Worker` job and the state machine parks in `:running` until the
  worker reports back through `job_finished/2`. All interaction goes through
  this module; nothing here messages a process that is not running.

      {:ok, _pid} = ObanClaude.Agent.start_agent("triage-7",
        args: ObanClaude.Args.defaults(model: "sonnet"))

      :processing = ObanClaude.Agent.submit_prompt("triage-7", "triage the new issues")
      {:ok, :running} = ObanClaude.Agent.status("triage-7")

      {:ok, {:awaiting_permission, %{id: id}}} =
        ObanClaude.Agent.await("triage-7", [:idle, :awaiting_permission, :waiting_for_user])
      :processing = ObanClaude.Agent.approve_action("triage-7", id)

  Requires `ObanClaude.Agent.Supervisor` in the host supervision tree.
  """

  @registry ObanClaude.Agent.Registry
  @supervisor ObanClaude.Agent.InstanceSupervisor

  @typedoc "The caller-chosen agent identity, unique per running agent."
  @type agent_id :: term()

  @typedoc """
  What `status/1` returns: a bare state atom, except the two gated states,
  which atomically carry what they are gated on (the action map holds the
  `:id` that `approve_action/2` / `reject_action/3` take). `:offline` when the
  agent is not running.
  """
  @type status ::
          :idle
          | :running
          | :paused
          | :offline
          | {:awaiting_permission, %{id: String.t(), description: String.t()}}
          | {:waiting_for_user, String.t() | nil}

  @doc """
  Spawn a new agent under the dynamic supervisor.

  Starting an id that is already running returns the existing pid, so the call
  is idempotent. See `ObanClaude.Agent.Instance` for the config keys.
  """
  @spec start_agent(agent_id(), keyword() | map()) :: {:ok, pid()} | {:error, term()}
  def start_agent(agent_id, config \\ []) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {ObanClaude.Agent.Instance, {agent_id, config}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @doc "Cleanly stop a running agent (`:transient`, so it is not restarted)."
  @spec stop_agent(agent_id()) :: :ok | {:error, :agent_not_running}
  def stop_agent(agent_id) do
    with_agent(agent_id, &:gen_statem.stop/1)
  end

  @doc """
  Read the agent's lifecycle status from registry metadata, without messaging
  the process: one atomic read of the state *and*, in the gated states, the
  pending action or question it is gated on -- so there is no torn
  status-then-payload sequence.

      {:ok, :running} = status("live")
      {:ok, {:awaiting_permission, %{id: id, description: d}}} = status("live")
      {:ok, {:waiting_for_user, question}} = status("live")

  An unknown or stopped agent reads as `{:ok, :offline}`. Registry cleanup
  after a process death is asynchronous, so `:offline` after `stop_agent/1`
  is eventually-consistent -- `await(id, :offline)` if you need to block on it.
  """
  @spec status(agent_id()) :: {:ok, status()}
  def status(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{_pid, value}] -> {:ok, value}
      [] -> {:ok, :offline}
    end
  end

  @doc """
  Block until the agent settles into one of `states` (a state atom or list of
  them), returning the full `t:status/0` it landed on -- so a gated state
  arrives with its payload:

      case ObanClaude.Agent.await("live", [:idle, :awaiting_permission], 300_000) do
        {:ok, {:awaiting_permission, %{id: id}}} -> ObanClaude.Agent.approve_action("live", id)
        {:ok, :idle} -> :done
      end

  Polls the registry (25ms), so it never messages the agent. `:offline` is
  awaitable (e.g. after `stop_agent/1`). Returns `{:error, :timeout}` when the
  deadline passes first.
  """
  @spec await(agent_id(), atom() | [atom()], timeout :: pos_integer()) ::
          {:ok, status()} | {:error, :timeout}
  def await(agent_id, states, timeout \\ 60_000) do
    states = List.wrap(states)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_await(agent_id, states, deadline)
  end

  @doc """
  Send a prompt to a running agent. Synchronous: replies `:processing` once the
  turn's Oban job is enqueued.

  In `:running` and `:awaiting_permission` the call blocks (the machine
  postpones it) until the turn finishes / the gate clears; in
  `:waiting_for_user` the prompt is the answer to the pending question and
  resumes the claude session.
  """
  @spec submit_prompt(agent_id(), String.t()) :: :processing | {:error, term()}
  def submit_prompt(agent_id, prompt), do: call(agent_id, {:user_prompt, prompt})

  @doc """
  The fire-and-forget form of `submit_prompt/2`: never blocks the caller.

  Returns `:ok` as soon as the cast is sent -- there is no `:processing`
  acknowledgment and no error reply on a failed enqueue (that lands in
  `history/1` as `{:enqueue_failed, reason}`). State handling matches
  `submit_prompt/2` -- queued in `:running` / `:awaiting_permission`, the
  answer in `:waiting_for_user` -- except `:paused`, where the prompt is
  dropped (recorded as `{:dropped_prompt, text}`) since lockdown has no caller
  to refuse. Use this from callers that must not block on a busy agent (a
  LiveView event handler); use `submit_prompt/2` when you want backpressure
  and the enqueue acknowledgment.
  """
  @spec cast_prompt(agent_id(), String.t()) :: :ok | {:error, :agent_not_running}
  def cast_prompt(agent_id, prompt) do
    with_agent(agent_id, &:gen_statem.cast(&1, {:user_prompt, prompt}))
  end

  @doc """
  Approve the pending action by id (read it off `status/1` or `await/3`).

  The continuation turn resumes the claude session with the approved action as
  its prompt, and carries the agent's `:approved_args` (e.g. a
  `permission_mode` elevation) merged over the default args -- so approval
  actually unlocks the tools the action needs, on that turn only.
  """
  @spec approve_action(agent_id(), String.t()) :: :processing | {:error, term()}
  def approve_action(agent_id, action_id), do: call(agent_id, {:approve_action, action_id})

  @doc "Reject the pending action: the denial is recorded and the agent returns to `:idle`."
  @spec reject_action(agent_id(), String.t(), String.t()) :: :rejected | {:error, term()}
  def reject_action(agent_id, action_id, reason \\ "denied") do
    call(agent_id, {:reject_action, action_id, reason})
  end

  @doc "Asynchronously force the agent into `:paused` lockdown, from any state. Drops any pending action or question."
  @spec emergency_pause(agent_id()) :: :ok | {:error, :agent_not_running}
  def emergency_pause(agent_id) do
    with_agent(agent_id, &:gen_statem.cast(&1, :emergency_pause))
  end

  @doc "Release a `:paused` agent back to `:idle`."
  @spec resume_agent(agent_id()) :: :resumed | {:error, term()}
  def resume_agent(agent_id), do: call(agent_id, :resume)

  @doc """
  The agent's bookkeeping in one map: `:state`, `:session_id`, `:turns`,
  accumulated `:cost_usd`, and any `:pending_action` / `:pending_question`.
  A call into the process (unlike `status/1`); works in every state.
  """
  @spec info(agent_id()) :: {:ok, map()} | {:error, :agent_not_running}
  def info(agent_id), do: call(agent_id, :info)

  @doc """
  The agent's event log, oldest first. Works in every state. Result entries
  are `{:result, structured_output_map}` for `--json-schema` turns and
  `{:result, text}` otherwise.
  """
  @spec history(agent_id()) :: {:ok, list()} | {:error, :agent_not_running}
  def history(agent_id), do: call(agent_id, :history)

  @doc """
  The return path for workers: report a finished turn back to its agent.

  `ObanClaude.Agent.Job` calls this from `handle_result/2` /
  `handle_error/3` with the `agent_id` it read off the job's meta. Payload
  shapes: `{:ok, %ClaudeWrapper.Result{}}` on success, or
  `{:error, oban_return, payload}` for a failed turn. Fire-and-forget: if the
  agent is gone the outcome is dropped.
  """
  @spec job_finished(agent_id(), {:ok, ClaudeWrapper.Result.t()} | {:error, term(), term()}) ::
          :ok | {:error, :agent_not_running}
  def job_finished(agent_id, payload) do
    with_agent(agent_id, &:gen_statem.cast(&1, {:job_finished, payload}))
  end

  @doc """
  The retry half of the return path: report a failed-but-retryable attempt.

  `ObanClaude.Agent.Job`'s error callback calls this when Oban will re-run
  the job (an `{:error, _}` with attempts remaining, or a `{:snooze, _}`). The
  machine stays in `:running` -- the logical turn is still in flight -- records
  `{:retrying, retry}` in history, and re-arms the `:job_timeout` watchdog to
  cover the retry's backoff plus execution. `retry` is
  `%{attempt:, max_attempts:, verdict:}`. Fire-and-forget, like
  `job_finished/2`.
  """
  @spec job_retrying(agent_id(), map()) :: :ok | {:error, :agent_not_running}
  def job_retrying(agent_id, retry) do
    with_agent(agent_id, &:gen_statem.cast(&1, {:job_retrying, retry}))
  end

  defp poll_await(agent_id, states, deadline) do
    {:ok, current} = status(agent_id)

    cond do
      status_state(current) in states ->
        {:ok, current}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(25)
        poll_await(agent_id, states, deadline)
    end
  end

  defp status_state({state, _payload}), do: state
  defp status_state(state) when is_atom(state), do: state

  defp call(agent_id, request), do: with_agent(agent_id, &:gen_statem.call(&1, request))

  defp with_agent(agent_id, fun) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _state}] -> fun.(pid)
      [] -> {:error, :agent_not_running}
    end
  end
end
