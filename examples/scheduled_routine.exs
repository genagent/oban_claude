# examples/scheduled_routine.exs
#
# The "scheduled routine" shape: a worker that holds ALL of its config, an empty
# job, and `Oban.Plugins.Cron` firing it on a schedule. This is the "everything
# in the worker, an empty job -> a routine" case from the `ObanClaude.Worker`
# docs, and it is the scheduled half of the oban_claude platform story: Oban owns
# the schedule, oban_claude owns running claude, and the job carries nothing.
#
# Offline and deterministic, like examples/playground.exs: a throwaway SQLite
# (Lite) Oban, with the claude call faked via the worker's `:query_fun` seam.
#
#   mix run examples/scheduled_routine.exs
#
# It runs in two acts:
#   1. an immediate empty-job insert, to show the routine runs instantly;
#   2. a bounded wait for the real Cron tick, to prove the schedule fires itself.

import Ecto.Query, only: [from: 2]

# ---------------------------------------------------------------------------
# 1. A throwaway SQLite-backed Ecto repo (fresh file every run).
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_scheduled.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule RoutineRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, RoutineRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule RoutineMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

# ---------------------------------------------------------------------------
# 2. The routine worker. The prompt lives in worker-level `:args`, so the job
#    itself is empty -- the schedule just says "run me," the worker knows what
#    "me" means. claude is stubbed via `:query_fun`.
# ---------------------------------------------------------------------------
defmodule RoutineWorker do
  use ObanClaude.Worker,
    queue: :routine,
    args: %{"prompt" => "Summarize what changed in the repo since yesterday."},
    query_fun: &__MODULE__.fake_query/2

  require Logger
  alias ClaudeWrapper.Result

  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    Logger.info("[routine] ran: #{inspect(result.result)}")
    :ok
  end

  # The empty job merged under the worker's `:args`, so the fixed prompt arrives
  # here even though the job carried nothing.
  def fake_query(prompt, _opts) do
    IO.puts("  [claude] prompt=#{inspect(prompt)}")
    {:ok, %Result{result: "daily summary produced", is_error: false, cost_usd: 0.0}}
  end
end

# ---------------------------------------------------------------------------
# 3. Boot: repo, migrate, then Oban WITH the Cron plugin.
#
#    `{"* * * * *", RoutineWorker}` inserts an empty RoutineWorker job at the top
#    of every minute. `Oban.Peers.Isolated` makes this single node the always-on
#    leader, which Cron requires to insert (the default peer would sit idle here).
# ---------------------------------------------------------------------------
{:ok, _} = RoutineRepo.start_link()
Ecto.Migrator.up(RoutineRepo, 1, RoutineMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: RoutineRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", RoutineWorker}]}],
    queues: [routine: 1]
  )

count = fn ->
  RoutineRepo.one(from(j in "oban_jobs", where: j.worker == "RoutineWorker", select: count(j.id)))
end

wait_for = fn target, timeout_s, label ->
  deadline = System.monotonic_time(:second) + timeout_s

  Enum.reduce_while(Stream.cycle([:tick]), nil, fn _, _ ->
    if count.() >= target do
      {:halt, :ok}
    else
      if System.monotonic_time(:second) >= deadline do
        {:halt, :timeout}
      else
        IO.write("\r  #{label} (#{max(deadline - System.monotonic_time(:second), 0)}s left) ")
        Process.sleep(500)
        {:cont, nil}
      end
    end
  end)
end

# ---------------------------------------------------------------------------
# Act 1: prove the routine runs instantly from an empty job.
# ---------------------------------------------------------------------------
IO.puts("\nAct 1: insert an empty job -- the worker supplies the prompt.\n")
{:ok, _} = %{} |> RoutineWorker.new() |> Oban.insert()
:ok = wait_for.(1, 10, "waiting for the manual job")
IO.puts("\n  -> empty job in, full agent run out.\n")

# ---------------------------------------------------------------------------
# Act 2: prove Cron fires the same job on its own at the next minute boundary.
# ---------------------------------------------------------------------------
IO.puts("Act 2: now wait for Cron to insert and run one on the schedule.")
IO.puts("       (fires at the top of the minute, so up to ~60s)\n")

case wait_for.(2, 70, "waiting for the Cron tick") do
  :ok ->
    IO.puts("\n  -> Cron inserted and ran a RoutineWorker job with no help.\n")

  :timeout ->
    IO.puts("\n  (timed out waiting for the minute boundary; the wiring is still correct)\n")
end

IO.puts("""
Total RoutineWorker jobs run: #{count.()}

In production you would drop the same crontab entry into your app's Oban config:

    config :my_app, Oban,
      plugins: [{Oban.Plugins.Cron, crontab: [{"0 6 * * *", MyApp.RoutineWorker}]}]

The worker holds the prompt and every claude arg; the schedule just says "run."
""")
