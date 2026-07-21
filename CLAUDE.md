# oban_claude

An `Oban.Worker` over [`claude_wrapper`](https://hex.pm/packages/claude_wrapper):
it runs Claude Code jobs on an Oban queue and maps claude's typed `%Result{}` /
`%Error{}` onto Oban return values. This package is only the thin seam between
the two. Oban owns the queue (transactional claim, retries, uniqueness,
Lifeline, Pruner); claude_wrapper owns running claude.

## Surface

- `ObanClaude.run/2` -- the engine: a string-keyed args map in, `{oban_return, result}` out. Options: `:classifier` and `:query_fun`.
- `ObanClaude.Worker` -- `use ObanClaude.Worker, <oban opts>`; `:args` are default claude args merged under each job's args (the job wins). `handle_result/2` (success) and `handle_error/3` (every non-`:ok` verdict, with the run payload + job -- the home for a resume enqueue) are the override points.
- `ObanClaude.Args.new/1` / `defaults/1` -- the validated builder (atom keys in, the string map out); `defaults/1` is prompt-optional for worker `:args`, and a `:meta` map rides through untouched. `worktree` and the session keys (`resume`, `session_id`, `fork_session`, `no_session_persistence`) are normal options.
- `ObanClaude.Outcome.classify/1` -- the default, overridable outcome -> Oban-return mapping.
- `ObanClaude.outcome/1` and `structured/1` -- read structured output from a `--json-schema` run. `ObanClaude.session_id/1` / `cost_usd/1` -- read the resume handle / spend off a `%Result{}` or a rail-stop `%Error{}`.
- `mix oban_claude` -- a `cheer` command tree: `run` (one queueless claude run), `doctor` (fleet pre-flight: binary/version/auth), `args` (dry-run print `Args.new/1`). Shared parsing/rendering lives in `ObanClaude.CLI` (+ `ObanClaude.CLI.{Run,Doctor,Args}`). `mix oban_claude.install` -- Igniter installer that scaffolds a SQLite-backed setup (needs Igniter present first).
- `ObanClaude.Agent` (experimental) -- the opt-in stateful layer: one agent = one `:gen_statem` whose turns run as worker jobs, session id threading turn to turn. Facade: `start_agent`/`status`/`await`/`list`/`submit_prompt`/`cast_prompt` (with `session:`/`origin:` options)/`approve_action` (elevated via `:approved_args`, re-gates if incomplete)/`reject_action`/`emergency_pause`/`resume_agent`/`info`/`history`; `job_finished`/`job_retrying` are the worker return path. `ObanClaude.Agent.Tick` adapts `Oban.Plugins.Cron` (crontab entry = self-restarting routine; runs on its own `:ticks` queue). Host opt-in: `ObanClaude.Agent.Supervisor` in the tree. Guide: `guides/agent_lifecycle.md`; test seam: `:enqueue_fun` + `job_finished/2`.

## Scope

The core stays as little as possible: the thin seam between Oban and claude.
It takes no position on what consumes a result (the agent may effect its own
writes, or return structured data for a downstream effector). The one
deliberate stateful exception is the opt-in `ObanClaude.Agent` layer (zero
extra deps, inert without its supervisor); it owns lifecycle only. Operational
concerns (durable spend/budgets, notebooks, gate persistence, notifications,
dashboards, MCP surfaces) belong in apps -- the reference app is `../custode`.
The extraction trigger for the agent layer into its own package is the first
HARD dep the seam should not carry; optional deps do not count. A separate
`oban_github` package (a source plugin and a sink) and the app that wires
them together live elsewhere.

`SPEC.md` holds the original design brief and the build-out history.

## Conventions

- Elixir `~> 1.20`, OTP 29. `claude_wrapper` is a Hex dependency, pinned to the
  `~> 0.13.0` line: this library hardcodes its contract (`@passthrough` keys, the
  permission_mode/effort/hermetic vocabularies, the `Outcome` error kinds), so
  bump it deliberately per wrapper release and re-verify those lists.
- Run `mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix docs --warnings-as-errors`, `mix test`, and `mix dialyzer` before every push; CI runs the same.
- The `:live`-tagged test makes a real, paid claude call and is excluded by default. Run it with `mix test --only live`.
- `examples/playground.exs` and `examples/propose_dispose.exs` run the worker offline on a throwaway SQLite-backed Oban: `mix run examples/<script>.exs`.
- Feature branch + draft PR for changes; conventional-commit messages; no AI-attribution trailers in commits or PRs.
