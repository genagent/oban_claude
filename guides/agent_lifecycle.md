# Agent lifecycle

The agent layer is the stateful floor above the stateless `ObanClaude` seam:
**one agent = one `:gen_statem` process** whose conversational turns run as
ordinary `ObanClaude.Worker` jobs. The process never blocks on claude -- a
prompt enqueues a job and the machine parks until the worker's callbacks
report back -- and the claude session id threads turn to turn, so one agent
is one persistent conversation.

It is opt-in: nothing runs unless `ObanClaude.Agent.Supervisor` is in your
tree, and the core seam (`ObanClaude.run/2`, `ObanClaude.Worker`) is
untouched by it.

> #### Experimental {: .warning}
>
> The agent API may still change between minor releases while it carries
> this marker.

## Quickstart

Add the supervisor after your Oban instance, and run the two queues:

    children = [
      MyApp.Repo,
      {Oban, repo: MyApp.Repo, queues: [agents: 2, ticks: 1], ...},
      ObanClaude.Agent.Supervisor
    ]

Then, from anywhere:

    {:ok, _pid} = ObanClaude.Agent.start_agent("a1", args: %{"model" => "haiku"})
    :processing  = ObanClaude.Agent.submit_prompt("a1", "reply with just: hi")
    {:ok, :idle} = ObanClaude.Agent.await("a1", :idle, 120_000)
    {:ok, log}   = ObanClaude.Agent.history("a1")

Every config key has a default; `:args` is any string-keyed claude args map
(build it with `ObanClaude.Args.defaults/1`). See `ObanClaude.Agent.Instance`
for the full config table.

## The lifecycle

| State | Meaning | Prompts arriving here |
|---|---|---|
| `:idle` | ready | start a turn |
| `:running` | an Oban job is in flight | postponed until the turn ends |
| `:waiting_for_user` | the last turn asked a question | consumed as the answer (except `origin: :tick`, which queues) |
| `:awaiting_permission` | the last turn requested approval | postponed until the gate clears |
| `:paused` | lockdown via `emergency_pause/1` | refused (calls) or dropped-and-recorded (casts) |

A `:state_timeout` watchdog (`:job_timeout`, default 60s) guards `:running`
against a turn that never reports back. Every state change atomically updates
the registry -- `ObanClaude.Agent.status/1` reads the state *and* the gated
payload (action or question) in one messageless read -- and emits
`[:oban_claude, :agent, :transition]` telemetry.

## Directives: how a turn routes the machine

The machine routes on the turn's structured output. Give the agent a
`json_schema` arg with a `"directive"` field and tell it (via
`append_system_prompt`) when to use each value:

  * `"ask_user"` + `"question"` -> `:waiting_for_user`
  * `"request_permission"` + `"action"` -> `:awaiting_permission`
  * anything else -> `:idle`

No schema means every turn returns to `:idle` -- fine for plain
conversational agents.

## Approvals actually unlock things

Conversational approval is only meaningful if it changes what the turn may
do. The `:approved_args` config (e.g. `%{"permission_mode" => "accept_edits"}`,
or a `"worktree"` for isolated edits) merges over the agent's args for
**approve continuations only** -- normal turns run with whatever standing
permissions you configured, which can be none at all.

Approved work is also **not allowed to silently die**: if the approved turn
fails (a rail stop, a crash verdict) or hits the watchdog, the machine
re-gates -- back to `:awaiting_permission` with the same description and a
fresh action id, with `{:approval_incomplete, reason}` in history. Because
the failed turn's session id was captured, a re-approval resumes the
interrupted work rather than starting over.

## Prompts: sync, async, and options

  * `submit_prompt/3` is a call: it blocks until the machine accepts the
    prompt (microseconds in `:idle`; the whole in-flight turn if postponed)
    and replies `:processing`. Backpressure for scripts.
  * `cast_prompt/3` is fire-and-forget: never blocks the caller. For
    LiveView handlers, schedulers, anything that must not wait.

Both take options: `session: :fresh` starts a new claude session for that
turn (cleared at delivery time, so it composes with queued prompts);
`origin: :tick` marks a scheduled delivery that must never be consumed as
the answer to a pending question.

## Retries are one logical turn

`ObanClaude.Agent.Job` routes terminal-aware: `{:cancel, _}` or a final
`{:error, _}` reports `job_finished/2`; a retryable failure or `{:snooze, _}`
reports `job_retrying/2`, which keeps the machine in `:running` and re-arms
the watchdog. The default worker stays `max_attempts: 1` (every retry is a
paid call); opt in with a three-line delegating worker -- see
`ObanClaude.Agent.Job`.

## Scheduling: a crontab entry is an agent

`ObanClaude.Agent.Tick` adapts `Oban.Plugins.Cron` (which schedules at the
worker layer) to the machine (which owns turn enqueueing): a beat delivers a
*prompt* through the facade, never a job behind the machine's back.

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

Policies per tick: `if_busy` (`"skip"` default / `"queue"`), `if_offline`
(`"skip"` default / `"start"` -- the crontab becomes the agent's spec, so
restarts self-heal at the next beat), `session` (`"resume"` default /
`"fresh"`, the routine-friendly choice). Ticks run on their **own queue**
(`:ticks`): on a queue shared with agent turns a tick serializes behind the
very turn it should observe as busy, and skip-policy can never fire.

## Observing a fleet

  * `status/1` -- one atomic registry read: the state, plus the pending
    action/question in the gated states. Never messages the process.
  * `await/3` -- block until the agent settles into given states; returns the
    full status payload. Registry-polling.
  * `list/0` -- every running agent as `{id, status}`, off the registry.
  * `info/1` -- turn count, accumulated cost, session id, pendings (a call;
    in-process, so it resets on restart -- durable ledgers are the app's job).
  * `history/1` -- the bounded event log (`:max_history`, default 500).
  * Telemetry: `[:oban_claude, :agent, :transition]` with
    `%{agent_id, from, to}`, plus the run-level events documented in
    `ObanClaude`.

## Testing without a queue or claude

The `:enqueue_fun` config replaces the Oban insert, and `job_finished/2` is
the public return path -- so a test drives the whole machine with no DB and
no claude:

    test_pid = self()

    {:ok, _} =
      ObanClaude.Agent.start_agent("t1",
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    :processing = ObanClaude.Agent.submit_prompt("t1", "go")
    assert_receive {:enqueued, %{"prompt" => "go"}, %{"agent_id" => "t1"}}

    :ok = ObanClaude.Agent.job_finished("t1", {:ok, ObanClaude.Testing.result("done")})
    {:ok, :idle} = ObanClaude.Agent.await("t1", :idle, 1_000)

Build payloads with `ObanClaude.Testing` (`result/1`, `structured_result/2`
for directives, `error/2` for failures).

## What it deliberately does not do

The machine owns lifecycle, not operations. Durable spend ledgers and
budgets, persisted journals/todos, gate records that survive restarts,
notifications, dashboards, and MCP surfaces for agents-driving-agents are
all **application concerns** -- they compose cleanly on top of the telemetry
and the facade (each was built and live-proven in a demo app during this
layer's incubation), and they carry dependencies this library should not.
