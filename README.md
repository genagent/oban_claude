# oban_claude

[![Hex.pm](https://img.shields.io/hexpm/v/oban_claude.svg)](https://hex.pm/packages/oban_claude)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/oban_claude)
[![CI](https://github.com/genagent/oban_claude/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/oban_claude/actions/workflows/ci.yml)
[![Downloads](https://img.shields.io/hexpm/dt/oban_claude.svg)](https://hex.pm/packages/oban_claude)
[![License](https://img.shields.io/hexpm/l/oban_claude.svg)](https://github.com/genagent/oban_claude/blob/main/LICENSE)

Run [Claude Code](https://github.com/anthropics/claude-code) jobs on an
[Oban](https://hex.pm/packages/oban) queue. A thin worker over
[`claude_wrapper`](https://hex.pm/packages/claude_wrapper) that maps claude's
typed result/error onto Oban's return values.

Oban already gives you the durable queue: a transactional claim (`FOR UPDATE
SKIP LOCKED`), retries with backoff, uniqueness, the `Lifeline` reaper, the
`Pruner`. `claude_wrapper` already gives you a synchronous, headless `claude -p`
call that returns a typed `%ClaudeWrapper.Result{}` / `%ClaudeWrapper.Error{}`.
`oban_claude` is the ~60 lines between them.

## Install

```elixir
def deps do
  [
    {:oban, "~> 2.23"},
    {:oban_claude, "~> 0.1"}
  ]
end
```

## Requirements

- **Elixir `~> 1.20`** on **OTP 29**.
- The **`claude` CLI, installed and authenticated** -- `oban_claude` shells out
  to it via [`claude_wrapper`](https://hex.pm/packages/claude_wrapper) (pinned to
  the `0.13.x` line). Run `claude doctor` before your first real job; without a
  working CLI, runs dead-letter as `{:cancel, :binary_not_found}` or
  `{:cancel, :auth}`.

## Use

```elixir
defmodule MyApp.ClaudeJob do
  use ObanClaude.Worker, queue: :claude, max_attempts: 3

  # Optional. Default returns :ok. Override to branch on a typed outcome,
  # persist cost/session, or enqueue a follow-on effector job.
  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    case ObanClaude.outcome(result) do
      "blocked" -> {:cancel, :blocked}
      _ -> :ok
    end
  end
end

%{"prompt" => "summarize this repo", "working_dir" => "/path/to/repo"}
|> MyApp.ClaudeJob.new()
|> Oban.insert()
```

The job args are the spec: `prompt` (required) plus a **curated subset** of
`claude_wrapper` query options (`model`, `max_turns`, `max_budget_usd`,
`working_dir`, `permission_mode`, `timeout`, ...) -- the exact set is the
`ObanClaude.Args` options table (which now includes the session-control keys
`resume` / `session_id` / `fork_session` / `no_session_persistence`). Query
options outside that set (e.g. `env`) are not forwarded, and unknown raw-map keys
are silently ignored. Args are JSON, so atom-valued options are given as strings:
`permission_mode` is `"bypass_permissions"`, coerced to the atom for you.

In `handle_result/2`, `ObanClaude.outcome/1` reads the `"outcome"` key of a
`--json-schema` run's structured output; `ObanClaude.structured/1` returns the
whole validated object.

## Workers as task definitions

A worker is a task type; a job is one instance. `:args` on the worker are default
claude args, merged under each job's args (the job wins). That gives a spectrum:

```elixir
# fixed config in the worker, the variable input in the job
defmodule MyApp.PrReview do
  use ObanClaude.Worker,
    queue: :review,
    args: %{"model" => "sonnet", "system_prompt" => "Review the pull request."}
end

MyApp.PrReview.new(%{"prompt" => "PR #4321: " <> diff}) |> Oban.insert()
```

Because the job wins the merge, `:args` are **defaults, not guardrails** — a job
can override any of them, including `permission_mode` or a budget cap. To make a
key worker-invariant, put it in `:pinned_args`, which merges *over* the job
(precedence: `pinned_args > job > args`):

```elixir
defmodule MyApp.ReadOnlyAudit do
  use ObanClaude.Worker,
    queue: :audit,
    args: %{"model" => "sonnet"},
    # a job cannot escalate these, even by supplying the same key
    pinned_args: %{"permission_mode" => "default", "max_budget_usd" => 2.0}
end
```

This matters when job args come from a semi-trusted source (a webhook, an exposed
enqueue API). Both maps must be string-keyed (atom keys raise at compile time),
and a job with malformed args (a missing prompt, an unknown `permission_mode`)
dead-letters as `{:cancel, {:invalid_args, _}}` rather than retrying to exhaustion.

With no `:args`, a worker is a bare passthrough (the job carries everything). With
everything in `:args` and an empty job it is a routine: pair it with
`Oban.Plugins.Cron` for a scheduled claude task.

```elixir
config :my_app, Oban,
  plugins: [{Oban.Plugins.Cron, crontab: [{"0 9 * * *", MyApp.DailyDigest}]}]
```

## Triggering

A job is just a row, so anything that can insert one can trigger an agent. Two
shapes cover most work:

- **Scheduled** -- `Oban.Plugins.Cron` inserts an (empty) job on a crontab. The
  worker holds the config; the schedule just says "run." See
  `examples/scheduled_routine.exs`.
- **Event-driven** -- a webhook, poller, or PubSub handler calls
  `Worker.new(args) |> Oban.insert()` when something happens. Add `unique:` to
  the worker and Oban debounces duplicate events, so a burst of the same signal
  does the (paid) claude work once. See `examples/event_driven.exs`.

```elixir
use ObanClaude.Worker, queue: :events, unique: [period: 60]
```

`oban_claude` is trigger-agnostic: it never knows what inserted the job. The
config layering (app config, then worker `:args` defaults, then per-job args with
the job winning) is the same in both cases.

## Isolation (git worktrees)

A full-auto worker that writes to a repo should isolate each run in its own git
worktree, so concurrent (or successive) jobs never collide in one working copy.
`worktree` maps to the claude CLI's `--worktree`; set it in the worker defaults:

```elixir
use ObanClaude.Worker,
  queue: :issues,
  args: ObanClaude.Args.defaults(working_dir: "/repo", worktree: true)
```

- `worktree: true` -- an ephemeral worktree per run. The CLI removes it at
  end-of-run, but a killed run (Oban timeout, `cancel_job`, deploy, crash) skips
  that cleanup and leaks the checkout -- see [Worktree hygiene](agent_worker_patterns.html#worktree-hygiene).
- `worktree: "issue-173"` (per job) -- a **named** worktree, reusable across jobs.
  A per-job value overrides the worker default, so a chain of jobs for one issue
  can share a worktree by passing the same name (assumes at most one job touches
  it at a time -- guard with `unique`, see the guide).

It requires `working_dir` to be a git repo, so it is opt-in (a read-only or
non-repo job would fail `--worktree`). The installer's sample worker enables it.

## Full-auto workers

A worker can run the agent full-auto: claude makes the change and opens the PR
itself (the agent is its own sink -- oban_claude takes no part). Three things
make an unattended, one-shot job reliable:

- **Isolate** each run in its own git worktree, so concurrent jobs never collide
  in the shared checkout.
- **Bound the cost** with `max_turns` and `max_budget_usd`. A one-shot job has no
  human to stop it; the classifier turns `max_turns_exceeded` into a `:cancel`.
- **Keep it single-turn.** A batch job has no follow-up turn, so a *system* prompt
  must tell the agent to finish at the draft PR and never wait on CI -- otherwise
  it can park waiting for a notification that never comes (a user-prompt
  instruction loses to the repo's own conventions).
- **Seal the config** with `hermetic: :full` so the run doesn't inherit the host's
  `~/.claude` or the repo's `.claude` (allow rules, hooks, ambient MCP servers).

```elixir
defmodule MyApp.IssueWorker do
  use ObanClaude.Worker,
    queue: :issues,
    max_attempts: 1,
    args:
      ObanClaude.Args.defaults(
        working_dir: "/repo",
        permission_mode: :bypass_permissions,
        worktree: true,
        hermetic: :full,
        max_turns: 40,
        max_budget_usd: 2.0,
        append_system_prompt:
          "You run as a single-turn batch job: there is no follow-up turn. " <>
            "When you have opened the draft PR your job is complete -- end " <>
            "immediately. Never wait for a notification or watch CI."
      )
end

# one job per unit of work; a named worktree lets a future plan/implement/review
# chain for the same issue share one worktree
MyApp.IssueWorker.new(ObanClaude.Args.new(prompt: issue_text, worktree: "issue-#{n}"))
|> Oban.insert()
```

Before running this against real repos, read the fleet-safety sections of the
*Agent worker patterns* guide: an unattended fleet has to reckon with process
lifecycle (a timed-out or cancelled run keeps spending unless you use `forcola`),
retry cost (`max_attempts: 1` for mutating jobs -- retries are paid and repeat
writes), wall-clock timeouts, deploy/crash recovery, and untrusted input (fence
external issue/PR text; prefer propose/dispose). Each is a real footgun, not a
nicety.

## Structured output (propose / dispose)

Pass a `json_schema` (a JSON Schema string) and claude returns a validated
object instead of prose. `ObanClaude.structured/1` reads the whole object off the
result; `ObanClaude.outcome/1` is the shorthand for its `"outcome"` key.

This is the propose / dispose split: the worker runs read-only and *proposes* a
typed verdict, and `handle_result/2` *disposes* of it (act on it, branch, or
enqueue a follow-on effector job that does the writing).

```elixir
defmodule MyApp.Triage do
  @schema Jason.encode!(%{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["outcome", "summary"],
            "properties" => %{
              "outcome" => %{"enum" => ["fix", "needs_review", "wontfix"]},
              "summary" => %{"type" => "string"}
            }
          })

  use ObanClaude.Worker,
    queue: :triage,
    max_attempts: 3,
    args: %{
      "model" => "sonnet",
      "json_schema" => @schema,
      "system_prompt" => "Triage the issue. Inspect the repo but do not write anything."
    }

  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    case ObanClaude.structured(result) do
      %{"outcome" => "fix", "summary" => summary} ->
        # dispose: hand the proposal to an effector that actually writes
        %{"prompt" => "Implement this change: " <> summary}
        |> MyApp.Implement.new()
        |> Oban.insert()

        :ok

      %{"outcome" => "wontfix"} ->
        {:cancel, :wontfix}

      _ ->
        :ok
    end
  end
end

MyApp.Triage.new(%{"prompt" => "Issue #87: " <> body}) |> Oban.insert()
```

The schema is just another job arg: fix it on the worker (`:args`, above) so every
job shares it, or pass a per-job `"json_schema"`. `@schema` is a module attribute
referenced before `use`, which the worker macro allows. `outcome/1` and
`structured/1` return `nil` on a run that produced no structured output, so a
worker that sometimes runs without a schema can fall through to a plain-text path.

## The classifier

`oban_claude` maps each claude outcome onto the right Oban verdict (overridable
via `:classifier`):

| claude outcome | Oban | why |
|---|---|---|
| `Result` ok | `:ok` -> `handle_result/2` | success; the worker decides the final atom |
| `Result is_error: true` | `{:error, :result_error}` | retry, capped by `max_attempts` |
| `:timeout` | `{:error, :timeout}` | transient; retry with backoff, bounded by `max_attempts` |
| `:auth` (`reason: :rate_limit`) | `{:error, :rate_limit}` | rate/quota limit is transient; retry (bounded) |
| `:command_failed` / `:json` / `:io` | `{:error, kind}` | likely transient; retry + backoff |
| missing/unrunnable binary (`:io` + `:enoent`/`:eacces`) | `{:cancel, :binary_not_found}` | the CLI is absent or not executable; re-fails identically |
| `:auth` (other reasons) and other config/env faults | `{:cancel, kind}` | the broken environment re-fails identically; retrying cannot help |
| `:max_budget_exceeded` / `:max_turns_exceeded` | `{:cancel, ...}` | the rails stopped it; resume via `handle_error/3` + `resume:` is deliberate |

The default mapping never returns `{:snooze, _}`: Oban implements snooze by
*incrementing* `max_attempts`, so a deterministically-failing job would snooze
forever (unbounded paid re-runs). Every transient outcome is `{:error, _}`
instead, bounded by `max_attempts`. To opt into snooze -- or any other verdict
-- override the classifier, returning the `{oban_return, payload}` envelope:

```elixir
defmodule MyApp.Worker do
  use ObanClaude.Worker, queue: :claude, classifier: &__MODULE__.classify/1

  # Ride out a rate-limit window with a snooze (accepting that snooze bypasses
  # max_attempts); defer everything else to the default mapping.
  def classify({:error, %ClaudeWrapper.Error{kind: :auth, reason: :rate_limit} = e}),
    do: {{:snooze, {15, :minutes}}, e}

  def classify(outcome), do: ObanClaude.Outcome.classify(outcome)
end
```

The classifier changes the *verdict*; it is a pure mapping and stays job-blind.
To act on a failure with the run's payload and the job in hand -- persist the
spend, or read the `session_id` off a rail-stop `%Error{}` and enqueue a
`resume:` continuation -- override `c:ObanClaude.Worker.handle_error/3`, the
error-path mirror of `handle_result/2` (it fires on every non-`:ok` verdict and
defaults to passing the verdict through). `ObanClaude.session_id/1` and
`cost_usd/1` read those off either a `%Result{}` or an `%Error{}` without
touching `claude_wrapper` internals. See the **session-resume handoff** recipe in
the [Agent worker patterns](guides/agent_worker_patterns.md) guide.

A classifier must return the `{oban_return, payload}` envelope -- e.g.
`{{:cancel, :blocked}, error}`, not a flat `{:cancel, :blocked}`. `run/2` raises
on a flat verdict, since `ObanClaude.Worker` would otherwise hand Oban a bare
atom, which it records as success.

## Examples

Runnable scripts (throwaway SQLite-backed Oban; claude is stubbed via
`:query_fun`, so they cost nothing), each `mix run examples/<name>.exs` (they
ship in the Hex package, or browse them on
[GitHub](https://github.com/genagent/oban_claude/tree/main/examples)). CI runs
the fast offline ones on every push, so a drift in the public API breaks the
build, not your first `mix run`:

- `playground.exs` -- one job per claude outcome, watch the queue resolve them
  (`:ok` / cancel / retry / snooze).
- `propose_dispose.exs` -- a structured-output run whose result drives a
  follow-on effector job.
- `event_driven.exs` -- insert-driven triggering: a burst of identical events is
  debounced to one run by Oban's `unique`, a distinct event gets its own.
- `triage_issues.exs` -- a worker configured for issue triage; offline by
  default (baked issues if `gh` is absent), `--live` for real paid haiku calls.

Two more aren't run in CI -- one is slow, one is interactive:

- `scheduled_routine.exs` -- a Cron-driven routine: the worker holds the prompt,
  the job is empty, and `Oban.Plugins.Cron` fires it on a schedule (waits ~70s
  for a real Cron tick).
- `console.exs` -- a local queue you drive from `iex -S mix` (loaded by
  `.iex.exs`); each `run/1` is a real, paid claude call.

To scaffold a fresh project with all the pieces wired (SQLite, Oban, a sample
worker, a boot-time watch demo), use the [Igniter](https://hexdocs.pm/igniter)
installer. The `mix igniter.*` tasks come from Igniter, so it has to be present
first.

Into a **new** project -- install the `igniter_new` archive once (globally),
then create the project with oban_claude:

```bash
mix archive.install hex igniter_new
mix igniter.new my_app --install oban_claude
```

Into an **existing** project -- add Igniter to your deps, then install:

```elixir
# mix.exs
{:igniter, "~> 0.6", only: [:dev, :test]}
```

```bash
mix deps.get
mix igniter.install oban_claude
```

For a single run with no queue or database, `mix oban_claude.run` sends CLI flags
through the same `Args.new/1` vocabulary and prints the `{oban_return, result}`
verdict (add `--json` for a machine-readable summary):

```bash
mix oban_claude.run "summarize the repo" --working-dir . --permission-mode plan
```

## Testing

`ObanClaude.run/2` and `use ObanClaude.Worker` accept a `:query_fun` (default
`&ClaudeWrapper.query/2`): a `(prompt, query_opts)` function returning
`{:ok, %Result{}}` / `{:error, %Error{}}`. Override it to stub claude in tests
without a live call, or to route through a different `claude_wrapper` entrypoint.

[`ObanClaude.Testing`](https://hexdocs.pm/oban_claude/ObanClaude.Testing.html)
builds those stub returns without hard-coding `claude_wrapper`'s structs --
`respond/1`, `fail/1`, and `sequence/1` (for retry paths) hand you a ready
`:query_fun`, and `result/1` / `structured_result/2` / `error/2` build the bare
structs for a `handle_result/2` unit test:

```elixir
import ObanClaude.Testing

assert {:ok, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: respond("done"))
assert {{:cancel, :auth}, _} = ObanClaude.run(%{"prompt" => "x"}, query_fun: fail(:auth))
```

## What it does NOT do

No state, no daemon, no "sink". It runs the agent and returns the
verdict. Whether the agent effects its own writes (full-auto) or returns
structured data for a downstream effector is the *job's* concern, encoded in the
prompt and permission mode. Persisting results and reacting to completion are the
caller's job (`handle_result/2` + the `[:oban_claude, :run, :stop]` telemetry).

See [SPEC.md](https://github.com/genagent/oban_claude/blob/main/SPEC.md) for the
design and the build-out checklist.
