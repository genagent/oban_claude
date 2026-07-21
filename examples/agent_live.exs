# examples/agent_live.exs
#
# The agent lifecycle spike against REAL claude calls -- this script COSTS
# MONEY (a few turns on sonnet, typically well under $1 total, each turn
# capped by max_budget_usd).
#
# Everything is real: the SQLite-backed Oban queue, the default
# ObanClaude.Agent.Job worker, claude itself. The agent works in a throwaway
# workspace under the tmp dir, so the approved edit lands there, not in a
# repo. Demonstrates the full loop:
#
#   1. a plain turn (directive none)
#   2. a permission-gated edit: request_permission -> approve, where
#      :approved_args elevates that one turn to accept_edits so the approved
#      edit actually lands on disk
#   3. an ask_user turn answered by the operator
#
#   mix run examples/agent_live.exs

# ---------------------------------------------------------------------------
# 1. Throwaway workspace the agent runs in, with a file to work on.
# ---------------------------------------------------------------------------
workspace = Path.join(System.tmp_dir!(), "oban_claude_agent_live_ws")
File.rm_rf!(workspace)
File.mkdir_p!(workspace)

notes = Path.join(workspace, "notes.md")

File.write!(notes, """
# Project notes

- The queue procesing logic lives in the worker module.
- Results are classified onto Oban verdicts.
- Session ids allow resuming a conversation.
""")

IO.puts("Workspace: #{workspace}")
IO.puts("notes.md before:\n" <> File.read!(notes))

# ---------------------------------------------------------------------------
# 2. Throwaway SQLite repo + Oban + the agent tree, as in the other examples.
# ---------------------------------------------------------------------------
db_path = Path.join(System.tmp_dir!(), "oban_claude_agent_live.db")
for suffix <- ["", "-shm", "-wal"], do: File.rm(db_path <> suffix)

defmodule AgentLiveRepo do
  use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
end

Application.put_env(:oban_claude, AgentLiveRepo,
  database: db_path,
  pool_size: 1,
  busy_timeout: 5_000,
  log: false
)

defmodule AgentLiveMigration do
  use Ecto.Migration
  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end

{:ok, _} = AgentLiveRepo.start_link()
Ecto.Migrator.up(AgentLiveRepo, 1, AgentLiveMigration, log: false)

{:ok, _} =
  Oban.start_link(
    repo: AgentLiveRepo,
    engine: Oban.Engines.Lite,
    notifier: Oban.Notifiers.PG,
    peer: Oban.Peers.Isolated,
    plugins: [],
    queues: [agents: 1]
  )

{:ok, _} = ObanClaude.Agent.Supervisor.start_link()

:telemetry.attach(
  "agent-live-transitions",
  [:oban_claude, :agent, :transition],
  fn _event, _measurements, meta, _config ->
    IO.puts("  [transition] #{meta.agent_id}: #{meta.from} -> #{meta.to}")
  end,
  nil
)

:telemetry.attach(
  "agent-live-runs",
  [:oban_claude, :run, :stop],
  fn _event, meas, meta, _config ->
    out = ObanClaude.structured(meta.result) || %{}
    IO.puts("  [turn] $#{Float.round(meas.cost_usd, 4)} directive=#{out["directive"]}")
    IO.puts("  [turn] #{out["summary"] || String.slice(meta.result.result || "", 0, 300)}")
  end,
  nil
)

# ---------------------------------------------------------------------------
# 3. The agent: real claude, directive schema, per-approval edit elevation.
# ---------------------------------------------------------------------------
schema =
  Jason.encode!(%{
    type: "object",
    additionalProperties: false,
    required: ["directive", "summary"],
    properties: %{
      directive: %{type: "string", enum: ["none", "ask_user", "request_permission"]},
      summary: %{type: "string"},
      question: %{type: "string", description: "set when directive=ask_user"},
      action: %{type: "string", description: "set when directive=request_permission"}
    }
  })

args =
  ObanClaude.Args.defaults(
    model: "sonnet",
    working_dir: workspace,
    max_turns: 10,
    max_budget_usd: 1.0,
    timeout: 240_000,
    json_schema: schema,
    append_system_prompt: """
    You are one turn of a long-running, operator-supervised agent. Always
    return the structured output. Set directive=ask_user with a question when
    you need information only the operator has. Set directive=request_permission
    with a one-line action description before any file edit or other
    consequential step, and do NOT take the step this turn. Otherwise
    directive=none. Put your actual answer in summary.
    """
  )

{:ok, _pid} =
  ObanClaude.Agent.start_agent("live",
    args: args,
    approved_args: %{"permission_mode" => "accept_edits"},
    job_timeout: 300_000
  )

settled = [:idle, :awaiting_permission, :waiting_for_user]
turn_timeout = 300_000

# ---------------------------------------------------------------------------
# 4. Drive the loop.
# ---------------------------------------------------------------------------
IO.puts("\n== turn 1: plain prompt ==")
:processing = ObanClaude.Agent.submit_prompt("live", "Summarize notes.md in one sentence.")
{:ok, s1} = ObanClaude.Agent.await("live", settled, turn_timeout)
IO.puts("  settled at: #{inspect(s1)}")

IO.puts("\n== turn 2: permission-gated edit ==")

:processing =
  ObanClaude.Agent.submit_prompt(
    "live",
    "notes.md contains a spelling mistake. Fix it. Request permission before editing."
  )

case ObanClaude.Agent.await("live", settled, turn_timeout) do
  {:ok, {:awaiting_permission, %{id: action_id, description: description}}} ->
    IO.puts("  [operator] approving: #{description}")
    :processing = ObanClaude.Agent.approve_action("live", action_id)
    {:ok, s2} = ObanClaude.Agent.await("live", settled, turn_timeout)
    IO.puts("  settled at: #{inspect(s2)}")

  {:ok, other} ->
    IO.puts("  expected :awaiting_permission, settled at: #{inspect(other)}")
end

IO.puts("\nnotes.md after:\n" <> File.read!(notes))

IO.puts("\n== turn 3: ask_user ==")

:processing =
  ObanClaude.Agent.submit_prompt(
    "live",
    "I am considering splitting notes.md by topic. Ask me one clarifying question, then advise."
  )

case ObanClaude.Agent.await("live", settled, turn_timeout) do
  {:ok, {:waiting_for_user, question}} ->
    IO.puts("  [operator] agent asks: #{question}")
    IO.puts("  [operator] answering...")

    :processing =
      ObanClaude.Agent.submit_prompt(
        "live",
        "There will only ever be a handful of notes; simplicity matters most."
      )

    {:ok, s3} = ObanClaude.Agent.await("live", settled, turn_timeout)
    IO.puts("  settled at: #{inspect(s3)}")

  {:ok, other} ->
    IO.puts("  expected :waiting_for_user, settled at: #{inspect(other)}")
end

# ---------------------------------------------------------------------------
# 5. The bill and the log.
# ---------------------------------------------------------------------------
{:ok, info} = ObanClaude.Agent.info("live")

IO.puts("""

Info:
  state:      #{inspect(info.state)}
  session_id: #{info.session_id}
  turns:      #{info.turns}
  cost_usd:   $#{Float.round(info.cost_usd, 4)}
""")

{:ok, history} = ObanClaude.Agent.history("live")
IO.puts("History (oldest first):")

for entry <- history do
  IO.puts("  " <> (entry |> inspect() |> String.slice(0, 160)))
end
