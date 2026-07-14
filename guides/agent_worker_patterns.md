# Agent worker patterns

Worked recipes for running claude agents on an Oban queue with `oban_claude`.
These are **patterns to read and copy, not modules to install** -- each is a
`use ObanClaude.Worker` plus an `ObanClaude.Args` config and a
`c:ObanClaude.Worker.handle_result/2`. They were validated by driving oban_claude
against a real repository (implementing issues, reviewing and merging the PRs,
and auditing itself).

`oban_claude` stays a thin seam: it runs one claude turn per job and maps the
result onto an Oban return. Everything below is composition on top of that.

## The pillars of an unattended worker

A job runs with no human watching, so a full-auto worker needs four things.

1. **Isolation.** Run in a git worktree so concurrent jobs never collide in one
   working copy. Set it in the worker defaults:

   ```elixir
   use ObanClaude.Worker,
     queue: :agents,
     args: ObanClaude.Args.defaults(working_dir: "/repo", worktree: true)
   ```

   A per-job `worktree: "issue-42"` (a named worktree) overrides the default and
   lets a chain of jobs share one worktree.

2. **Guardrails.** A one-shot job has no one to stop it. Cap it with `max_turns`,
   `max_budget_usd`, and a wall-clock `timeout`; the default classifier turns
   `:max_turns_exceeded` / `:max_budget_exceeded` into `{:cancel, _}`. These are
   load-bearing, not optional -- and `max_turns`/`max_budget_usd` live *inside*
   the CLI, so they cannot fire if the CLI itself wedges; that is what the
   args-level `timeout` is for (see [Timeouts and stuck runs](#timeouts-and-stuck-runs)).

3. **A single-turn, anti-park system prompt.** A queue job runs once with no
   follow-up turn. If the repo's own conventions say "open a PR, then watch CI,"
   the agent will try to wait for a CI notification that never arrives and burn
   its whole turn budget. Put the override in `append_system_prompt` (a *system*
   instruction beats a user-prompt one):

   ```
   You run as a single-turn batch job: there is no follow-up turn. When you have
   opened the draft PR your job is complete -- end immediately. Never wait for a
   notification or watch CI, even if repository conventions say to.
   ```

4. **Sealed config (`hermetic: :full`).** By default a run *also* loads the host
   user's `~/.claude` and the target repo's project/local config -- settings-file
   allow rules, hooks, ambient MCP servers. On a shared host an allowlisted
   `Bash` in someone's `~/.claude` silently grants a "read-only" worker
   write/exec; and a PR author who edits the repo's `.claude` pulls their config
   into the agent. `hermetic: :full` seals all of it (`--setting-sources`,
   `--strict-mcp-config`, `--exclude-dynamic-system-prompt-sections`; auth is
   untouched), so the run's surface is exactly what these args set. Set it in the
   defaults for any fleet worker:

   ```elixir
   use ObanClaude.Worker,
     queue: :agents,
     args: ObanClaude.Args.defaults(working_dir: "/repo", worktree: true, hermetic: :full)
   ```

Those four pillars keep a *single* job well-behaved. Running a *fleet* of them
unattended adds more concerns, each a real footgun covered at the end of this
guide: [Retries cost money](#retries-cost-money-and-may-repeat-writes),
[Timeouts and stuck runs](#timeouts-and-stuck-runs),
[Process lifecycle](#process-lifecycle-kill-the-cli-not-just-the-task),
[Deploys and crash recovery](#deploys-and-crash-recovery),
[Fleet cost controls](#fleet-cost-controls),
[Data handling](#data-handling),
[Worktree hygiene](#worktree-hygiene), and
[Untrusted input](#untrusted-input).

## Issue-work worker: issue -> draft PR

The agent is its own sink: it makes the change and opens the PR itself.

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
        max_turns: 40,
        max_budget_usd: 2.0,
        append_system_prompt: "…single-turn, anti-park (see above)…"
      )

  @impl ObanClaude.Worker
  def handle_result(result, job) do
    require Logger
    Logger.info("issue ##{job.args["issue"]}: #{String.slice(result.result || "", 0, 120)}")
    :ok
  end
end

# Turning an issue into a prompt is the caller's job (a source layer). Here it is
# done by hand; a named worktree keys the run to the issue.
prompt = "Issue ##{n} in my-repo:\n\n#{title_and_body}\n\nImplement it, commit on a branch, open a DRAFT PR that closes ##{n}, then stop."

ObanClaude.Args.new(prompt: prompt, worktree: "issue-#{n}", meta: %{"issue" => n})
|> MyApp.IssueWorker.new()
|> Oban.insert()
```

`:meta` carries non-claude values (the issue number) through to `handle_result/2`
and telemetry without being validated as a claude arg.

## Review / merge worker: PR -> merged

The job is a PR number. The agent verifies CI, reviews the diff against its
issue, rebases and resolves conflicts if the PR has drifted from `main`, then
squash-merges. Run the queue **serially** (`queue` concurrency 1) so each merge
moves `main` before the next PR is considered.

```elixir
defmodule MyApp.MergeWorker do
  use ObanClaude.Worker,
    queue: :merges,
    max_attempts: 1,
    args: ObanClaude.Args.defaults(working_dir: "/repo", permission_mode: :bypass_permissions, max_turns: 50, max_budget_usd: 3.0, append_system_prompt: "…single-turn…")

  @impl ObanClaude.Worker
  def handle_result(result, _job), do: (IO.puts(result.result || ""); :ok)
end
```

The prompt tells the agent to check `gh pr checks`, review, `gh pr ready`, and
`gh pr merge --squash --delete-branch` -- and to *skip* (not merge) if CI is red
or the diff is wrong. Review-then-merge, autonomous on clean.

## Read-only audit worker (propose / dispose)

Not every worker writes. A read-only worker runs the agent under
`permission_mode: :default` and returns a typed verdict via `--json-schema`.
This is the propose/dispose split: the agent *proposes* structured findings;
`handle_result/2` *disposes* of them.

`permission_mode: :default` blocks writes **only if no ambient allow rule
pre-approves them** -- an allowlisted `Bash`/`Edit` in the host's `~/.claude` or
the repo's `.claude` auto-approves without a prompt even in non-interactive mode.
Add `hermetic: :full` to make "read-only" unconditional (it seals that ambient
config away), and pin *both* so an inserted job can't escalate:

```elixir
defmodule MyApp.AuditWorker do
  use ObanClaude.Worker,
    queue: :audit,
    args: ObanClaude.Args.defaults(working_dir: "/repo", append_system_prompt: "…read-only, single-turn…"),
    # permission_mode + hermetic are this worker's safety properties, so pin
    # them: :pinned_args merges over the job, so an inserted job cannot escalate
    # to full-write (or unseal the config) by supplying its own value.
    pinned_args: ObanClaude.Args.defaults(permission_mode: :default, hermetic: :full)

  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    case ObanClaude.structured(result) do
      %{"overall" => verdict, "findings" => findings} ->
        # stand-in for however your app reports findings (a Logger call, a DB
        # write, a notification) -- the point is the verdict -> Oban mapping below
        IO.inspect(findings, label: "audit #{verdict}")
        if verdict == "blockers", do: {:cancel, :blockers}, else: :ok

      _ ->
        :ok
    end
  end
end

# enqueue with a json_schema so the final message is a validated object
ObanClaude.Args.new(prompt: audit_prompt, json_schema: my_schema)
|> MyApp.AuditWorker.new()
|> Oban.insert()
```

`ObanClaude.structured/1` reads the whole validated object; `ObanClaude.outcome/1`
is the shorthand for a top-level `"outcome"` key.

Note the terminal verdict returns `{:cancel, :blockers}`, not `{:error, _}`: the
claude run *succeeded* -- it produced a valid verdict -- so `{:error, _}` would
re-run the entire paid audit (up to `max_attempts` times) only to reach the same
conclusion. `{:cancel, _}` is a clean terminal signal. Reserve `{:error, _}` for
failures a re-run could actually fix (see [Retries cost money](#retries-cost-money-and-may-repeat-writes)).

## Pipeline: plan -> implement -> merge-when-green

For "work the issue, then merge it once CI is green," a single blocking run does
not work -- CI takes minutes, and an agent cannot sit and wait for it (see pillar
3). The answer is a **pipeline of chained jobs**, built on plain OSS Oban -- no
Oban Pro Workflow required.

Three ideas make it work:

- **Chaining.** Each stage's `handle_result/2` enqueues the next stage's job.
- **Named-worktree handoff.** Every stage passes `worktree: "issue-N"`, so the
  implement stage builds on the plan stage's checkout.
- **Async CI gating via snooze.** The merge stage checks CI *once* and returns a
  structured verdict; `handle_result/2` maps it onto an Oban return. When CI is
  still pending it returns `{:snooze, n}` and Oban's scheduler re-runs the job
  later -- no process blocks, nothing parks.

```elixir
# Stage 1: plan -> enqueue implement (passing the plan text along)
defmodule MyApp.PlanWorker do
  use ObanClaude.Worker, queue: :pipeline, args: MyApp.Pipeline.base()

  @impl ObanClaude.Worker
  def handle_result(result, job) do
    n = job.args["issue"]
    MyApp.Pipeline.job(MyApp.Pipeline.implement_prompt(n, result.result), n)
    |> MyApp.ImplementWorker.new()
    |> Oban.insert()

    :ok
  end
end

# Stage 2: implement (opens draft PR) -> enqueue merge
defmodule MyApp.ImplementWorker do
  use ObanClaude.Worker, queue: :pipeline, args: MyApp.Pipeline.base()

  @impl ObanClaude.Worker
  def handle_result(_result, job) do
    n = job.args["issue"]
    MyApp.Pipeline.job(MyApp.Pipeline.merge_prompt(n), n, json_schema: MyApp.Pipeline.ci_schema())
    |> MyApp.MergeWorker.new()
    |> Oban.insert()

    :ok
  end
end

# Stage 3: merge-when-green -- snooze while CI is pending
defmodule MyApp.MergeWorker do
  use ObanClaude.Worker, queue: :pipeline, args: MyApp.Pipeline.base()

  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    case ObanClaude.structured(result) do
      %{"ci_status" => "green", "merged" => true} -> :ok
      %{"ci_status" => "pending"} -> {:snooze, 45}
      %{"ci_status" => "red"} -> {:cancel, :ci_failed}
      _ -> {:cancel, :unexpected}
    end
  end
end
```

The merge stage's prompt: find the PR that closes issue N, run `gh pr checks`,
and return `{ci_status, merged}` -- merging (review + `gh pr merge`) only when
every check is green, reporting `pending` otherwise. Each `pending` is one cheap
re-check; Oban holds the job between them.

This is the pipeline pattern for **any** async gate, not just CI: return a
structured "not ready yet" verdict and let `handle_result/2` snooze.

## Notes and gotchas

- **Worktree lifecycle.** A *named* worktree persists after the run -- that is
  what makes the pipeline handoff possible, but for a one-shot job it is cruft to
  prune (`git worktree remove`). `oban_claude` does not own git lifecycle;
  cleanup is the app's (or a maintenance job's).
- **Issue -> prompt is the app's job.** `oban_claude` is trigger-agnostic; how a
  webhook/poller/issue becomes a prompt lives in a source layer, not here. For
  composing the prompt itself, `ClaudeWrapper.Prompt` (one layer down) is a
  builder -- `new`/`append`/`attach`/`git_diff`/`git_log`/`vars`, and `render/1`
  returns the plain string `ObanClaude.Args` accepts. Note `render/1` does its
  file/git IO when called: render at enqueue to capture git state then, or
  render inside the job (a custom `:query_fun`) for run-time state.
- **Concurrency.** Independent jobs run concurrently, each in its own named
  worktree. Serialize (queue concurrency 1) only where later jobs depend on
  earlier ones landing (e.g. sequential merges into one branch).

## Retries cost money (and may repeat writes)

Every retry is a *fresh, full-price* claude run, and `max_budget_usd` caps a
single attempt, not the job. Worst-case spend per job is therefore
`max_attempts × max_budget_usd` (plus a little overspend -- the cap is checked
after each step, so a run can overshoot before it trips). Oban's default
`max_attempts` is **20**, so a worker that omits it can re-run a $2 job twenty
times.

- **Set `max_attempts` explicitly on every worker.** A mutating (full-auto)
  worker should use `max_attempts: 1` unless its prompt is genuinely idempotent
  -- retrying a run that already pushed a branch just does it again. Reserve
  retries for read-only / propose-only workers, where a re-run is cheap and safe.
- **Do not map a *successful* run to `{:error, _}`.** A run that produced a valid
  result succeeded, even when the *content* is a "blockers" verdict. Returning
  `{:error, _}` from `handle_result/2` re-runs the whole paid call; use
  `{:cancel, reason}` for a terminal verdict, and `{:error, _}` only when a
  re-run could actually change the outcome.

## Timeouts and stuck runs

Nothing is time-bounded by default: the args-level `:timeout` is unset (the CLI
call blocks indefinitely) and `Oban.Worker`'s `timeout/1` defaults to
`:infinity`. `max_turns` and `max_budget_usd` live *inside* the CLI and cannot
fire if the CLI itself wedges -- a network stall, a deadlocked stdio MCP server,
an unexpected interactive prompt. A wedged job holds its concurrency slot
indefinitely and emits no telemetry.

- **Set the args-level `:timeout`** (milliseconds) on every fleet worker, e.g.
  `timeout: :timer.minutes(15)`. This is the timeout that produces the typed
  `:timeout` error the classifier understands.
- **Do not reach for Oban's `timeout/1` as the fix.** It kills only the BEAM
  task; under the default runner the claude OS process keeps running (and
  spending) while Oban records a failure and retries -- now you have a duplicate
  paid run *and* an orphan. Keep `timeout/1` at `:infinity`, or strictly above
  the args `:timeout`. (See the next section for making a kill actually kill.)

## Process lifecycle: kill the CLI, not just the task

`oban_claude` runs the CLI synchronously inside the Oban job process. Under
claude_wrapper's **default** runner, killing that process -- an Oban timeout, an
`Oban.cancel_job`, a node shutdown -- closes the pipes but sends *no signal to
the OS process*: the `claude` CLI and its MCP-server children keep running and
usually finish, committing / pushing / opening a PR minutes after you believed
the job stopped.

For any fleet, switch to the leak-free runner claude_wrapper ships:

```elixir
# mix.exs
{:forcola, "~> 0.3"}

# config/runtime.exs (or config.exs)
config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola
```

It process-groups the CLI and SIGTERM/SIGKILLs the whole tree on timeout,
cancel, or BEAM death. Without it, a timed-out or cancelled run is still
executing -- which makes an immediate retry a double-spend / two-agents-on-one-
worktree hazard.

## Deploys and crash recovery

A claude job is **paid and non-idempotent**, which makes ordinary deploys the
sharp edge. Oban's `shutdown_grace_period` defaults to **15 seconds** -- far
below any real run -- so a deploy that catches a job mid-run abandons it in the
`executing` state (and, on the default runner, the CLI survives BEAM death and
finishes unsupervised).

- **Pause the claude queues before a deploy** (`Oban.pause_queue/2`), or raise
  `shutdown_grace_period` above your worst-case run.
- **Configure `Oban.Plugins.Lifeline`** to rescue orphaned `executing` jobs --
  it is opt-in (the default is `plugins: []`). But rescue is purely time-based:
  a healthy long run rescued mid-flight becomes a *second* concurrent paid run,
  so set `rescue_after` comfortably above your args `:timeout`, and pair it with
  forcola so the predecessor is actually dead first.
- With `max_attempts: 1`, Lifeline turns a rescued crash into a silent *discard*
  -- the work never happens and nothing retries. Choose deliberately.
- **Guard chained stages with `unique`.** `handle_result/2` enqueues the next
  stage non-atomically with the job completing, so a crash in between can re-run
  a stage *and* double-enqueue the next. A short `unique` window on the
  follow-on worker prevents the duplicate.

## Untrusted input

The full-auto and issue-work recipes interpolate external text (a GitHub issue
title/body, a webhook payload) into the prompt and run the agent with
`permission_mode: :bypass_permissions`, which auto-approves every tool call. That
agent can run arbitrary Bash and read anything the BEAM user can (`~/.ssh`,
`~/.aws`, the environment). A worktree isolates the *git checkout* -- not the
filesystem, network, or credentials. **Treat any externally sourced text as
adversarial:** whoever can file an issue can try to steer the agent.

For externally triggered work:

- Prefer the **propose / dispose** split: run read-only (`permission_mode:
  :default`), return a typed verdict, and let app-side code (an effector) make
  the change. The agent never holds write authority over untrusted input.
- When full-auto is unavoidable: **fence** the external text in the prompt
  (delimit it and tell the model it is untrusted data, not instructions), pin
  `disallowed_tools`, seal the environment with `hermetic: :full`, run under an
  OS user with minimal credentials, and require human review before merge.

## Fleet cost controls

`max_budget_usd` bounds one attempt; nothing bounds *N* runaway jobs (a
mis-configured poller, a hostile burst). oban_claude owns no state, so a
fleet-wide ceiling is an app-owned handler wiring three pieces it already gives
you: the `cost_usd` on every telemetry event, `ClaudeWrapper.Budget` (a
self-contained accumulator with `max_usd` / `on_exceeded`), and `Oban.pause_queue/2`.

```elixir
# Attach once at boot against a started ClaudeWrapper.Budget.
def attach(budget) do
  events = [[:oban_claude, :run, :stop], [:oban_claude, :run, :exception]]
  :telemetry.attach_many("claude-budget", events, &__MODULE__.record/4, budget)
end

# :exception carries cost_usd for rail-stop runs (0.0 otherwise), so summing
# BOTH events counts the capped runs -- a :stop-only ledger undercounts.
def record(_event, measurements, _meta, budget) do
  ClaudeWrapper.Budget.record(budget, measurements[:cost_usd] || 0.0)
end
```

Start the `Budget` with `on_exceeded: fn _ -> Oban.pause_queue(queue: :claude) end`,
and reset + `Oban.resume_queue/2` from a daily `Oban.Plugins.Cron` job. Per-queue
(rather than global) ledgers key on the `:job` metadata now on every event
(`meta.job.queue`). Anything with real policy -- persistence, multiple ledgers,
alerting -- belongs in a companion package, not here.

## Data handling

Job args are stored **verbatim as JSON** in the `oban_jobs` row -- the full
prompt, `system_prompt`, and every `:meta` value -- and kept until
`Oban.Plugins.Pruner` removes them, or **forever** if it is not configured
(Oban's default is `plugins: []`; the installer scaffolds none). The same args
map rides on every telemetry event, so a logging handler can write prompt
contents into your log pipeline; and claude_wrapper passes the prompt as argv,
so it is visible in `ps` to any local user on the host while a run is active.

- **Never put secrets or PII in a prompt or `:meta`.** Pass a *reference* and let
  the agent resolve it inside the run via its own env/tooling.
- **Configure `Oban.Plugins.Pruner`** with a `max_age` sized to the data's
  sensitivity -- otherwise args sit queryable in the DB, in Oban Web, and in
  every backup indefinitely.
- **Redact** `:args` / `:result` / `:error` telemetry metadata before shipping it
  to a log aggregator.
- Size **host trust** accordingly -- argv is world-readable in `ps`.

## Worktree hygiene

oban_claude passes `worktree` through to the CLI, which *creates* the worktree --
but nothing in the stack *removes* one. Two paths leak:

- **Ephemeral worktrees on a killed run.** `worktree: true` is cleaned up only
  when the CLI reaches end-of-run. An Oban timeout, `cancel_job`, deploy, or
  crash -- and forcola's kill-the-tree-on-timeout -- skips that, leaking a full
  checkout + branch + `.git/worktrees` metadata each time, until an unattended
  fleet fills the disk. Run a cron-scheduled maintenance job that lists
  worktrees (`ClaudeWrapper.Worktrees.for_repo/1`) and `git worktree remove
  --force`s aged, non-`main` ones.
- **Two jobs in one named worktree.** A named worktree assumes **at most one job
  touches it at a time**. A timeout-retry under the default runner (the orphan
  keeps writing), a Lifeline rescue, or an operator re-enqueue breaks that --
  two git agents contend on `index.lock` and interleave commits. Guard workers
  that take a named worktree with a `unique` on the worktree key, and pair it
  with forcola so a superseded run cannot still be writing:

  ```elixir
  use ObanClaude.Worker,
    queue: :pipeline,
    unique: [fields: [:args], keys: [:worktree],
             states: [:available, :scheduled, :executing, :retryable]]
  ```
