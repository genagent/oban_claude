# dev/propose_dispose.exs
#
# Shows the shape the autonomous issue/PR worker is built around: "propose /
# dispose". A claude worker (queue :claude) runs with a JSON schema, gets back
# a typed outcome, and *disposes* by enqueuing a follow-on effector job on a
# second queue (:sink) -- the stand-in for the future, separate `oban_github`
# sink. oban_claude stays GitHub-agnostic; the sink is just another Oban worker.
#
# Two Oban patterns on display: multiple queues, and a worker enqueuing a
# follow-on job.
#
# The claude call is stubbed via :query_fun (offline, deterministic). In real
# use you'd either pass a `"json_schema"` arg or route :query_fun through
# `ClaudeWrapper.Structured.run/3`; the {:ok, parsed, result} it returns adapts
# to this seam as `{:ok, _parsed, result} -> {:ok, result}`.
#
#   mix run dev/propose_dispose.exs

import Ecto.Query, only: [from: 2]

# --- Boot (same throwaway-SQLite setup as dev/playground.exs) ---------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_propose_dispose.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule PdRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, PdRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule PdMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

# --- The sink: a plain Oban worker standing in for oban_github --------------
defmodule SinkJob do
  use Oban.Worker, queue: :sink, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => action, "issue" => issue}}) do
    IO.puts("  [sink] issue ##{issue}: would #{action}  (stand-in for oban_github)")
    :ok
  end
end

# --- The claude worker: propose an outcome, dispose by enqueuing a sink job --
defmodule ClaudeJob do
  use ObanClaude.Worker, queue: :claude, max_attempts: 3, query_fun: &__MODULE__.fake_query/2

  alias ClaudeWrapper.Result

  # The dispose step. Branch on the typed outcome; enqueue the matching sink
  # action, or cancel when the agent reported it is blocked.
  @impl ObanClaude.Worker
  def handle_result(result, %Oban.Job{args: %{"issue" => issue}}) do
    case ObanClaude.structured(result) do
      %{"outcome" => "done"} ->
        enqueue_sink("open a PR", issue)
        :ok

      %{"outcome" => "needs_review"} ->
        enqueue_sink("comment for human review", issue)
        :ok

      %{"outcome" => "blocked"} ->
        {:cancel, :blocked}

      _ ->
        :ok
    end
  end

  defp enqueue_sink(action, issue) do
    {:ok, _job} = %{"action" => action, "issue" => issue} |> SinkJob.new() |> Oban.insert()
  end

  # Stubbed claude entrypoint: the prompt doubles as the scenario selector and
  # becomes the schema-validated `outcome`. (Real use: a JSON schema makes
  # claude return this object; the stub just fabricates it.)
  def fake_query(prompt, _opts) do
    {:ok,
     %Result{result: "", is_error: false, extra: %{"structured_output" => %{"outcome" => prompt}}}}
  end
end

# --- Start everything -------------------------------------------------------
{:ok, _} = PdRepo.start_link()
Ecto.Migrator.up(PdRepo, 1, PdMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: PdRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [],
    queues: [claude: 2, sink: 5]
  )

# --- Enqueue claude jobs for three issues with different outcomes -----------
proposals = [
  {101, "done"},
  {102, "needs_review"},
  {103, "blocked"}
]

IO.puts("\nEnqueuing #{length(proposals)} claude jobs (one per issue)...\n")

for {issue, outcome} <- proposals do
  {:ok, _} = %{"prompt" => outcome, "issue" => issue} |> ClaudeJob.new() |> Oban.insert()
end

# --- Watch both queues settle (claude jobs spawn sink jobs as they finish) --
terminal = ~w(completed cancelled discarded)

snapshot = fn ->
  PdRepo.all(
    from(j in "oban_jobs", select: {j.id, j.worker, j.state, j.queue}, order_by: j.id)
  )
end

IO.puts("Watching both queues:\n")

Enum.reduce_while(1..25, nil, fn i, _ ->
  Process.sleep(400)
  rows = snapshot.()

  line =
    rows
    |> Enum.map(fn {id, worker, state, _q} -> "##{id}:#{worker}=#{state}" end)
    |> Enum.join("  ")

  IO.puts("  t=#{Float.round(i * 0.4, 1)}s  #{line}")

  # Settled when every job is terminal and at least one sink job has appeared
  # (so we don't stop before the claude jobs have had a chance to dispose).
  all_terminal? = Enum.all?(rows, fn {_, _, state, _} -> state in terminal end)
  has_sink? = Enum.any?(rows, fn {_, w, _, _} -> w =~ "SinkJob" end)

  if all_terminal? and has_sink?, do: {:halt, rows}, else: {:cont, rows}
end)

IO.puts("\nFinal states:")
IO.puts("  " <> String.duplicate("-", 64))

for {id, worker, state, queue} <- snapshot.() do
  IO.puts("  ##{id}  #{String.pad_trailing(queue, 7)} #{String.pad_trailing(worker, 9)} #{state}")
end

IO.puts("""

  Issue 101 (done)         -> claude completed -> sink enqueued: open a PR
  Issue 102 (needs_review) -> claude completed -> sink enqueued: comment
  Issue 103 (blocked)      -> claude cancelled -> no sink (nothing to dispose)
""")
