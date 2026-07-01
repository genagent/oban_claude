# examples/event_driven.exs
#
# The "event-driven" shape: any process inserts a job to trigger an agent, and
# Oban's uniqueness debounces duplicate events. This is the mirror of
# examples/scheduled_routine.exs -- there a schedule inserts the job, here an
# event does. oban_claude is trigger-agnostic: it never knows or cares what
# inserted the job.
#
# Offline and deterministic: a throwaway SQLite (Lite) Oban, claude faked via the
# worker's `:query_fun` seam.
#
#   mix run examples/event_driven.exs

import Ecto.Query, only: [from: 2]

# ---------------------------------------------------------------------------
# 1. A throwaway SQLite-backed Ecto repo (fresh file every run).
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_event_driven.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule EventRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, EventRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule EventMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

# ---------------------------------------------------------------------------
# 2. The worker. `unique:` tells Oban to collapse jobs with identical args
#    inserted within the window into one -- so a flurry of the same event does
#    the work once. claude is stubbed via `:query_fun`.
# ---------------------------------------------------------------------------
defmodule EventWorker do
  use ObanClaude.Worker,
    queue: :events,
    unique: [period: 60],
    query_fun: &__MODULE__.fake_query/2

  require Logger
  alias ClaudeWrapper.Result

  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    Logger.info("[event] handled: #{inspect(result.result)}")
    :ok
  end

  def fake_query(prompt, _opts) do
    IO.puts("  [claude] prompt=#{inspect(prompt)}")
    {:ok, %Result{result: "reacted to: #{prompt}", is_error: false, cost_usd: 0.0}}
  end
end

# ---------------------------------------------------------------------------
# 3. Boot: repo, migrate, Oban on the Lite engine.
# ---------------------------------------------------------------------------
{:ok, _} = EventRepo.start_link()
Ecto.Migrator.up(EventRepo, 1, EventMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: EventRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [],
    queues: [events: 1]
  )

# An "event source": something happened, so insert a job. The only signal we
# read back is `job.conflict?` -- true when uniqueness folded this insert into an
# already-pending job rather than creating a new one.
fire = fn label, args ->
  {:ok, job} = args |> ObanClaude.Args.new() |> EventWorker.new() |> Oban.insert()
  tag = if job.conflict?, do: "deduped (no new job)", else: "enqueued ##{job.id}"
  IO.puts("  event #{label} -> #{tag}")
  job
end

# ---------------------------------------------------------------------------
# 4. Fire a burst of the SAME event, then one distinct event.
# ---------------------------------------------------------------------------
IO.puts("\nSame event fires three times in a row:\n")
for _ <- 1..3, do: fire.("\"issue-42 opened\"", prompt: "Triage issue #42")

IO.puts("\nA different event fires once:\n")
fire.("\"issue-99 opened\"", prompt: "Triage issue #99")

# ---------------------------------------------------------------------------
# 5. Watch the queue drain: two distinct runs, not four.
# ---------------------------------------------------------------------------
count = fn state ->
  EventRepo.one(
    from(j in "oban_jobs", where: j.worker == "EventWorker" and j.state == ^state, select: count(j.id))
  )
end

IO.puts("\nWatching the queue drain:\n")

Enum.reduce_while(1..20, nil, fn _, _ ->
  Process.sleep(300)
  done = count.("completed")
  IO.puts("  completed: #{done}")
  if done >= 2 and count.("available") == 0 and count.("executing") == 0, do: {:halt, done}, else: {:cont, done}
end)

IO.puts("""

Four inserts, two runs: uniqueness debounced the three identical "issue-42"
events into one. In an event-driven app the source (a webhook, a poller, a
PubSub handler) just inserts; Oban's `unique` keeps duplicate signals from doing
duplicate (paid) claude work.
""")
