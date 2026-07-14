defmodule ObanClaude.Outcome do
  @moduledoc """
  The default mapping from `claude_wrapper`'s typed result/error onto Oban's
  return values. Override per-worker with `use ObanClaude.Worker, classifier: &MyMod.classify/1`.

  The mapping encodes the right Oban semantics for each claude failure mode:

  | claude outcome                       | Oban             | why |
  |--------------------------------------|------------------|-----|
  | `%Result{is_error: false}`           | `{:ok, result}`  | success; the worker's `handle_result/2` decides the final atom |
  | `%Result{is_error: true}`            | `{:error, :result_error}` | claude emitted an error result with valid JSON; retry, bounded by `max_attempts` |
  | `%Error{kind: :timeout}`             | `{:error, :timeout}` | transient; retry with backoff, bounded by `max_attempts` |
  | `%Error{kind: :auth, reason: :rate_limit}` | `{:error, :rate_limit}` | rate/quota limit is transient; retry (bounded) rather than cancel |
  | `%Error{kind: :command_failed/:json/:io}` | `{:error, kind}` | likely transient infra; retry with backoff |
  | missing/unrunnable binary (`:io` + `:enoent`/`:eacces`) | `{:cancel, :binary_not_found}` | the CLI is absent or not executable; re-fails identically |
  | a config/env fault (see below)       | `{:cancel, kind}` | the same broken environment re-fails identically; a retry only burns budget |
  | `%Error{kind: :budget_exceeded/:max_budget_exceeded/:max_turns_exceeded}` | `{:cancel, kind}` | the rails stopped it; resuming is a deliberate act, not a blind retry |
  | any other typed `%Error{}`           | `{:error, kind}` | unknown but typed; retry under `max_attempts`, then dead-letter |
  | a non-`%Error{}` error term          | `{:cancel, ...}` | off-contract and unclassifiable; do not blindly re-run |

  ## The default mapping never snoozes

  Oban implements `{:snooze, n}` by *incrementing* `max_attempts` (the engine's
  snooze bumps the attempt ceiling), so a snooze never consumes an attempt. A job
  that deterministically fails the same way -- a run that always exceeds its
  `:timeout`, a permanently rate-limited key -- would therefore snooze
  **forever**: unbounded paid re-runs, no dead-letter, no operator signal. So
  every transient outcome above maps to `{:error, _}` instead, letting
  `max_attempts` + backoff bound the retries. A worker that genuinely wants
  snooze semantics (e.g. `{:snooze, {1, :hour}}` to ride out a rate-limit
  window) opts in with a `:classifier` override -- accepting that it bypasses
  `max_attempts`.

  Two `:timeout` cautions for unattended fleets: claude_wrapper's default
  runner does **not** kill the timed-out CLI process (it can keep running and
  complete its side effects -- a commit, a push, a PR -- after Oban re-queues
  the job), so configure `config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola`
  for strict termination; and a re-queued timeout is a fresh, full-price run.

  ## Config/environment faults

  The faults that cancel are `:auth` (every reason except `:rate_limit`, which
  retries -- see above), `:version_mismatch`, `:invalid_version`,
  `:dangerous_not_allowed`, `:invalid_tool_pattern`, plus `:binary_not_found`,
  `:not_a_git_repo`, and `:git_unavailable`. A missing or unauthenticated
  binary, an unusable CLI version, a disallowed flag, or a malformed tool
  pattern fails the same way on every attempt, so retrying cannot help.

  The last three (`:binary_not_found`, `:not_a_git_repo`, `:git_unavailable`)
  are retained for custom `:query_fun` paths but are **unreachable via the
  default `ClaudeWrapper.query/2`**: a missing binary surfaces as `:io` with an
  `:enoent`/`:eacces` reason (cancelled as `:binary_not_found` by the dedicated
  clause), and a non-git `working_dir` under `:worktree` surfaces as
  `:command_failed` (retried). Do not build monitoring on those three kinds
  appearing on the default path. (The `:io`/`:enoent` cancel only fires on the
  no-`:timeout` path; with a `:timeout` arg the spawn raises inside the run
  Task, which Oban records as a crash and retries.)

  The rail-stop rows -- `:budget_exceeded` (a client-side ceiling),
  `:max_budget_exceeded` (claude's own `--max-budget-usd` cap), and
  `:max_turns_exceeded` -- are the genuinely app-dependent ones. An app that
  resumes the run rather than restarting it reads the `session_id` off the
  rail-stop `%Error{}` in `c:ObanClaude.Worker.handle_error/3` (via
  `ObanClaude.session_id/1`) and enqueues a follow-on job with `resume:` + the
  same named worktree -- the "session-resume handoff" pattern in the Agent worker
  patterns guide. The classifier override is for a *verdict* change (e.g. a
  bounded snooze); the resume *effect* belongs in `handle_error/3`.

  An `{:error, term}` that is not a typed `%Error{}` (off the documented
  contract, e.g. a custom `:query_fun` routing through
  `ClaudeWrapper.Structured.run/3`, whose `parse/1` and `Jason` paths return
  non-`Error` terms) is cancelled rather than retried: an unclassifiable
  failure should not be blindly re-run.
  """

  alias ClaudeWrapper.{Error, Result}

  # Config/environment faults: a missing or unauthenticated binary, an unusable
  # CLI version, a disallowed flag, or a malformed tool pattern re-fails
  # identically on every attempt. Cancel so the job dead-letters at once rather
  # than burning the whole `max_attempts` budget on a retry that cannot succeed.
  # `:binary_not_found`/`:not_a_git_repo`/`:git_unavailable` are kept for custom
  # `:query_fun` paths but never reach here via the default query -- see the
  # moduledoc.
  @config_faults [
    :auth,
    :binary_not_found,
    :version_mismatch,
    :invalid_version,
    :dangerous_not_allowed,
    :invalid_tool_pattern,
    :not_a_git_repo,
    :git_unavailable
  ]

  # The rails deliberately stopped a run that was otherwise progressing. A blind
  # retry just re-burns the same budget or turn ceiling; resuming is a deliberate
  # act for the app (read session_id off the %Error{} in handle_error/3, enqueue
  # a resume: job into the same named worktree).
  # `:budget_exceeded` is the client-side ceiling; `:max_budget_exceeded` is
  # claude's own `--max-budget-usd` cap. Both stop the same way -- retrying
  # re-burns the spend -- so both cancel.
  @rail_stops [:budget_exceeded, :max_budget_exceeded, :max_turns_exceeded]

  # The `System.cmd/3` spawn (no-`:timeout` path) raises `ErlangError` with
  # these `:original` reasons when the CLI binary is absent or not executable;
  # claude_wrapper rescues it to `%Error{kind: :io, reason: {:io, e}}`. Both are
  # deterministic, so cancel rather than retry to exhaustion as a generic `:io`.
  @unrunnable_binary [:enoent, :eacces]

  @doc "Map `ClaudeWrapper.query/2`'s return onto `{oban_return, term}`."
  @spec classify({:ok, Result.t()} | {:error, term()}) ::
          {ObanClaude.oban_return(), Result.t() | Error.t() | term()}
  def classify({:ok, %Result{is_error: false} = result}), do: {:ok, result}

  def classify({:ok, %Result{is_error: true} = result}), do: {{:error, :result_error}, result}

  # Transient, but NOT via snooze (snooze bypasses `max_attempts` -- see the
  # moduledoc). `{:error, :timeout}` lets backoff + `max_attempts` bound it.
  def classify({:error, %Error{kind: :timeout} = error}), do: {{:error, :timeout}, error}

  # Rate/quota limit folds into the `:auth` kind but is transient (the window
  # resets), so retry it rather than cancel like the other `:auth` reasons.
  def classify({:error, %Error{kind: :auth, reason: :rate_limit} = error}),
    do: {{:error, :rate_limit}, error}

  def classify({:error, %Error{kind: kind} = error})
      when kind in @config_faults or kind in @rail_stops,
      do: {{:cancel, kind}, error}

  # The real missing/unrunnable-binary shape on the default query path (see the
  # moduledoc): cancel rather than let it retry to exhaustion as a generic `:io`.
  def classify({:error, %Error{kind: :io, reason: {:io, %ErlangError{original: reason}}} = error})
      when reason in @unrunnable_binary,
      do: {{:cancel, :binary_not_found}, error}

  def classify({:error, %Error{kind: kind} = error}), do: {{:error, kind}, error}

  # Off-contract: an error term that is not a typed %Error{} (e.g. a Structured
  # parse/Jason failure routed in via :query_fun). Cancel rather than retry
  # something we cannot classify.
  def classify({:error, other}), do: {{:cancel, other}, other}
end
