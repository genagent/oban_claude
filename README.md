# oban_claude

[![CI](https://github.com/genagent/oban_claude/actions/workflows/ci.yml/badge.svg)](https://github.com/genagent/oban_claude/actions/workflows/ci.yml)

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

The job args are the spec: `prompt` (required) plus any `claude_wrapper` query
option (`model`, `max_turns`, `max_budget_usd`, `working_dir`, `permission_mode`,
`timeout`, ...). Args are JSON, so atom-valued options are given as strings:
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

With no `:args`, a worker is a bare passthrough (the job carries everything). With
everything in `:args` and an empty job it is a routine: pair it with
`Oban.Plugins.Cron` for a scheduled claude task.

```elixir
config :my_app, Oban,
  plugins: [{Oban.Plugins.Cron, crontab: [{"0 9 * * *", MyApp.DailyDigest}]}]
```

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
| `:timeout` | `{:snooze, 30}` | transient; back off |
| `:command_failed` / `:json` / `:io` | `{:error, kind}` | likely transient; retry + backoff |
| `:auth` / `:binary_not_found` | `{:cancel, ...}` | global/env problem; retrying cannot help |
| `:budget_exceeded` / `:max_turns_exceeded` | `{:cancel, ...}` | the rails stopped it; resume/re-scope is deliberate |

## Testing

`ObanClaude.run/2` and `use ObanClaude.Worker` accept a `:query_fun` (default
`&ClaudeWrapper.query/2`): a `(prompt, query_opts)` function returning
`{:ok, %Result{}}` / `{:error, %Error{}}`. Override it to stub claude in tests
without a live call, or to route through a different `claude_wrapper` entrypoint.

## What it does NOT do

No state, no daemon, no "sink". It runs the agent and returns the
verdict. Whether the agent effects its own writes (full-auto) or returns
structured data for a downstream effector is the *job's* concern, encoded in the
prompt and permission mode. Persisting results and reacting to completion are the
caller's job (`handle_result/2` + the `[:oban_claude, :run, :stop]` telemetry).

See [SPEC.md](https://github.com/genagent/oban_claude/blob/main/SPEC.md) for the
design and the build-out checklist.
