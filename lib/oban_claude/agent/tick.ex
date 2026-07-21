defmodule ObanClaude.Agent.Tick do
  @moduledoc """
  The adapter between `Oban.Plugins.Cron` (which schedules at the worker
  layer) and the agent state machine (which owns turn enqueueing): a scheduled
  tick delivers a *prompt* to an agent through the facade, never a claude job
  behind the machine's back.

  Modeled on the "Routines" idea: a routine is a prompt on a schedule, aimed at
  a named agent. The claude turn itself is still enqueued by
  `ObanClaude.Agent.Instance`, so every machine invariant (session threading,
  `:running` + watchdog, approval gating) holds for scheduled work exactly as
  for interactive work.

      {Oban.Plugins.Cron,
       crontab: [
         {"0 9 * * *", ObanClaude.Agent.Tick,
          args: %{
            "agent_id" => "standup",
            "prompt" => "Summarize overnight CI failures.",
            "session" => "fresh",
            "if_offline" => "start",
            "start" => %{"args" => %{"model" => "sonnet"}}
          }}
       ]}

  ## Args

    * `"agent_id"` (required) -- the agent to prompt.
    * `"prompt"` (required) -- the prompt to deliver.
    * `"if_busy"` -- what to do when the agent is not `:idle`:
      * `"skip"` (default) -- cancel this beat (`{:cancel, :agent_busy}`); a
        missed beat is better than a backlog of stale scheduled prompts.
      * `"queue"` -- deliver anyway; the machine queues it behind the
        in-flight turn / pending gate. Beware: on a slow agent a fast
        schedule accumulates a backlog.
    * `"if_offline"` -- what to do when the agent is not running (e.g. after
      a restart):
      * `"skip"` (default) -- cancel this beat (`{:cancel, :agent_not_running}`).
      * `"start"` -- start the agent, then deliver. Config comes from the
        optional `"start"` map -- `"args"`, `"approved_args"`, `"job_timeout"`
        (the JSON-clean subset of `ObanClaude.Agent.Instance` config; a
        custom `:worker` or `:oban` needs the agent started by the host app
        instead). With `"start"` the crontab is effectively the agent's spec.
    * `"session"` -- `"resume"` (default) continues the agent's claude
      session; `"fresh"` starts a new one for this beat. Prefer `"fresh"` for
      long-lived routines, or the session's context (and per-turn cost) grows
      without bound.

  Delivery uses `ObanClaude.Agent.cast_prompt/3` with `origin: :tick`, so a
  scheduled prompt can never be consumed as the operator's answer to a
  pending `:waiting_for_user` question -- it queues behind it. The `"skip"`
  policies are a best-effort status pre-check; the origin flag is the
  race-safe backstop.

  A `:paused` agent never receives a tick (`{:cancel, :agent_paused}`) --
  lockdown outranks the schedule, in both `"if_busy"` modes.

  `max_attempts: 1`: a tick is a point-in-time beat; retrying a failed one
  later would deliver a stale prompt (and risk a duplicate), so a missed beat
  is simply missed. The cancels are visible per-beat in the `oban_jobs` table.

  Ticks default to their OWN queue (`:ticks` -- run it alongside the agents
  queue, e.g. `queues: [agents: 2, ticks: 1]`). On a queue shared with agent
  turns a tick serializes BEHIND the very turn it should observe, so by the
  time it runs the agent looks idle again and the `"skip"` policy can never
  fire -- a lesson from live fleet use.
  """

  use Oban.Worker, queue: :ticks, max_attempts: 1

  alias ObanClaude.Agent

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, agent_id} <- fetch(args, "agent_id"),
         {:ok, prompt} <- fetch(args, "prompt"),
         {:ok, if_busy} <- policy(args, "if_busy", ~w(skip queue)),
         {:ok, if_offline} <- policy(args, "if_offline", ~w(skip start)),
         {:ok, session} <- policy(args, "session", ~w(resume fresh)) do
      opts = [origin: :tick, session: %{"resume" => :resume, "fresh" => :fresh}[session]]
      tick(agent_id, prompt, opts, if_busy, if_offline, args)
    end
  end

  defp tick(agent_id, prompt, opts, if_busy, if_offline, args) do
    case Agent.status(agent_id) do
      {:ok, :offline} when if_offline == "start" ->
        start_and_deliver(agent_id, prompt, opts, args)

      {:ok, :offline} ->
        {:cancel, :agent_not_running}

      {:ok, :paused} ->
        {:cancel, :agent_paused}

      {:ok, :idle} ->
        deliver(agent_id, prompt, opts)

      {:ok, _busy} when if_busy == "queue" ->
        deliver(agent_id, prompt, opts)

      {:ok, _busy} ->
        {:cancel, :agent_busy}
    end
  end

  defp start_and_deliver(agent_id, prompt, opts, args) do
    start = Map.get(args, "start", %{})

    config = [
      args: Map.get(start, "args", %{}),
      approved_args: Map.get(start, "approved_args", %{}),
      job_timeout: Map.get(start, "job_timeout", 60_000)
    ]

    case Agent.start_agent(agent_id, config) do
      {:ok, _pid} -> deliver(agent_id, prompt, opts)
      {:error, reason} -> {:cancel, {:start_failed, inspect(reason)}}
    end
  end

  defp deliver(agent_id, prompt, opts) do
    case Agent.cast_prompt(agent_id, prompt, opts) do
      :ok -> :ok
      # the agent died between the status read and the cast: this beat is missed
      {:error, :agent_not_running} -> {:cancel, :agent_not_running}
    end
  end

  defp fetch(args, key) do
    case args do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:cancel, {:invalid_tick, "missing or invalid #{inspect(key)}"}}
    end
  end

  defp policy(args, key, allowed) do
    value = Map.get(args, key, hd(allowed))

    if value in allowed do
      {:ok, value}
    else
      {:cancel, {:invalid_tick, "unknown #{inspect(key)} #{inspect(value)}"}}
    end
  end
end
