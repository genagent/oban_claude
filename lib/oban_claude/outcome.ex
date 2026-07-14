defmodule ObanClaude.Outcome do
  @moduledoc """
  The default mapping from `claude_wrapper`'s typed result/error onto Oban's
  return values. Override per-worker with `use ObanClaude.Worker, classifier: &MyMod.classify/1`.

  The mapping encodes the right Oban semantics for each claude failure mode:

  | claude outcome                       | Oban             | why |
  |--------------------------------------|------------------|-----|
  | `%Result{is_error: false}`           | `{:ok, result}`  | success; the worker's `handle_result/2` decides the final atom |
  | `%Result{is_error: true}`            | `{:error, ...}`  | claude emitted an error result with valid JSON; retry, capped by `max_attempts` |
  | `%Error{kind: :timeout}`             | `{:snooze, 30}`  | transient; back off and retry soon |
  | `%Error{kind: :command_failed/:json/:io}` | `{:error, kind}` | likely transient infra; retry with backoff |
  | a config/env fault (see below)       | `{:cancel, kind}` | the same broken environment re-fails identically; a retry only burns budget |
  | `%Error{kind: :budget_exceeded/:max_budget_exceeded/:max_turns_exceeded}` | `{:cancel, kind}` | the rails stopped it; resuming is a deliberate act, not a blind retry |
  | any other typed `%Error{}`           | `{:error, kind}` | unknown but typed; retry under `max_attempts`, then dead-letter |
  | a non-`%Error{}` error term          | `{:cancel, ...}` | off-contract and unclassifiable; do not blindly re-run |

  The config/env faults that cancel are `:auth`, `:binary_not_found`,
  `:version_mismatch`, `:invalid_version`, `:dangerous_not_allowed`,
  `:invalid_tool_pattern`, `:not_a_git_repo`, and `:git_unavailable`: a missing or
  unauthenticated binary, an unusable CLI version, a disallowed flag, a malformed
  tool pattern, or a `worktree` run against a non-git directory or a host without
  git fails the same way on every attempt, so retrying cannot help and only
  delays the dead-letter.

  The rail-stop rows -- `:budget_exceeded` (a client-side ceiling),
  `:max_budget_exceeded` (claude's own `--max-budget-usd` cap), and
  `:max_turns_exceeded` -- are the genuinely app-dependent ones. An app whose
  worker resumes via a pinned `--session-id` may prefer `{:snooze, n}` or
  `{:error, ...}` there. That is exactly what the `:classifier` override is for.

  An `{:error, term}` that is not a typed `%Error{}` (off the documented
  contract, e.g. a custom `:query_fun` routing through
  `ClaudeWrapper.Structured.run/3`, whose `parse/1` and `Jason` paths return
  non-`Error` terms) is cancelled rather than retried: an unclassifiable
  failure should not be blindly re-run.
  """

  alias ClaudeWrapper.{Error, Result}

  @snooze_seconds 30

  # Config/environment faults: a missing or unauthenticated binary, an unusable
  # CLI version, a disallowed flag, a malformed tool pattern, or a `worktree` run
  # against a non-git dir / a host without git re-fails identically on every
  # attempt. Cancel so the job dead-letters at once rather than burning the whole
  # `max_attempts` budget on a retry that cannot succeed.
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
  # retry just re-burns the same budget or turn ceiling; resuming a pinned
  # `--session-id` is a deliberate act for the app (override the classifier).
  # `:budget_exceeded` is the client-side ceiling; `:max_budget_exceeded` is
  # claude's own `--max-budget-usd` cap. Both stop the same way -- retrying
  # re-burns the spend -- so both cancel.
  @rail_stops [:budget_exceeded, :max_budget_exceeded, :max_turns_exceeded]

  @doc "Map `ClaudeWrapper.query/2`'s return onto `{oban_return, term}`."
  @spec classify({:ok, Result.t()} | {:error, term()}) ::
          {ObanClaude.oban_return(), Result.t() | term()}
  def classify({:ok, %Result{is_error: false} = result}), do: {:ok, result}

  def classify({:ok, %Result{is_error: true} = result}), do: {{:error, :result_error}, result}

  def classify({:error, %Error{kind: :timeout} = error}), do: {{:snooze, @snooze_seconds}, error}

  def classify({:error, %Error{kind: kind} = error})
      when kind in @config_faults or kind in @rail_stops,
      do: {{:cancel, kind}, error}

  def classify({:error, %Error{kind: kind} = error}), do: {{:error, kind}, error}

  # Off-contract: an error term that is not a typed %Error{} (e.g. a Structured
  # parse/Jason failure routed in via :query_fun). Cancel rather than retry
  # something we cannot classify.
  def classify({:error, other}), do: {{:cancel, other}, other}
end
