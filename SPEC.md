# oban_claude -- spec and build-out guide

This file is the brief for a focused session to finish `oban_claude`. The
skeleton already in `lib/` is the intended shape; this explains the why, the
decisions, and what is left to do.

## Purpose

`oban_claude` is the thin seam between **Oban** (a durable job queue) and
**claude_wrapper** (a typed, headless `claude -p` runner). It is one small
library: an `Oban.Worker` whose `perform/1` runs a claude query and maps the
result onto Oban's return values.

Design rule: **build as little as possible.** Oban owns the queue, the
transactional claim (`FOR UPDATE SKIP LOCKED`), retries/backoff, uniqueness, the
`Lifeline` reaper, the `Pruner`. claude_wrapper owns running claude and parsing
its `--output-format json` into a typed `%Result{}` / `%Error{}`. `oban_claude`
owns only the ~60 lines that connect them: an args -> query mapping and an
outcome -> Oban-atom classifier.

## Where it sits (context)

This package is one of three layers, deliberately separate:

- `oban_claude` (this) -- runs claude jobs on Oban. Knows claude, **not GitHub.**
- `oban_github` (separate, later) -- a GitHub **source** (an Oban plugin that
  polls a query and inserts jobs) and **sink reactor** (writes outcomes back).
  Knows GitHub, **not claude.**
- an application (last, named when its shape is clear) -- wires source -> claude
  worker, holds the policy (issue -> prompt mapping, label vocabulary). Knows
  both.

Symmetric blindness, app in the middle. `oban_claude` must stay GitHub-agnostic
so it is reusable for any trigger, not just GitHub.

### Sink-agnostic on purpose

A full-auto agent is its own sink: it opens the PR / comments **inside its turn**
with its own tools, so there is no separate projection step. The alternative
(agent runs read-only, returns structured data, a downstream effector applies it
-- "propose / dispose") is also supported. `oban_claude` does not pick: whether
the agent self-effects or proposes is encoded in the **job's** prompt + permission
mode, never here. Do not add GitHub or effector logic to this package.

## Public API (the intended surface)

- `ObanClaude.run(args, opts \\ []) :: {oban_return, %Result{} | %Error{}}`
  -- the engine. String-keyed `args` map in; `:prompt` required; `@passthrough`
  keys forwarded to `ClaudeWrapper.query/2`. `opts[:classifier]` overrides the
  default mapping.
- `ObanClaude.outcome(result) :: String.t() | nil` -- pull the structured-tasks
  `outcome` string out of `Result.structured_output/1`.
- `use ObanClaude.Worker, <oban opts>, classifier: fun` -- the drop-in worker.
  Injects `perform/1`; the one override point is the `handle_result/2` callback
  (default `:ok`).
- `ObanClaude.Outcome.classify/1` -- the default, documented, overridable
  classifier.

## Args contract

`prompt` (required) plus pass-through to `ClaudeWrapper.query/2`:

```
model  max_turns  max_budget_usd  working_dir  permission_mode  timeout
system_prompt  append_system_prompt  fallback_model  add_dir  json_schema
```

String keys (Oban args are JSON). `build/1` converts them with
`String.to_existing_atom/1`.

> BUILD-OUT: confirm every pass-through key is a real `ClaudeWrapper.query/2`
> option and that the value shapes match (e.g. `permission_mode` atom vs string,
> `max_budget_usd` float). Trim or rename to match the installed claude_wrapper.

## The classifier (the real content)

See `ObanClaude.Outcome` for the table. The two app-dependent rows are
`:budget_exceeded` and `:max_turns_exceeded` -- the default `{:cancel, ...}` is
the safe choice (the rails stopped it; a blind retry re-hits). An app whose
worker resumes reads the `session_id` off the rail-stop `%Error{}` in
`handle_error/3` (via `ObanClaude.session_id/1`) and enqueues a follow-on job
with `resume:` + the same named worktree; a classifier override can additionally
change the verdict to `{:snooze, n}` or `{:error, ...}`.

> DECISION TO REVISIT: is the default `:cancel` for max_turns right, or should it
> be `{:error, ...}` (retry) on the assumption the tree is usually complete (the
> roba #308 lesson)? Leaning cancel-by-default because a non-resuming retry just
> re-burns budget. Document the override clearly.

## Telemetry

Emit `[:oban_claude, :run, :stop]` (`%{duration, cost_usd}`, `%{result, args}`)
on success and `[:oban_claude, :run, :exception]` on a wrapper error. The app
attaches handlers (cost accounting, logging) without coupling.

## What it does NOT do

No persistence (the app / `handle_result/2` does it), no GitHub, no sink, no
daemon, no state. Keep it that way.

## Build-out checklist

1. `mix deps.get` (pulls oban + the claude_wrapper path dep). Confirm it compiles.
2. Verify the `%ClaudeWrapper.Result{}` and `%ClaudeWrapper.Error{}` field names
   and the `Error.kind` atom set against the installed claude_wrapper
   (`lib/claude_wrapper/result.ex`, `error.ex`). Fix the structs used in
   `test/oban_claude_test.exs` and the `classify/1` guards to match exactly.
3. Confirm `ClaudeWrapper.query/2`'s option names; align `@passthrough`.
4. Decide the `permission_mode` value shape (the worker for autonomous work will
   want `:bypass_permissions` / full-auto -- confirm the wrapper's term).
5. Add a structured-output path: a `:schema` worker option routing through
   `ClaudeWrapper.Structured.run/3` so a `--json-schema` outcome is parsed; have
   `handle_result/2` receive the parsed struct. (Optional for v1; the
   `ObanClaude.outcome/1` helper is the minimal stand-in.)
6. Tests: the `Outcome.classify/1` tests are pure and should pass once the
   structs match. Add a worker test with a stubbed `ObanClaude.run/1` (inject the
   classifier, or make `run` mockable) so `perform/1` is covered without calling
   claude. A live test (tagged, opt-in) that actually runs a tiny query is worth
   one smoke case -- assert mechanics (it returns `:ok` and a `%Result{}`), never
   model content.
7. `mix format`, `mix docs`, a LICENSE (MIT), and a `git init` + first commit.
8. Decide hex publish vs path-dep-for-now (claude_wrapper is itself a path dep
   until released, so this stays unpublished until that does).

## Guideline references

The pattern to model is Oban's own worker macro and Pro's wrap-and-extend worker:

- `Oban.Worker` source -- the canonical `__using__` macro + behaviour +
  `defoverridable`: <https://github.com/oban-bg/oban/blob/main/lib/oban/worker.ex>
- `Oban.Worker` docs (v2.23): <https://hexdocs.pm/oban/Oban.Worker.html>
- `Oban.Pro.Worker` -- the "library worker that wraps Oban.Worker and adds
  callbacks" shape we are copying: <https://oban.pro/docs/pro/Oban.Pro.Worker.html>
- Writing Oban plugins (for `oban_github` later):
  <https://oban.hexdocs.pm/writing_plugins.html>
- `defoverridable` fallbacks pattern (DockYard):
  <https://dockyard.com/blog/2024/04/18/use-macro-with-defoverridable-function-fallbacks>

## Open questions

- Ready-made worker vs behaviour-only? Currently both: `ObanClaude.run/1`
  (function, for any caller) + `use ObanClaude.Worker` (drop-in). Keep both.
- Should `oban_claude` ship a default queue/Oban config helper, or stay
  config-free and leave Oban setup entirely to the host app? Leaning config-free.
- Naming: `oban_claude` reads as an official Oban extension. Acceptable
  (community `oban_*` packages exist), but `claude_oban` is an alternative if the
  association is unwanted.
