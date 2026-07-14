# Changelog

## [0.1.0](https://github.com/genagent/oban_claude/releases/tag/v0.1.0) (2026-07-01)


### Features

* add a sample iex Claude console (examples/console.exs) ([#13](https://github.com/genagent/oban_claude/issues/13)) ([fab4ce1](https://github.com/genagent/oban_claude/commit/fab4ce1b797f68bdcf8a9aad4b28bb37a42b11d1))
* Args.defaults/1 (worker defaults) and a :meta channel for job metadata ([#40](https://github.com/genagent/oban_claude/issues/40)) ([ccde2a9](https://github.com/genagent/oban_claude/commit/ccde2a9554fedcd14fdab594e843f03dafa71d96))
* first-class Args.new/1 constructor ([#30](https://github.com/genagent/oban_claude/issues/30)) ([0ed13be](https://github.com/genagent/oban_claude/commit/0ed13be989346bba60ee75cc7a80e3503acab814))
* issue-triage dogfood example and live tests ([#25](https://github.com/genagent/oban_claude/issues/25)) ([e28f85a](https://github.com/genagent/oban_claude/commit/e28f85af748d7b2b4e9fdeb4e973a16c9cb0a11b))
* merge worker-level default args under job args ([#11](https://github.com/genagent/oban_claude/issues/11)) ([77e7edf](https://github.com/genagent/oban_claude/commit/77e7edfeff61700d5df51defc406d29f5758d78c))
* mix oban_claude.install (Igniter installer, SQLite + watch demo) ([#33](https://github.com/genagent/oban_claude/issues/33)) ([1845894](https://github.com/genagent/oban_claude/commit/1845894fd5a07946cca36d7d8ff751f20b96d51a))
* mix oban_claude.run one-shot task ([#37](https://github.com/genagent/oban_claude/issues/37)) ([a475a73](https://github.com/genagent/oban_claude/commit/a475a737e8d397395d5b3d0bdfbca15513b24c78))
* worktree isolation support (Args worktree option) ([#41](https://github.com/genagent/oban_claude/issues/41)) ([afac8bc](https://github.com/genagent/oban_claude/commit/afac8bc7f5820a61f1f073ad85a4c93268093f07))


### Bug Fixes

* address release-readiness audit findings ([#47](https://github.com/genagent/oban_claude/issues/47)) ([402c3c8](https://github.com/genagent/oban_claude/commit/402c3c81e427d56d113c55ffc025242a2e1af667))
* handle off-contract errors in Outcome.classify/1 ([#6](https://github.com/genagent/oban_claude/issues/6)) ([2a49607](https://github.com/genagent/oban_claude/commit/2a496078166a912cdcbbf69b018a2af2c58bb42c))
* harden the Oban-return classifier and lock the telemetry contract ([#26](https://github.com/genagent/oban_claude/issues/26)) ([1f3f642](https://github.com/genagent/oban_claude/commit/1f3f6425f55218c8e8b231ac8eab76a4ad24ad89))


### Miscellaneous Chores

* release initial version as 0.1.0 ([#36](https://github.com/genagent/oban_claude/issues/36)) ([1579e4d](https://github.com/genagent/oban_claude/commit/1579e4d4c3436c5b0936307b725a14f4ef03f34c))
