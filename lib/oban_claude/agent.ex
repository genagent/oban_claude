defmodule ObanClaude.Agent do
  @moduledoc """
  A facade over long-lived agent processes whose turns run as Oban jobs
  (spike, see PR #115: exploratory API, may change or be extracted).

  One agent is one `ObanClaude.Agent.Instance` (`:gen_statem`) registered
  under a caller-chosen id. A prompt does not block on claude: it enqueues an
  `ObanClaude.Worker` job and the state machine parks in `:running` until the
  worker reports back through `job_finished/2`. All interaction goes through
  this module; nothing here messages a process that is not running.

      {:ok, _pid} = ObanClaude.Agent.start_agent("triage-7",
        args: ObanClaude.Args.defaults(model: "sonnet"))

      :processing = ObanClaude.Agent.submit_prompt("triage-7", "triage the new issues")
      {:ok, :running} = ObanClaude.Agent.get_status("triage-7")

  Requires `ObanClaude.Agent.Supervisor` in the host supervision tree.
  """

  @registry ObanClaude.Agent.Registry
  @supervisor ObanClaude.Agent.InstanceSupervisor

  @typedoc "The caller-chosen agent identity, unique per running agent."
  @type agent_id :: term()

  @typedoc "A lifecycle state as read from the registry (`:offline` when not running)."
  @type status ::
          :idle | :running | :waiting_for_user | :awaiting_permission | :paused | :offline

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
  Read the agent's lifecycle state from registry metadata, without messaging
  the process. An unknown or stopped agent reads as `{:ok, :offline}`.
  """
  @spec get_status(agent_id()) :: {:ok, status()}
  def get_status(agent_id) do
    case Registry.lookup(@registry, agent_id) do
      [{_pid, state}] -> {:ok, state}
      [] -> {:ok, :offline}
    end
  end

  @doc """
  Send a prompt to a running agent. Synchronous: replies `:processing` once the
  turn's Oban job is enqueued.

  In `:running` the call blocks (the machine postpones it) until the in-flight
  turn finishes; in `:waiting_for_user` the prompt is the answer to the
  pending question and resumes the claude session.
  """
  @spec submit_prompt(agent_id(), String.t()) :: :processing | {:error, term()}
  def submit_prompt(agent_id, prompt), do: call(agent_id, {:user_prompt, prompt})

  @doc "Approve the pending action (see `pending/1` for its id). Resumes the session with the approved action as the next turn."
  @spec approve_action(agent_id(), String.t()) :: :processing | {:error, term()}
  def approve_action(agent_id, action_id), do: call(agent_id, {:approve_action, action_id})

  @doc "Reject the pending action: the denial is recorded and the agent returns to `:idle`."
  @spec reject_action(agent_id(), String.t(), String.t()) :: :rejected | {:error, term()}
  def reject_action(agent_id, action_id, reason \\ "denied") do
    call(agent_id, {:reject_action, action_id, reason})
  end

  @doc "Asynchronously force the agent into `:paused` lockdown, from any state."
  @spec emergency_pause(agent_id()) :: :ok | {:error, :agent_not_running}
  def emergency_pause(agent_id) do
    with_agent(agent_id, &:gen_statem.cast(&1, :emergency_pause))
  end

  @doc "Release a `:paused` agent back to `:idle`."
  @spec resume_agent(agent_id()) :: :resumed | {:error, term()}
  def resume_agent(agent_id), do: call(agent_id, :resume)

  @doc "The agent's event log, oldest first. Works in every state."
  @spec history(agent_id()) :: {:ok, list()} | {:error, :agent_not_running}
  def history(agent_id), do: call(agent_id, :history)

  @doc """
  What the agent is waiting on: `%{action: action | nil, question: question | nil}`.
  The action map carries the `:id` that `approve_action/2` / `reject_action/3` take.
  """
  @spec pending(agent_id()) :: {:ok, map()} | {:error, :agent_not_running}
  def pending(agent_id), do: call(agent_id, :pending)

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

  defp call(agent_id, request), do: with_agent(agent_id, &:gen_statem.call(&1, request))

  defp with_agent(agent_id, fun) do
    case Registry.lookup(@registry, agent_id) do
      [{pid, _state}] -> fun.(pid)
      [] -> {:error, :agent_not_running}
    end
  end
end
