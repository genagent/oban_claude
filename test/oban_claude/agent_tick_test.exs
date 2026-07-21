defmodule ObanClaude.Agent.TickTest do
  # Tick's policy matrix, driven by calling perform/1 directly with fake jobs.
  # Most tests use enqueue_fun agents (no DB); the auto-start test boots a real
  # SQLite Oban (default name, no queues) so the started agent's default
  # enqueue path lands a real row in oban_jobs -- inserted but never executed,
  # so no claude runs.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ObanClaude.Testing

  alias ObanClaude.Agent
  alias ObanClaude.Agent.Tick

  defmodule Repo do
    use Ecto.Repo, otp_app: :oban_claude, adapter: Ecto.Adapters.SQLite3
  end

  defmodule Migration do
    use Ecto.Migration
    def up, do: Oban.Migrations.up()
    def down, do: Oban.Migrations.down()
  end

  setup_all do
    db = Path.join(System.tmp_dir!(), "oban_claude_agent_tick_test.db")
    for suffix <- ["", "-shm", "-wal"], do: File.rm(db <> suffix)

    Application.put_env(:oban_claude, Repo,
      database: db,
      pool_size: 1,
      busy_timeout: 5_000,
      log: false
    )

    start_supervised!(Repo)
    Ecto.Migrator.up(Repo, 1, Migration, log: false)

    # Default name (Oban), which is where an auto-started agent's default
    # config inserts. queues: [] -- jobs are inserted, never executed.
    start_supervised!(
      {Oban,
       repo: Repo,
       engine: Oban.Engines.Lite,
       peer: Oban.Peers.Isolated,
       notifier: Oban.Notifiers.PG,
       plugins: [],
       queues: []}
    )

    :ok
  end

  setup do
    start_supervised!(ObanClaude.Agent.Supervisor)
    :ok
  end

  defp settle(id) do
    {:ok, _} = Agent.history(id)
    :ok
  end

  defp start_agent!(opts \\ []) do
    id = "tick-agent-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    enqueue_fun = fn args, meta ->
      send(test_pid, {:enqueued, args, meta})
      {:ok, :queued}
    end

    {:ok, _pid} = Agent.start_agent(id, Keyword.merge([enqueue_fun: enqueue_fun], opts))
    id
  end

  defp tick(args), do: Tick.perform(%Oban.Job{args: args})

  test "delivers to an :idle agent" do
    id = start_agent!()
    assert :ok = tick(%{"agent_id" => id, "prompt" => "beat"})
    assert {:ok, :running} = Agent.await(id, :running, 1_000)
    assert_receive {:enqueued, %{"prompt" => "beat"}, %{"agent_id" => ^id}}
  end

  test "skips a busy agent by default" do
    id = start_agent!()
    :processing = Agent.submit_prompt(id, "long turn")
    assert_receive {:enqueued, _args, _meta}

    assert {:cancel, :agent_busy} = tick(%{"agent_id" => id, "prompt" => "beat"})
    refute_receive {:enqueued, %{"prompt" => "beat"}, _meta}, 50
  end

  test "if_busy queue delivers behind the in-flight turn" do
    id = start_agent!()
    :processing = Agent.submit_prompt(id, "long turn")
    assert_receive {:enqueued, _args, _meta}

    assert :ok = tick(%{"agent_id" => id, "prompt" => "beat", "if_busy" => "queue"})
    refute_receive {:enqueued, %{"prompt" => "beat"}, _meta}, 50

    :ok = Agent.job_finished(id, {:ok, result("done")})
    assert_receive {:enqueued, %{"prompt" => "beat"}, _meta}
  end

  test "a queued tick never answers a pending question" do
    id = start_agent!()
    :processing = Agent.submit_prompt(id, "deploy")
    assert_receive {:enqueued, _args, _meta}

    turn = structured_result(%{"directive" => "ask_user", "question" => "env?"}, session_id: "s")
    :ok = Agent.job_finished(id, {:ok, turn})
    {:ok, {:waiting_for_user, "env?"}} = Agent.await(id, :waiting_for_user, 1_000)

    assert :ok = tick(%{"agent_id" => id, "prompt" => "beat", "if_busy" => "queue"})
    settle(id)
    assert {:ok, {:waiting_for_user, "env?"}} = Agent.status(id)
    refute_receive {:enqueued, %{"prompt" => "beat"}, _meta}, 50

    :processing = Agent.submit_prompt(id, "staging")
    assert_receive {:enqueued, %{"prompt" => "staging"}, _meta}
    :ok = Agent.job_finished(id, {:ok, result("deployed")})
    assert_receive {:enqueued, %{"prompt" => "beat"}, _meta}
  end

  test "a paused agent never receives a tick, in either if_busy mode" do
    id = start_agent!()
    :ok = Agent.emergency_pause(id)
    {:ok, :paused} = Agent.await(id, :paused, 1_000)

    assert {:cancel, :agent_paused} = tick(%{"agent_id" => id, "prompt" => "beat"})

    assert {:cancel, :agent_paused} =
             tick(%{"agent_id" => id, "prompt" => "beat", "if_busy" => "queue"})

    refute_receive {:enqueued, _args, _meta}, 50
  end

  test "an offline agent skips by default" do
    assert {:cancel, :agent_not_running} = tick(%{"agent_id" => "ghost", "prompt" => "beat"})
  end

  test "if_offline start boots the agent and delivers through the real queue" do
    id = "tick-start-" <> Integer.to_string(System.unique_integer([:positive]))

    args = %{
      "agent_id" => id,
      "prompt" => "boot beat",
      "if_offline" => "start",
      "start" => %{"args" => %{"model" => "haiku"}, "job_timeout" => 90_000}
    }

    assert :ok = tick(args)
    assert {:ok, :running} = Agent.await(id, :running, 1_000)

    # the auto-started agent used its default config: ObanClaude.Agent.Job
    # into the default Oban instance, tagged with the agent id
    row =
      Repo.one(
        from(j in "oban_jobs",
          where: j.worker == "ObanClaude.Agent.Job",
          select: %{args: j.args, meta: j.meta}
        )
      )

    assert %{"prompt" => "boot beat", "model" => "haiku"} = Jason.decode!(row.args)
    assert %{"agent_id" => ^id} = Jason.decode!(row.meta)
  end

  test "session fresh delivers the beat without a resume handle" do
    id = start_agent!()
    :processing = Agent.submit_prompt(id, "one")
    :ok = Agent.job_finished(id, {:ok, result(result: "done", session_id: "sess-1")})
    {:ok, :idle} = Agent.await(id, :idle, 1_000)

    assert :ok = tick(%{"agent_id" => id, "prompt" => "beat", "session" => "fresh"})
    assert_receive {:enqueued, %{"prompt" => "beat"} = args, _meta}
    refute Map.has_key?(args, "resume")
  end

  test "invalid tick args cancel with a reason" do
    assert {:cancel, {:invalid_tick, reason}} = tick(%{"prompt" => "beat"})
    assert reason =~ "agent_id"

    assert {:cancel, {:invalid_tick, _}} = tick(%{"agent_id" => "a", "prompt" => ""})

    assert {:cancel, {:invalid_tick, reason}} =
             tick(%{"agent_id" => "a", "prompt" => "beat", "if_busy" => "wait"})

    assert reason =~ "if_busy"
  end
end
