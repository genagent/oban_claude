# Agent worker patterns

Worked recipes for running claude agents on an Oban queue with `oban_claude`.
These are **patterns to read and copy, not modules to install** -- each is a
`use ObanClaude.Worker` plus an `ObanClaude.Args` config and a
`c:ObanClaude.Worker.handle_result/2`. They were validated by driving oban_claude
against a real repository (implementing issues, reviewing and merging the PRs,
and auditing itself).

`oban_claude` stays a thin seam: it runs one claude turn per job and maps the
result onto an Oban return. Everything below is composition on top of that.

## The three pillars of an unattended worker

A job runs with no human watching, so a full-auto worker needs three things.

1. **Isolation.** Run in a git worktree so concurrent jobs never collide in one
   working copy. Set it in the worker defaults:

   ```elixir
   use ObanClaude.Worker,
     queue: :agents,
     args: ObanClaude.Args.defaults(working_dir: "/repo", worktree: true)
   ```

   A per-job `worktree: "issue-42"` (a named worktree) overrides the default and
   lets a chain of jobs share one worktree.

2. **Guardrails.** A one-shot job has no one to stop it. Cap it with `max_turns`
   and `max_budget_usd`; the default classifier turns `:max_turns_exceeded` /
   `:budget_exceeded` into `{:cancel, _}`. These are load-bearing, not optional.

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
`permission_mode: :default` (non-interactive = writes blocked) and returns a
typed verdict via `--json-schema`. This is the propose/dispose split: the agent
*proposes* structured findings; `handle_result/2` *disposes* of them.

```elixir
defmodule MyApp.AuditWorker do
  use ObanClaude.Worker,
    queue: :audit,
    args: ObanClaude.Args.defaults(working_dir: "/repo", append_system_prompt: "…read-only, single-turn…"),
    # `permission_mode` is this worker's safety property, so pin it: `:pinned_args`
    # merges over the job, so an inserted job cannot escalate to full-write by
    # supplying its own `permission_mode`. (In `:args` it would only be a default.)
    pinned_args: ObanClaude.Args.defaults(permission_mode: :default)

  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    case ObanClaude.structured(result) do
      %{"overall" => verdict, "findings" => findings} ->
        report(verdict, findings)
        if verdict == "blockers", do: {:error, :blockers}, else: :ok

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
  webhook/poller/issue becomes a prompt lives in a source layer, not here.
- **Concurrency.** Independent jobs run concurrently, each in its own named
  worktree. Serialize (queue concurrency 1) only where later jobs depend on
  earlier ones landing (e.g. sequential merges into one branch).
