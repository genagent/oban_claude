# examples/agent_retry_live.exs
#
# The agent spike's retry path against REAL claude calls -- this script COSTS
# MONEY (one completed haiku turn; the failed attempt times out before claude
# can answer, so it bills at or near zero).
#
# The worker opts into retries (max_attempts: 3) and delegates its callbacks
# to ObanClaude.Agent.Job, whose routing is terminal-aware. The only
# manipulation is chaos injection at the :query_fun seam: the FIRST call
# forces a 1500ms subprocess timeout onto the real ClaudeWrapper.query/2, so
# attempt 1 dies with a genuine %Error{kind: :timeout} (a retryable {:error,
# :timeout} verdict); later calls run untouched. What that exercises, all
# real:
#
#   * Oban schedules and re-runs the retry (attempt bookkeeping in SQLite)
#   * the agent stays :running across the failed attempt -- job_retrying/2
#     records {:retrying, ...} and re-arms the watchdog
#   * the final attempt succeeds and lands as ONE finished turn
#
#   mix run examples/agent_retry_live.exs

# ---------------------------------------------------------------------------
# 1. Throwaway SQLite repo + Oban, as in the other examples.
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_agent_retry_live.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule RetryLiveRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, RetryLiveRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule RetryLiveMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

# ---------------------------------------------------------------------------
# 2. A retrying agent worker: real claude, chaos on the first call only.
# ---------------------------------------------------------------------------
:persistent_term.put(:retry_live_calls, :counters.new(1, []))

defmodule RetryLiveWorker do
  use ObanClaude.Worker,
    queue: :agents,
    max_attempts: 3,
    query_fun: &__MODULE__.chaos_query/2

  # Snappy demo: retry ~2s after a failure instead of Oban's default ~16s+.
  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 2

  @impl ObanClaude.Worker
  def handle_result(result, job), do: ObanClaude.Agent.Job.handle_result(result, job)

  @impl ObanClaude.Worker
  def handle_error(verdict, payload, job),
    do: ObanClaude.Agent.Job.handle_error(verdict, payload, job)

  # Call 1: the real claude subprocess, crippled by a 1500ms timeout it cannot
  # possibly meet. Call 2+: the same real call, untouched.
  def chaos_query(prompt, opts) do
    counter = :persistent_term.get(:retry_live_calls)
    :counters.add(counter, 1, 1)
    call = :counters.get(counter, 1)

    opts = if call == 1, do: Keyword.put(opts, :timeout, 1_500), else: opts
    IO.puts("  [claude] call #{call}, timeout=#{inspect(opts[:timeout])}")
    ClaudeWrapper.query(prompt, opts)
  end
end

# ---------------------------------------------------------------------------
# 3. Boot + printers for every seam event.
# ---------------------------------------------------------------------------
{:ok, _} = RetryLiveRepo.start_link()
Ecto.Migrator.up(RetryLiveRepo, 1, RetryLiveMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: RetryLiveRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [],
    queues: [agents: 1]
  )

{:ok, _} = ObanClaude.Agent.Supervisor.start_link()

:telemetry.attach(
  "retry-live-transitions",
  [:oban_claude, :agent, :transition],
  fn _e, _m, meta, _c -> IO.puts("  [transition] #{meta.from} -> #{meta.to}") end,
  nil
)

:telemetry.attach(
  "retry-live-stop",
  [:oban_claude, :run, :stop],
  fn _e, meas, meta, _c ->
    IO.puts("  [run ok] $#{Float.round(meas.cost_usd, 4)}: #{inspect(meta.result.result)}")
  end,
  nil
)

:telemetry.attach(
  "retry-live-exception",
  [:oban_claude, :run, :exception],
  fn _e, _m, meta, _c ->
    IO.puts("  [run failed] kind=#{inspect(meta.error.kind)} (attempt #{meta.job.attempt})")
  end,
  nil
)

# ---------------------------------------------------------------------------
# 4. One cast prompt; the retry happens underneath while the agent holds
#    :running the whole way.
# ---------------------------------------------------------------------------
{:ok, _} =
  ObanClaude.Agent.start_agent("retry-demo",
    worker: RetryLiveWorker,
    args: %{"model" => "haiku"},
    job_timeout: 120_000
  )

IO.puts("\ncasting prompt (fire-and-forget)...")
:ok = ObanClaude.Agent.cast_prompt("retry-demo", "Reply with exactly: recovered")
{:ok, :running} = ObanClaude.Agent.await("retry-demo", :running, 10_000)

{:ok, :idle} = ObanClaude.Agent.await("retry-demo", :idle, 180_000)

# ---------------------------------------------------------------------------
# 5. Proof: the agent's ledger and Oban's own attempt bookkeeping.
# ---------------------------------------------------------------------------
{:ok, info} = ObanClaude.Agent.info("retry-demo")
{:ok, history} = ObanClaude.Agent.history("retry-demo")

IO.puts("\nAgent info: turns=#{info.turns} cost=$#{Float.round(info.cost_usd, 4)}")
IO.puts("Agent history (oldest first):")
for entry <- history, do: IO.puts("  #{inspect(entry, printable_limit: 120)}")

import Ecto.Query, only: [from: 2]

[{state, attempt, max_attempts}] =
  RetryLiveRepo.all(from(j in "oban_jobs", select: {j.state, j.attempt, j.max_attempts}))

IO.puts("\nOban's row: state=#{state} attempt=#{attempt}/#{max_attempts}")
