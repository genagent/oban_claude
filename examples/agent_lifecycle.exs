# examples/agent_lifecycle.exs
#
# The agent lifecycle spike end to end, offline: one long-lived
# ObanClaude.Agent (:gen_statem) whose turns run as REAL Oban jobs on the
# throwaway SQLite (Lite) engine, with only the claude call stubbed via the
# worker's :query_fun seam.
#
# Walks the whole state matrix: a plain turn, a request_permission turn
# approved by the "human" (note the :approved_args elevation on that turn
# only), an ask_user turn answered by the "human", and the emergency pause.
# Transitions print live off the telemetry event.
#
#   mix run examples/agent_lifecycle.exs

# ---------------------------------------------------------------------------
# 1. Throwaway SQLite repo + Oban schema, as in examples/playground.exs.
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_agent_lifecycle.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule LifecycleRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, LifecycleRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule LifecycleMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

# ---------------------------------------------------------------------------
# 2. The turn worker: the REAL ObanClaude.Worker pipeline with a scripted
#    claude. Routing back to the agent delegates to ObanClaude.Agent.Job, the
#    canonical router -- this module only swaps the claude entrypoint.
# ---------------------------------------------------------------------------
defmodule LifecycleWorker do
  use ObanClaude.Worker,
    queue: :agents,
    max_attempts: 1,
    query_fun: &__MODULE__.fake_query/2

  import ObanClaude.Testing, only: [result: 1, structured_result: 2]

  @impl ObanClaude.Worker
  def handle_result(result, job), do: ObanClaude.Agent.Job.handle_result(result, job)

  @impl ObanClaude.Worker
  def handle_error(verdict, payload, job),
    do: ObanClaude.Agent.Job.handle_error(verdict, payload, job)

  def fake_query(prompt, query_opts) do
    # permission_mode only appears on the approve continuation (:approved_args)
    IO.puts(
      "  [claude] resume=#{inspect(query_opts[:resume])} " <>
        "permission_mode=#{inspect(query_opts[:permission_mode])} prompt=#{inspect(prompt)}"
    )

    {:ok, scenario(prompt)}
  end

  # The prompt doubles as the scenario selector. Every result carries the same
  # session id, so the resume handle visibly threads turn to turn.
  defp scenario("plan a refactor" <> _rest) do
    structured_result(
      %{"directive" => "request_permission", "action" => "rewrite lib/core.ex"},
      session_id: "sess-demo"
    )
  end

  defp scenario("Approved:" <> _rest),
    do: result(result: "refactor complete", session_id: "sess-demo")

  defp scenario("pick a deploy env" <> _rest) do
    structured_result(
      %{"directive" => "ask_user", "question" => "which environment?"},
      session_id: "sess-demo"
    )
  end

  defp scenario("staging" <> _rest),
    do: result(result: "deployed to staging", session_id: "sess-demo")

  defp scenario(other),
    do: result(result: "done: #{other}", session_id: "sess-demo")
end

# ---------------------------------------------------------------------------
# 3. Boot: repo, migration, Oban (agents queue), the agent supervision tree.
# ---------------------------------------------------------------------------
{:ok, _} = LifecycleRepo.start_link()
Ecto.Migrator.up(LifecycleRepo, 1, LifecycleMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: LifecycleRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [],
    queues: [agents: 1]
  )

{:ok, _} = ObanClaude.Agent.Supervisor.start_link()

:telemetry.attach(
  "agent-lifecycle-demo",
  [:oban_claude, :agent, :transition],
  fn _event, _measurements, meta, _config ->
    IO.puts("  [transition] #{meta.agent_id}: #{meta.from} -> #{meta.to}")
  end,
  nil
)

{:ok, _pid} =
  ObanClaude.Agent.start_agent("demo",
    worker: LifecycleWorker,
    approved_args: %{"permission_mode" => "accept_edits"}
  )

# ---------------------------------------------------------------------------
# 4. Walk the matrix. `await/3` blocks on the registry until the state lands,
#    returning the gated payload atomically with the state.
# ---------------------------------------------------------------------------
IO.puts("\n== turn 1: a plain prompt (idle -> running -> idle) ==")
:processing = ObanClaude.Agent.submit_prompt("demo", "summarize the repo")
{:ok, :idle} = ObanClaude.Agent.await("demo", :idle, 10_000)

IO.puts("\n== turn 2: request_permission (running -> awaiting_permission) ==")
:processing = ObanClaude.Agent.submit_prompt("demo", "plan a refactor")

{:ok, {:awaiting_permission, %{id: action_id, description: description}}} =
  ObanClaude.Agent.await("demo", :awaiting_permission, 10_000)

IO.puts("  [human] pending action #{action_id}: #{description} -- approving")
:processing = ObanClaude.Agent.approve_action("demo", action_id)
{:ok, :idle} = ObanClaude.Agent.await("demo", :idle, 10_000)

IO.puts("\n== turn 3: ask_user (running -> waiting_for_user) ==")
:processing = ObanClaude.Agent.submit_prompt("demo", "pick a deploy env")

{:ok, {:waiting_for_user, question}} =
  ObanClaude.Agent.await("demo", :waiting_for_user, 10_000)

IO.puts("  [human] agent asks: #{question} -- answering \"staging\"")
:processing = ObanClaude.Agent.submit_prompt("demo", "staging")
{:ok, :idle} = ObanClaude.Agent.await("demo", :idle, 10_000)

IO.puts("\n== emergency pause and resume ==")
:ok = ObanClaude.Agent.emergency_pause("demo")
{:ok, :paused} = ObanClaude.Agent.await("demo", :paused, 10_000)
{:error, :paused} = ObanClaude.Agent.submit_prompt("demo", "anything")
IO.puts("  [human] prompt while paused refused; resuming")
:resumed = ObanClaude.Agent.resume_agent("demo")

{:ok, info} = ObanClaude.Agent.info("demo")
{:ok, history} = ObanClaude.Agent.history("demo")

IO.puts("\nInfo: #{inspect(Map.take(info, [:state, :turns, :cost_usd, :session_id]))}")
IO.puts("History (oldest first):")
for entry <- history, do: IO.puts("  #{inspect(entry)}")
