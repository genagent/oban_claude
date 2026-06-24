# oban_claude

Run [Claude Code](https://github.com/anthropics/claude-code) jobs on an
[Oban](https://hex.pm/packages/oban) queue. A thin, GitHub-agnostic worker over
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
`timeout`, ...).

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

## What it does NOT do

No GitHub, no state, no daemon, no "sink". It runs the agent and returns the
verdict. Whether the agent effects its own writes (full-auto) or returns
structured data for a downstream effector is the *job's* concern, encoded in the
prompt and permission mode. Persisting results and reacting to completion are the
caller's job (`handle_result/2` + the `[:oban_claude, :run, :stop]` telemetry).

See [SPEC.md](SPEC.md) for the design and the build-out checklist.
