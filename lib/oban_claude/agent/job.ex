defmodule ObanClaude.Agent.Job do
  @moduledoc """
  The default Oban worker for agent turns: runs claude, then routes the
  outcome back to the owning `ObanClaude.Agent.Instance`.

  The owning agent's id rides in the job's meta (`"agent_id"`), where
  `ObanClaude.Agent.Instance` puts it at enqueue time. `max_attempts: 1` keeps
  every Oban outcome terminal from the state machine's point of view -- a
  retry would otherwise report multiple `{:job_finished, ...}` events for one
  logical turn. A job without an `"agent_id"` (enqueued by hand) runs normally
  and reports to no one.
  """

  use ObanClaude.Worker, queue: :agents, max_attempts: 1

  @impl ObanClaude.Worker
  def handle_result(result, %Oban.Job{meta: %{"agent_id" => agent_id}}) do
    ObanClaude.Agent.job_finished(agent_id, {:ok, result})
    :ok
  end

  def handle_result(_result, _job), do: :ok

  @impl ObanClaude.Worker
  def handle_error(oban_return, payload, %Oban.Job{meta: %{"agent_id" => agent_id}}) do
    ObanClaude.Agent.job_finished(agent_id, {:error, oban_return, payload})
    oban_return
  end

  def handle_error(oban_return, _payload, _job), do: oban_return
end
