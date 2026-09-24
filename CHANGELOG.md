# Changelog

## [0.7.1](https://github.com/genagent/oban_claude/compare/v0.7.0...v0.7.1) (2026-09-24)


### Bug Fixes

* gate doctor on auth login state (closes [#138](https://github.com/genagent/oban_claude/issues/138)) ([#142](https://github.com/genagent/oban_claude/issues/142)) ([15eb11f](https://github.com/genagent/oban_claude/commit/15eb11f0605e54fe72021c35a7e302ab9c0ac338))
* make agent action ids restart-safe (closes [#131](https://github.com/genagent/oban_claude/issues/131)) ([#140](https://github.com/genagent/oban_claude/issues/140)) ([c0a0602](https://github.com/genagent/oban_claude/commit/c0a060284278cc3eb6183e273a9c7d2530087c5b))

## [0.7.0](https://github.com/genagent/oban_claude/compare/v0.6.1...v0.7.0) (2026-09-24)


### Features

* preserve application correlation through agent turns (closes [#135](https://github.com/genagent/oban_claude/issues/135)) ([#136](https://github.com/genagent/oban_claude/issues/136)) ([a618817](https://github.com/genagent/oban_claude/commit/a61881771209eded27ab1453fc9ed3affd1919c7))

## [0.6.1](https://github.com/genagent/oban_claude/compare/v0.6.0...v0.6.1) (2026-09-24)


### Bug Fixes

* contain enqueue failures without terminating the agent ([#133](https://github.com/genagent/oban_claude/issues/133)) ([bbffdd3](https://github.com/genagent/oban_claude/commit/bbffdd32d2535e30fc4fbca5be01c612d1c00267))

## [0.6.0](https://github.com/genagent/oban_claude/compare/v0.5.1...v0.6.0) (2026-09-23)


### Features

* add named session arcs ([#129](https://github.com/genagent/oban_claude/issues/129)) ([f4a5491](https://github.com/genagent/oban_claude/commit/f4a54914bcac3a33c441da382c556150dac3ebda))

## [0.5.1](https://github.com/genagent/oban_claude/compare/v0.5.0...v0.5.1) (2026-09-23)


### Bug Fixes

* correlate agent callbacks with their owning turn and generation (closes [#124](https://github.com/genagent/oban_claude/issues/124)) ([#125](https://github.com/genagent/oban_claude/issues/125)) ([f1e1885](https://github.com/genagent/oban_claude/commit/f1e1885e3892e904657f37db64bcb36d3fc48cf0))

## [0.5.0](https://github.com/genagent/oban_claude/compare/v0.4.0...v0.5.0) (2026-09-20)


### Features

* approve_action can carry args for that one continuation (closes [#121](https://github.com/genagent/oban_claude/issues/121)) ([#122](https://github.com/genagent/oban_claude/issues/122)) ([3233211](https://github.com/genagent/oban_claude/commit/32332113761f64e3400af70852c2ae547d8f53d4))
* emit run-start telemetry before the claude subprocess launches ([#120](https://github.com/genagent/oban_claude/issues/120)) ([b08d1b8](https://github.com/genagent/oban_claude/commit/b08d1b89811595cde0e0aedd65ca976901a4d9ad))
* stamp the conversational arc's origin into agent job meta ([#118](https://github.com/genagent/oban_claude/issues/118)) ([0e8835c](https://github.com/genagent/oban_claude/commit/0e8835c6c0a85425db98b22377a3b3d4a0b2bad5))

## [0.4.0](https://github.com/genagent/oban_claude/compare/v0.3.0...v0.4.0) (2026-07-21)


### Features

* add the agent lifecycle layer (ObanClaude.Agent) ([#115](https://github.com/genagent/oban_claude/issues/115)) ([5f3d80e](https://github.com/genagent/oban_claude/commit/5f3d80e184040186bc60ac47a70bbed5379ce0c5))

## [0.3.0](https://github.com/genagent/oban_claude/compare/v0.2.0...v0.3.0) (2026-07-14)


### Features

* adopt claude_wrapper 0.14.0 and expose its new one-shot query flags ([#112](https://github.com/genagent/oban_claude/issues/112)) ([f2de7c6](https://github.com/genagent/oban_claude/commit/f2de7c608cafe85710200697bc58e6186282b8f7))

## [0.2.0](https://github.com/genagent/oban_claude/compare/v0.1.0...v0.2.0) (2026-07-14)


### ⚠ BREAKING CHANGES

* the one-shot CLI moved from `mix oban_claude.run "..."` to `mix oban_claude run "..."` (a cheer subcommand). The prompt is still the first positional argument and every flag is unchanged; `--prompt` is dropped in favor of the positional.

### Features

* add :binary passthrough; make the Args&lt;-&gt;passthrough round-trip exhaustive ([#105](https://github.com/genagent/oban_claude/issues/105)) ([f076da7](https://github.com/genagent/oban_claude/commit/f076da7cfeeafbe6170d6ed1feb10231047a03cf))
* add ObanClaude.Testing, a builder for :query_fun stub returns ([#107](https://github.com/genagent/oban_claude/issues/107)) ([e2a41e5](https://github.com/genagent/oban_claude/commit/e2a41e5e7beda41dedffd9f196d60ff0661f1777)), closes [#81](https://github.com/genagent/oban_claude/issues/81)
* expose claude_wrapper's :hermetic config seal as an args option ([#59](https://github.com/genagent/oban_claude/issues/59)) ([5610800](https://github.com/genagent/oban_claude/commit/5610800e419f00453b38733db345a70e6baa9f1c)), closes [#58](https://github.com/genagent/oban_claude/issues/58)
* harden the mix tasks and telemetry for unattended fleets ([#100](https://github.com/genagent/oban_claude/issues/100)) ([de56cee](https://github.com/genagent/oban_claude/commit/de56ceeca825be91d8d806dd2af55d9dcf74c07a))
* pin worker args, harden :meta, validate args at the seam ([#98](https://github.com/genagent/oban_claude/issues/98)) ([509fd1c](https://github.com/genagent/oban_claude/commit/509fd1c36aaffaad97ddbaf4225993e4d8fddd7e))
* rebuild the CLI as a cheer `mix oban_claude` command tree (run/doctor/args) ([#109](https://github.com/genagent/oban_claude/issues/109)) ([7b29683](https://github.com/genagent/oban_claude/commit/7b29683dca675b89cbe9d2f40a51a48ddd4d58b2)), closes [#102](https://github.com/genagent/oban_claude/issues/102)
* session continuity + job-aware error handling (handle_error/3) ([#108](https://github.com/genagent/oban_claude/issues/108)) ([700ef86](https://github.com/genagent/oban_claude/commit/700ef8609487557055e0cfef64bc434d32ad5f36))


### Bug Fixes

* cancel :max_budget_exceeded rail stop instead of retrying it ([#56](https://github.com/genagent/oban_claude/issues/56)) ([f410ed1](https://github.com/genagent/oban_claude/commit/f410ed12e0aa630b69ef8ce2fea546f595704cfe)), closes [#55](https://github.com/genagent/oban_claude/issues/55)
* **ci:** harden the release workflow before publishing to Hex ([#101](https://github.com/genagent/oban_claude/issues/101)) ([f7b450c](https://github.com/genagent/oban_claude/commit/f7b450ccf23a48af4d5f4b2963bec6f1b5c58141)), closes [#66](https://github.com/genagent/oban_claude/issues/66)
* classifier correctness pass — bounded retries, envelope validation, accurate specs ([#97](https://github.com/genagent/oban_claude/issues/97)) ([0b78b3b](https://github.com/genagent/oban_claude/commit/0b78b3bc5b6c0829c339c66ce97f5ba54bbe947d))

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
