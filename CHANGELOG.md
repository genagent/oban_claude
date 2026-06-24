# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0]

Initial release.

### Added

- `ObanClaude.run/2`: run a claude job from a string-keyed args map and map the
  typed `%ClaudeWrapper.Result{}` / `%ClaudeWrapper.Error{}` onto an Oban return
  value. Options `:classifier` and `:query_fun`.
- `ObanClaude.Worker`: a `use`-able `Oban.Worker` with a single `handle_result/2`
  override point.
- `use ObanClaude.Worker, args: %{...}`: worker-level default claude args, merged
  under each job's args (the job wins). A bare worker is a passthrough; a fully
  preconfigured worker with an empty job is a routine (pair with
  `Oban.Plugins.Cron`).
- `ObanClaude.Outcome.classify/1`: the default, overridable outcome to
  Oban-return mapping, including a catch-all that cancels off-contract errors.
- `ObanClaude.outcome/1` and `ObanClaude.structured/1`: read the structured
  output of a `--json-schema` run.
- `[:oban_claude, :run, :stop]` and `[:oban_claude, :run, :exception]` telemetry.
