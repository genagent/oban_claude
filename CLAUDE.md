# oban_claude

An `Oban.Worker` over [`claude_wrapper`](https://hex.pm/packages/claude_wrapper):
it runs Claude Code jobs on an Oban queue and maps claude's typed `%Result{}` /
`%Error{}` onto Oban return values. This package is only the thin seam between
the two. Oban owns the queue (transactional claim, retries, uniqueness,
Lifeline, Pruner); claude_wrapper owns running claude.

## Surface

- `ObanClaude.run/2` -- the engine: a string-keyed args map in, `{oban_return, result}` out. Options: `:classifier` and `:query_fun`.
- `ObanClaude.Worker` -- `use ObanClaude.Worker, <oban opts>`; the one override point is `handle_result/2`.
- `ObanClaude.Outcome.classify/1` -- the default, overridable outcome -> Oban-return mapping.
- `ObanClaude.outcome/1` and `structured/1` -- read structured output from a `--json-schema` run.

## Scope

Build as little as possible: this is the ~60 lines between Oban and claude,
nothing more. It owns no state, runs no daemon, and takes no position on what
consumes a result (the agent may effect its own writes, or return structured
data for a downstream effector). A separate `oban_github` package (a source
plugin and a sink) and the app that wires them together live elsewhere.

`SPEC.md` holds the original design brief and the build-out history.

## Conventions

- Elixir `~> 1.20`, OTP 29. `claude_wrapper` is a Hex dependency.
- Run `mix format`, `mix compile --warnings-as-errors`, and `mix test` before every push; CI runs the same.
- The `:live`-tagged test makes a real, paid claude call and is excluded by default. Run it with `mix test --only live`.
- `dev/playground.exs` and `dev/propose_dispose.exs` run the worker offline on a throwaway SQLite-backed Oban: `mix run dev/<script>.exs`.
- Feature branch + draft PR for changes; conventional-commit messages; no AI-attribution trailers in commits or PRs.
