# Agent lifecycle

The agent layer is the stateful floor above the stateless `ObanClaude` seam:
**one agent = one `:gen_statem` process** whose conversational turns run as
ordinary `ObanClaude.Worker` jobs. The process never blocks on claude -- a
prompt enqueues a job and the machine parks until the worker's callbacks
report back. Provider sessions live in bounded, host-named conversation arcs,
so one agent can keep an operator conversation separate from scheduled and
task-specific work while remaining single-turn-at-a-time.

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
| `:paused` | lockdown via `emergency_pause/1`, `pause_after_turn/3`, or `quiesce/2` | refused (calls) or dropped-and-recorded (casts) |

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

## Pause at a safe turn boundary

Hosts that enforce a spend, token, or policy rail often learn that an agent
must pause while its turn is still running. Calling `emergency_pause/1` at that
point is too blunt: it deliberately drops action and question gates, and a
later asynchronous pause can race a postponed prompt through `:idle`.

`pause_after_turn/3` synchronously installs a correlated latch inside the state
machine before the worker callback can finish the turn:

    :telemetry.attach_many(
      "daily-spend-rail",
      [[:oban_claude, :run, :stop], [:oban_claude, :run, :exception]],
      fn _event, _measurements, %{job: %{meta: %{"agent_id" => id} = job_meta}}, _config ->
        case ObanClaude.Agent.pause_after_turn(id, :daily_spend, job_meta) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("safe-boundary pause refused: #{inspect(reason)}")
        end
      end,
      nil
    )

The telemetry handler must call `pause_after_turn/3` inline. The worker sends
its terminal callback only after telemetry handlers return, which gives the
latch deterministic ordering. Starting another process for the call gives up
that guarantee.

Treat a returned error as a visible, fail-closed race outcome. Do not raise in
the handler: telemetry detaches handlers that crash.

Pass the exact job metadata captured at enqueue time. The machine validates the
agent id, instance generation, and logical turn id atomically. A foreign,
stale, retired, or malformed identity returns a typed error and changes
nothing. Repeating the accepted source or current/latest owner identity is
idempotent; the first pause reason wins. A matching completed turn remains
correlatable while it is parked in `:waiting_for_user` or
`:awaiting_permission`, so a host that learns about the rail after the gate
opens can still install the latch without erasing the gate. A terminal turn
that already reached `:idle` remains retired and cannot be latched afterward.

Ordinary completion, terminal failure, and watchdog expiry now land directly
in `:paused`, before postponed prompts can run. A permission request or user
question remains gated. Approving or answering grants one continuation while
the latch stays active; that continuation pauses when it finishes, or remains
gated if it requests another action or question. Rejecting a latched permission
gate records the denial and goes directly to `:paused`.

Retries remain part of the same logical turn and keep the latch. An explicit
`resume_agent/1` clears it. `emergency_pause/1` remains immediate and clears the
latch together with all gate scopes.

For lifecycle changes that do not originate in turn telemetry, use
`quiesce/2`. It chooses the boundary atomically inside the state machine, so a
host does not need a racy `status/1` read followed by a pause:

    case ObanClaude.Agent.quiesce("caretaker", {:config_changed, revision}) do
      :paused -> restart_with_new_config()
      :armed -> wait_until_paused_then_restart()
      :already_paused -> restart_with_new_config()
    end

An idle agent pauses immediately. A running agent finishes its turn. A gated
agent retains its question or permission and allows the continuation before
pausing; rejecting a pending permission pauses immediately. Existing latches
are left in place, so the first reason wins. `quiesce/2` emits the same
`pause_reason` and `pause_action` transition fields with `cause: :quiesce`.

An optional `config_revision` on `start_agent/2` identifies the immutable host
configuration applied to that provider process. It is an opaque non-empty
string of at most 256 bytes. The provider does not compare or compute it:

    ObanClaude.Agent.start_agent("caretaker",
      args: %{"model" => "sonnet"},
      config_revision: "routine-42:7"
    )

The applied revision appears in `info/1`, every job's metadata, and Agent
transition and turn-completion telemetry. It is omitted from metadata when no
revision was supplied. The host can compare the observed revision with its
desired revision, call `quiesce/2`, stop the paused process, and start a new
one. The provider never mutates a running config in place.

## Prompts: sync, async, and options

  * `submit_prompt/3` is a call: it blocks until the machine accepts the
    prompt (microseconds in `:idle`; the whole in-flight turn if postponed)
    and replies `:processing`. Backpressure for scripts.
  * `cast_prompt/3` is fire-and-forget: never blocks the caller. For
    LiveView handlers, schedulers, anything that must not wait.

Both take options: `arc_id: "issue-651"` selects an opaque conversation arc;
omission uses the backward-compatible `"default"` arc. `session: :fresh`
clears only the selected arc at delivery time. `session: :fresh_fallback`
records that the host deliberately recovered from a failed resume.
`origin: :tick` marks a scheduled delivery that must never be consumed as the
answer to a pending question.

## Conversation arcs

Seed known provider handles when starting or restoring the process:

    {:ok, _pid} =
      ObanClaude.Agent.start_agent("caretaker",
        session_arcs: %{
          "operator" => persisted_operator_session,
          "issue-651" => persisted_issue_session
        },
        max_session_arcs: 32
      )

    :processing =
      ObanClaude.Agent.submit_prompt("caretaker", "continue the issue",
        arc_id: "issue-651"
      )

Each job's metadata identifies `arc_id`, the input `session_id`, and its
`continuation_decision` / `continuation_reason`. `info/1` returns
`session_arcs`, `active_arc_id`, and the current or most recent
`continuation`. A terminal resume classified as `:session_not_found`,
`:invalid_session`, `:unknown_session`, or `:session_rejected` produces a
typed `outcome: :session_rejected`. The host can then reconstruct a durable
handoff and deliberately submit `session: :fresh_fallback`; no local
transcript is selected implicitly.

Claude can branch a retained session without changing its source arc:

    :processing =
      ObanClaude.Agent.fork_arc(
        "caretaker",
        "issue-651",
        "issue-651-experiment",
        "try the alternate design"
      )

The returned child session is stored under the target arc. Least-recently
used inactive handles are evicted when `max_session_arcs` is reached. Arc
persistence and rotation policy remain the host application's responsibility.

## Retries are one logical turn

`ObanClaude.Agent.Job` routes terminal-aware: `{:cancel, _}` or a final
`{:error, _}` reports `job_finished/3`; a retryable failure or `{:snooze, _}`
reports `job_retrying/3`, which keeps the machine in `:running` and re-arms
the watchdog. The default worker stays `max_attempts: 1` (every retry is a
paid call); opt in with a three-line delegating worker -- see
`ObanClaude.Agent.Job`.

Every job carries an opaque instance generation and logical turn id in its
metadata. The instance checks both inside the state machine before changing
state, session, approval, counters, or watchdogs. Late outcomes, duplicate
callbacks, and callbacks from an earlier same-id process are retained only as
bounded diagnostics. Custom workers that delegate their result and error
callbacks to `ObanClaude.Agent.Job` inherit this behavior automatically.

## Scheduling: a crontab entry is an agent

`ObanClaude.Agent.Tick` adapts `Oban.Plugins.Cron` (which schedules at the
worker layer) to the machine (which owns turn enqueueing): a beat delivers a
*prompt* through the facade, never a job behind the machine's back.

    {Oban.Plugins.Cron,
     crontab: [
       {"0 9 * * *", ObanClaude.Agent.Tick,
        args: %{
          "agent_id" => "standup",
          "arc_id" => "daily-sweep",
          "prompt" => "Summarize overnight CI failures.",
          "session" => "fresh",
          "if_offline" => "start",
          "start" => %{
            "args" => %{"model" => "sonnet"},
            "config_revision" => "routine-42:7"
          }
        }}
     ]}

Policies per tick: `if_busy` (`"skip"` default / `"queue"`), `if_offline`
(`"skip"` default / `"start"` -- the crontab becomes the agent's spec, so
restarts self-heal at the next beat), `session` (`"resume"` default /
`"fresh"`, the routine-friendly choice). Ticks run on their **own queue**
(`:ticks`): on a queue shared with agent turns a tick serializes behind the
very turn it should observe as busy, and skip-policy can never fire.

A host can serialize Tick delivery with its own configuration boundary by
setting `config :oban_claude, tick_admission: MyApp.TickAdmission`. The module
must export `admit/4`. It receives `:claude`, the agent id, the optional
`"start.config_revision"`, and a zero-arity function containing the complete
status check, offline start, and prompt cast. It must either invoke and return
that function's result or return another valid `Oban.Worker` result. Without
this configuration, Tick delivery is unchanged.

## Observing a fleet

  * `status/1` -- one atomic registry read: the state, plus the pending
    action/question in the gated states. Never messages the process.
  * `await/3` -- block until the agent settles into given states; returns the
    full status payload. Registry-polling.
  * `list/0` -- every running agent as `{id, status}`, off the registry.
  * `info/1` -- applied `config_revision`, turn count, accumulated cost,
    default `session_id`, all retained
    `session_arcs`, current/recent continuation, pending gates, and the current
    `deferred_pause` latch. While paused, `pause_context` retains the cause,
    reason, action, and any correlated turn identity that applied the pause (a
    call; in-process, so the host seeds persisted arcs after restart).
  * `history/1` -- the bounded event log (`:max_history`, default 500). A safe
    boundary latch records `{:pause_after_turn, reason}` when accepted and
    `{:paused_after_turn, reason}` when it is applied. A host boundary records
    `{:quiesce, reason}` when armed or `{:quiesced, reason}` when an idle agent
    pauses immediately.
  * Telemetry: `[:oban_claude, :agent, :transition]` with
    `%{agent_id, from, to}`, and `[:oban_claude, :agent, :turn_completed]`
    with the arc, session, continuation decision, and typed outcome. Pass an
    opaque `correlation_id` to `submit_prompt/3` or `cast_prompt/3` to carry an
    application request identity through postponed delivery, job metadata,
    turn transitions, approval continuations, and completion. Turn events also
    expose the wrapper-owned `agent_generation` and `agent_turn_id`; when set,
    `config_revision` appears on every transition and completion. Deferred
    pause transitions add `cause` (`:pause_after_turn` for a correlated latch,
    `:quiesce` for a host boundary, `:emergency_pause` for the immediate
    brake), `pause_reason`, and `pause_action` (`:continued`, `:applied`, or
    `:cleared`). Gate transitions
    also add `gate_outcome` (`:opened`, `:approved`, `:answered`, `:incomplete`,
    or `:rejected`) and the relevant `action_id` or `question`.

## Testing without a queue or claude

The `:enqueue_fun` config replaces the Oban insert. Tests capture the metadata
passed to that function and return it through `job_finished/3`, so they drive
the whole machine with no DB and no claude while preserving turn ownership:

    test_pid = self()

    {:ok, _} =
      ObanClaude.Agent.start_agent("t1",
        enqueue_fun: fn args, meta ->
          send(test_pid, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    :processing = ObanClaude.Agent.submit_prompt("t1", "go")
    assert_receive {:enqueued, %{"prompt" => "go"}, %{"agent_id" => "t1"} = meta}

    :ok =
      ObanClaude.Agent.job_finished(
        "t1",
        {:ok, ObanClaude.Testing.result("done")},
        meta
      )
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
