# examples/agent_routine.exs
#
# A Routines-shaped agent: `Oban.Plugins.Cron` fires `ObanClaude.Agent.Tick`
# on a schedule, and the tick delivers a PROMPT to a long-lived agent through
# the facade -- Cron keeps its worker-layer contract, the state machine keeps
# its turn-enqueueing invariant, and the Tick worker is the adapter between
# them.
#
# Offline and deterministic like the other CI-safe examples (claude stubbed
# via :query_fun), but NOT run in CI: proving the schedule fires itself means
# waiting up to ~70s for a real minute-boundary Cron tick.
#
#   mix run examples/agent_routine.exs
#
# Two acts:
#   1. an immediate hand-inserted tick, to show delivery and the skip policy;
#   2. a bounded wait for the real Cron tick to prompt the agent on its own.

import Ecto.Query, only: [from: 2]

# ---------------------------------------------------------------------------
# 1. Throwaway SQLite repo + the stubbed agent turn worker.
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_agent_routine.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule AgentRoutineRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, AgentRoutineRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule AgentRoutineMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

defmodule RoutineAgentWorker do
  use ObanClaude.Worker,
    queue: :agents,
    max_attempts: 1,
    query_fun: &__MODULE__.fake_query/2

  import ObanClaude.Testing, only: [result: 1]

  @impl ObanClaude.Worker
  def handle_result(result, job), do: ObanClaude.Agent.Job.handle_result(result, job)

  @impl ObanClaude.Worker
  def handle_error(verdict, payload, job),
    do: ObanClaude.Agent.Job.handle_error(verdict, payload, job)

  def fake_query(prompt, query_opts) do
    IO.puts("  [claude] resume=#{inspect(query_opts[:resume])} prompt=#{inspect(prompt)}")
    # a visible busy window, so Act 1's second tick observes :running
    Process.sleep(2_000)
    {:ok, result(result: "routine ran: #{prompt}", session_id: "sess-routine")}
  end
end

# ---------------------------------------------------------------------------
# 2. Boot: Oban with the Cron plugin scheduling a Tick every minute, then the
#    agent tree and the agent itself. The tick uses session "fresh" (Routines
#    style: each beat starts a clean claude session) and default skip
#    policies.
# ---------------------------------------------------------------------------
tick_args = %{
  "agent_id" => "routine",
  "prompt" => "Do the scheduled sweep.",
  "session" => "fresh"
}

{:ok, _} = AgentRoutineRepo.start_link()
Ecto.Migrator.up(AgentRoutineRepo, 1, AgentRoutineMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: AgentRoutineRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [
      {Oban.Plugins.Cron, crontab: [{"* * * * *", ObanClaude.Agent.Tick, args: tick_args}]}
    ],
    # ticks on their own queue, so a beat can observe (and skip) a busy agent
    # instead of serializing behind the agent's own turn job
    queues: [agents: 1, ticks: 1]
  )

{:ok, _} = ObanClaude.Agent.Supervisor.start_link()

:telemetry.attach(
  "agent-routine-transitions",
  [:oban_claude, :agent, :transition],
  fn _e, _m, meta, _c -> IO.puts("  [transition] #{meta.from} -> #{meta.to}") end,
  nil
)

{:ok, _} = ObanClaude.Agent.start_agent("routine", worker: RoutineAgentWorker)

# ---------------------------------------------------------------------------
# 3. Act 1: a hand-inserted tick delivers now; a second tick while the agent
#    is busy is skipped (the default if_busy policy), visible as a cancelled
#    row.
# ---------------------------------------------------------------------------
IO.puts("\nAct 1: hand-insert a tick; insert a second while the turn runs (skipped).")

{:ok, _} = Oban.insert(ObanClaude.Agent.Tick.new(tick_args, queue: :ticks))
{:ok, :running} = ObanClaude.Agent.await("routine", :running, 15_000)

# the agent is mid-turn: this beat hits the default if_busy skip policy
{:ok, skipped} = Oban.insert(ObanClaude.Agent.Tick.new(tick_args, queue: :ticks))

{:ok, :idle} = ObanClaude.Agent.await("routine", :idle, 15_000)
{:ok, history} = ObanClaude.Agent.history("routine")
IO.puts("  agent history so far: #{inspect(history, printable_limit: 200)}")
IO.puts("  skipped beat is job ##{skipped.id} (see final table)")

# ---------------------------------------------------------------------------
# 4. Act 2: wait for the real Cron tick at the next minute boundary.
# ---------------------------------------------------------------------------
IO.puts("\nAct 2: waiting up to ~70s for Cron to fire the next tick itself...")

count_ticks = fn ->
  AgentRoutineRepo.one(
    from(j in "oban_jobs", where: j.worker == "ObanClaude.Agent.Tick", select: count(j.id))
  )
end

baseline = count_ticks.()

Enum.reduce_while(1..150, nil, fn _i, _acc ->
  if count_ticks.() > baseline do
    {:halt, :ok}
  else
    Process.sleep(500)
    {:cont, nil}
  end
end) || raise "Cron never fired within the wait budget"

{:ok, :idle} = ObanClaude.Agent.await("routine", :idle, 15_000)

{:ok, info} = ObanClaude.Agent.info("routine")
IO.puts("\nAfter the Cron beat: turns=#{info.turns}")

rows =
  AgentRoutineRepo.all(
    from(j in "oban_jobs",
      where: j.worker == "ObanClaude.Agent.Tick",
      select: {j.id, j.state, j.cancelled_at},
      order_by: [asc: j.id]
    )
  )

IO.puts("Tick rows (completed = delivered, cancelled = skipped beat):")
for {id, state, _} <- rows, do: IO.puts("  ##{id}  #{state}")
