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
  | `%Error{kind: :auth}`                | `{:cancel, ...}` | global config problem; retrying cannot help -- surface |
  | `%Error{kind: :binary_not_found}`    | `{:cancel, ...}` | the environment is broken |
  | `%Error{kind: :budget_exceeded}`     | `{:cancel, ...}` | the same budget will re-hit; a human re-scopes |
  | `%Error{kind: :max_turns_exceeded}`  | `{:cancel, ...}` | the rails stopped it; resuming is a deliberate act, not a blind retry |

  The `:budget_exceeded` and `:max_turns_exceeded` rows are the genuinely
  app-dependent ones -- an app whose worker resumes via a pinned `--session-id`
  may prefer `{:snooze, n}` or `{:error, ...}` there. That is exactly what the
  `:classifier` override is for.
  """

  alias ClaudeWrapper.{Error, Result}

  @snooze_seconds 30

  @doc "Map `ClaudeWrapper.query/2`'s return onto `{oban_return, term}`."
  @spec classify({:ok, Result.t()} | {:error, Error.t()}) ::
          {ObanClaude.oban_return(), Result.t() | Error.t()}
  def classify({:ok, %Result{is_error: false} = result}), do: {:ok, result}

  def classify({:ok, %Result{is_error: true} = result}), do: {{:error, :result_error}, result}

  def classify({:error, %Error{kind: :timeout} = error}), do: {{:snooze, @snooze_seconds}, error}

  def classify({:error, %Error{kind: kind} = error})
      when kind in [:auth, :binary_not_found, :budget_exceeded, :max_turns_exceeded],
      do: {{:cancel, kind}, error}

  def classify({:error, %Error{kind: kind} = error}), do: {{:error, kind}, error}
end
