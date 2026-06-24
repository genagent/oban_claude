# dev/playground.exs
#
# An offline, deterministic look at oban_claude running on a *real* Oban queue.
#
# Boots an Oban instance on the SQLite (Lite) engine -- no Postgres, no Docker,
# just a throwaway file in the tmp dir -- and runs the REAL `use
# ObanClaude.Worker`. The only thing faked is the claude call itself, injected
# via the worker's `:query_fun` seam. So this exercises the genuine path:
# perform/1 -> ObanClaude.run/2 -> build/1 -> classify -> handle_result/2.
#
#   mix run dev/playground.exs

import Ecto.Query, only: [from: 2]

# ---------------------------------------------------------------------------
# 1. A throwaway SQLite-backed Ecto repo (fresh file every run).
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_playground.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule PlaygroundRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, PlaygroundRepo,
  database: db_path,
  # SQLite has a single writer, so a one-connection pool is the natural fit
  # (and avoids a connect-time "database is locked" race). busy_timeout makes
  # any contender wait rather than error.
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

# ---------------------------------------------------------------------------
# 2. Oban's schema migration, run programmatically against the fresh DB.
#    (`Oban.Migrations.up/0` auto-detects the SQLite adapter.)
# ---------------------------------------------------------------------------
defmodule PlaygroundMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

# ---------------------------------------------------------------------------
# 3. The REAL worker, with claude stubbed via :query_fun.
# ---------------------------------------------------------------------------
defmodule PlaygroundWorker do
  use ObanClaude.Worker, queue: :claude, max_attempts: 3, query_fun: &__MODULE__.fake_query/2

  alias ClaudeWrapper.{Error, Result}

  # Tiny backoff so retries are watchable in seconds (Oban's default is ~15s+).
  @impl Oban.Worker
  def backoff(%Oban.Job{}), do: 1

  # The worker's one override point: branch on a typed structured outcome.
  @impl ObanClaude.Worker
  def handle_result(result, _job) do
    case ObanClaude.outcome(result) do
      "blocked" -> {:cancel, :blocked}
      _ -> :ok
    end
  end

  # Stubbed claude entrypoint. The prompt doubles as the scenario selector, and
  # query_opts shows the args build/1 produced -- note `permission_mode` arrives
  # here as the atom `:bypass_permissions` even though it was enqueued as a JSON
  # string. Returns the exact shapes ClaudeWrapper.query/2 returns.
  def fake_query(prompt, query_opts) do
    IO.puts("  [claude] prompt=#{inspect(prompt)} opts=#{inspect(query_opts)}")
    stub_outcome(prompt)
  end

  defp stub_outcome("ok"),
    do: {:ok, %Result{result: "all good", is_error: false, cost_usd: 0.0123}}

  defp stub_outcome("blocked"),
    do:
      {:ok,
       %Result{
         result: "",
         is_error: false,
         extra: %{"structured_output" => %{"outcome" => "blocked"}}
       }}

  defp stub_outcome("timeout"), do: {:error, %Error{kind: :timeout}}
  defp stub_outcome("auth"), do: {:error, %Error{kind: :auth, reason: :invalid_api_key}}
  defp stub_outcome("command_failed"), do: {:error, %Error{kind: :command_failed, exit_code: 1}}
end

# ---------------------------------------------------------------------------
# 4. Boot: start the repo, migrate, start Oban on the Lite engine.
# ---------------------------------------------------------------------------
{:ok, _} = PlaygroundRepo.start_link()
Ecto.Migrator.up(PlaygroundRepo, 1, PlaygroundMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: PlaygroundRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    # Single-node script: always-leader peer so the Stager promotes
    # `retryable`/`scheduled` jobs to `available`. NOTE: `plugins: []`, not
    # `plugins: false` -- `false` is the testing switch that forces a
    # non-leader peer and turns staging off, so retries would never fire.
    peer: Oban.Peers.Isolated,
    plugins: [],
    queues: [claude: 1]
  )

# ---------------------------------------------------------------------------
# 5. Enqueue one job per claude outcome, then watch the queue resolve them.
#    The "ok" job also carries pass-through opts to show JSON -> query mapping
#    (and the permission_mode string -> atom coercion).
# ---------------------------------------------------------------------------
jobs = [
  {%{"prompt" => "ok", "model" => "sonnet", "permission_mode" => "bypass_permissions"},
   "clean result -> :ok", []},
  {%{"prompt" => "blocked"}, "structured 'blocked' -> handle_result cancels", []},
  {%{"prompt" => "timeout"}, "transient -> snooze 30s", []},
  {%{"prompt" => "auth"}, "config problem -> cancel (terminal)", []},
  {%{"prompt" => "command_failed"}, "infra blip -> retry then discard", [max_attempts: 2]}
]

IO.puts("\nEnqueuing #{length(jobs)} jobs on the :claude queue...\n")

id_label =
  for {args, label, opts} <- jobs, into: %{} do
    {:ok, job} = args |> PlaygroundWorker.new(opts) |> Oban.insert()
    {job.id, "#{args["prompt"]} (#{label})"}
  end

ids = Map.keys(id_label)
terminal = ~w(completed cancelled discarded scheduled)

snapshot = fn ->
  PlaygroundRepo.all(
    from(j in "oban_jobs",
      where: j.id in ^ids,
      select: {j.id, j.state, j.attempt, j.max_attempts},
      order_by: j.id
    )
  )
end

print = fn rows ->
  IO.puts("  " <> String.duplicate("-", 74))

  for {id, state, attempt, max} <- rows do
    IO.puts(
      "  ##{id}  #{String.pad_trailing(state, 10)} attempt #{attempt}/#{max}  #{id_label[id]}"
    )
  end
end

# Watch the queue tick: one compact line per poll so the transitions are
# visible (e.g. command_failed walks retryable -> available -> discarded).
# Halt once every job is terminal or parked by the snooze.
IO.puts("Watching state transitions:\n")

Enum.reduce_while(1..25, nil, fn i, _ ->
  Process.sleep(400)
  rows = snapshot.()

  line =
    rows
    |> Enum.map(fn {id, state, _, _} -> "##{id}:#{state}" end)
    |> Enum.join("  ")

  IO.puts("  t=#{Float.round(i * 0.4, 1)}s  #{line}")

  if Enum.all?(rows, fn {_, state, _, _} -> state in terminal end),
    do: {:halt, rows},
    else: {:cont, rows}
end)

IO.puts("\nFinal states:")
print.(snapshot.())

IO.puts("""

  completed  succeeded (:ok)
  cancelled  {:cancel, _}: terminal, no retry  (auth, and blocked via handle_result)
  discarded  ran out of attempts after {:error, _} retries  (command_failed)
  scheduled  {:snooze, 30}: parked ~30s out; Oban bumped max_attempts so the
             snooze did not cost a retry  (timeout)
""")
