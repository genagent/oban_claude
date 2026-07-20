# examples/agent_routine_live.exs
#
# A real cron routine against REAL claude calls -- this script COSTS MONEY
# (two haiku turns, a few cents) and takes ~2-3 minutes: it waits for TWO real
# minute-boundary Cron ticks.
#
# Nothing is stubbed and nothing is pre-started. The crontab entry is the
# whole routine spec: `if_offline: "start"` means the FIRST beat boots the
# agent (model, watchdog) from the tick's own args, and `session: "fresh"`
# gives every beat a clean claude session, Routines-style. Oban owns the
# schedule, the Tick adapter delivers the prompt through the facade, the
# state machine owns the turn.
#
#   mix run examples/agent_routine_live.exs

import Ecto.Query, only: [from: 2]

# ---------------------------------------------------------------------------
# 1. Throwaway SQLite repo.
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_agent_routine_live.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule RoutineLiveRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, RoutineLiveRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule RoutineLiveMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

# ---------------------------------------------------------------------------
# 2. Boot: the crontab entry IS the routine. No agent is started here.
# ---------------------------------------------------------------------------
tick_args = %{
  "agent_id" => "routine-live",
  "prompt" => "Reply with one short haiku about job queues. Nothing else.",
  "session" => "fresh",
  "if_offline" => "start",
  "start" => %{"args" => %{"model" => "haiku"}, "job_timeout" => 120_000}
}

{:ok, _} = RoutineLiveRepo.start_link()
Ecto.Migrator.up(RoutineLiveRepo, 1, RoutineLiveMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: RoutineLiveRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [
      {Oban.Plugins.Cron,
       crontab: [{"* * * * *", ObanClaude.Agent.Tick, args: tick_args, queue: :ticks}]}
    ],
    # ticks on their own queue so a beat observes the agent, not its queue slot
    queues: [agents: 1, ticks: 1]
  )

{:ok, _} = ObanClaude.Agent.Supervisor.start_link()

:telemetry.attach(
  "routine-live-transitions",
  [:oban_claude, :agent, :transition],
  fn _e, _m, meta, _c ->
    IO.puts("  [transition] #{meta.agent_id}: #{meta.from} -> #{meta.to}")
  end,
  nil
)

:telemetry.attach(
  "routine-live-runs",
  [:oban_claude, :run, :stop],
  fn _e, meas, meta, _c ->
    IO.puts("  [turn] $#{Float.round(meas.cost_usd, 4)} session=#{meta.result.session_id}")
    IO.puts("  [turn] #{String.trim(meta.result.result || "")}")
  end,
  nil
)

IO.puts("No agent started. Waiting for Cron to fire the first beat (auto-start)...")
IO.puts("Status now: #{inspect(ObanClaude.Agent.status("routine-live"))}\n")

# ---------------------------------------------------------------------------
# 3. Wait for two beats' worth of finished turns (~2-3 minutes).
# ---------------------------------------------------------------------------
wait_for_turns = fn target, budget_ms ->
  deadline = System.monotonic_time(:millisecond) + budget_ms

  Enum.reduce_while(Stream.cycle([:tick]), nil, fn _t, _acc ->
    with {:ok, :idle} <- ObanClaude.Agent.status("routine-live"),
         {:ok, %{turns: turns}} when turns >= target <- ObanClaude.Agent.info("routine-live") do
      {:halt, :ok}
    else
      _not_yet ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, {:error, :timeout}}
        else
          Process.sleep(1_000)
          {:cont, nil}
        end
    end
  end)
end

:ok = wait_for_turns.(1, 150_000) || raise "first beat never landed"
IO.puts("\nbeat 1 landed (agent was auto-started by the tick). Waiting for beat 2...\n")
:ok = wait_for_turns.(2, 150_000) || raise "second beat never landed"

# ---------------------------------------------------------------------------
# 4. The ledger: two independent sessions, two beats, real spend.
# ---------------------------------------------------------------------------
{:ok, info} = ObanClaude.Agent.info("routine-live")
{:ok, history} = ObanClaude.Agent.history("routine-live")

IO.puts("\nAgent: turns=#{info.turns} cost=$#{Float.round(info.cost_usd, 4)}")
IO.puts("History (oldest first):")
for entry <- history, do: IO.puts("  #{inspect(entry, printable_limit: 140)}")

rows =
  RoutineLiveRepo.all(
    from(j in "oban_jobs", select: {j.id, j.worker, j.state}, order_by: [asc: j.id])
  )

IO.puts("\nJob rows (Tick beats + the agent turns they delivered):")

for {id, worker, state} <- rows,
    do: IO.puts("  ##{id}  #{String.pad_trailing(state, 10)} #{worker}")
