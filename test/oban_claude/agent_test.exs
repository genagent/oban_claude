defmodule ObanClaude.AgentTest do
  # The spec's validation suite plus the lifecycle matrix, driven with an
  # injected :enqueue_fun (no Oban, no DB, no claude): the enqueue lands in the
  # test mailbox and the test plays the worker's role by casting
  # `job_finished/2` back at the machine.
  use ExUnit.Case, async: true

  import ObanClaude.Testing

  alias ObanClaude.Agent

  setup do
    start_supervised!(ObanClaude.Agent.Supervisor)
    :ok
  end

  # job_finished/2 and emergency_pause/1 are casts; a call (history) queued
  # behind one guarantees it has been processed before the registry is read.
  defp settle(id) do
    {:ok, _} = Agent.history(id)
    :ok
  end

  defp start_agent!(opts \\ []) do
    id = "agent-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    enqueue_fun = fn args, meta ->
      send(test_pid, {:enqueued, args, meta})
      {:ok, :queued}
    end

    {:ok, _pid} = Agent.start_agent(id, Keyword.merge([enqueue_fun: enqueue_fun], opts))
    id
  end

  describe "registry status reads" do
    test "a started agent reads :idle without messaging the process" do
      id = start_agent!()
      assert {:ok, :idle} = Agent.get_status(id)
    end

    test "an unknown agent reads :offline" do
      assert {:ok, :offline} = Agent.get_status("never-started")
    end

    test "start_agent is idempotent for an already-running id" do
      id = start_agent!()
      [{pid, _}] = Registry.lookup(ObanClaude.Agent.Registry, id)
      assert {:ok, ^pid} = Agent.start_agent(id)
    end

    test "a stopped agent reads :offline again" do
      id = start_agent!()
      assert :ok = Agent.stop_agent(id)
      assert {:ok, :offline} = Agent.get_status(id)
    end
  end

  describe ":idle -> :running" do
    test "submit_prompt enqueues a turn tagged with the agent id and replies :processing" do
      id = start_agent!()
      assert :processing = Agent.submit_prompt(id, "run deep code audit step")
      assert {:ok, :running} = Agent.get_status(id)
      assert_receive {:enqueued, %{"prompt" => "run deep code audit step"}, %{"agent_id" => ^id}}
    end

    test "config default args ride under the prompt" do
      id = start_agent!(args: %{"model" => "sonnet"})
      :processing = Agent.submit_prompt(id, "go")
      assert_receive {:enqueued, %{"prompt" => "go", "model" => "sonnet"}, _meta}
    end

    test "an enqueue failure stays :idle and surfaces the reason" do
      id = "agent-fail-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, _} = Agent.start_agent(id, enqueue_fun: fn _args, _meta -> {:error, :db_down} end)

      assert {:error, {:enqueue_failed, :db_down}} = Agent.submit_prompt(id, "go")
      assert {:ok, :idle} = Agent.get_status(id)
    end
  end

  describe ":running" do
    test "a prompt during :running is postponed until the in-flight turn finishes" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "first")
      assert_receive {:enqueued, %{"prompt" => "first"}, _meta}

      caller = Task.async(fn -> Agent.submit_prompt(id, "second") end)
      refute_receive {:enqueued, %{"prompt" => "second"}, _meta}, 100

      :ok = Agent.job_finished(id, {:ok, result("done")})
      assert :processing = Task.await(caller)
      assert_receive {:enqueued, %{"prompt" => "second"}, _meta}
      assert {:ok, :running} = Agent.get_status(id)
    end

    test "a plain result returns the agent to :idle" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      :ok = Agent.job_finished(id, {:ok, result("all done")})
      settle(id)

      assert {:ok, :idle} = Agent.get_status(id)
      assert {:ok, history} = Agent.history(id)
      assert {:result, "all done"} in history
    end

    test "the watchdog returns a hung turn to :idle" do
      id = start_agent!(job_timeout: 50)
      :processing = Agent.submit_prompt(id, "hang")
      assert {:ok, :running} = Agent.get_status(id)

      Process.sleep(120)
      assert {:ok, :idle} = Agent.get_status(id)
      assert {:ok, history} = Agent.history(id)
      assert :watchdog_timeout in history
    end

    test "a failed turn returns to :idle and still captures a rail-stop session id" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "expensive")

      err = error(:max_budget_exceeded, reason: %{session_id: "sess-9", cost_usd: 1.5})
      :ok = Agent.job_finished(id, {:error, {:cancel, :max_budget_exceeded}, err})
      settle(id)
      assert {:ok, :idle} = Agent.get_status(id)

      :processing = Agent.submit_prompt(id, "pick it back up")
      assert_receive {:enqueued, %{"prompt" => "pick it back up", "resume" => "sess-9"}, _meta}
    end
  end

  describe "session threading" do
    test "the session id from a result resumes on the next turn" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "first")
      assert_receive {:enqueued, first_args, _meta}
      refute Map.has_key?(first_args, "resume")

      :ok = Agent.job_finished(id, {:ok, result(result: "done", session_id: "sess-42")})
      settle(id)

      :processing = Agent.submit_prompt(id, "second")
      assert_receive {:enqueued, %{"prompt" => "second", "resume" => "sess-42"}, _meta}
    end
  end

  describe ":waiting_for_user" do
    test "an ask_user directive parks the agent; the next prompt answers and resumes" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "deploy the service")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(%{"directive" => "ask_user", "question" => "which environment?"},
          session_id: "sess-1"
        )

      :ok = Agent.job_finished(id, {:ok, turn})
      settle(id)
      assert {:ok, :waiting_for_user} = Agent.get_status(id)
      assert {:ok, %{question: "which environment?"}} = Agent.pending(id)

      assert :processing = Agent.submit_prompt(id, "staging")
      assert_receive {:enqueued, %{"prompt" => "staging", "resume" => "sess-1"}, _meta}
      assert {:ok, :running} = Agent.get_status(id)
    end
  end

  describe ":awaiting_permission" do
    defp block_on_permission!(id) do
      :processing = Agent.submit_prompt(id, "plan a refactor")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(
          %{"directive" => "request_permission", "action" => "rewrite lib/core.ex"},
          session_id: "sess-2"
        )

      :ok = Agent.job_finished(id, {:ok, turn})
      settle(id)
      assert {:ok, :awaiting_permission} = Agent.get_status(id)

      {:ok, %{action: %{id: action_id, description: "rewrite lib/core.ex"}}} = Agent.pending(id)
      action_id
    end

    test "approve_action resumes the session with the approved action" do
      id = start_agent!()
      action_id = block_on_permission!(id)

      assert :processing = Agent.approve_action(id, action_id)
      assert_receive {:enqueued, %{"prompt" => prompt, "resume" => "sess-2"}, _meta}
      assert prompt =~ "rewrite lib/core.ex"
      assert {:ok, :running} = Agent.get_status(id)
    end

    test "reject_action records the denial and returns to :idle without enqueuing" do
      id = start_agent!()
      action_id = block_on_permission!(id)

      assert :rejected = Agent.reject_action(id, action_id, "too risky")
      assert {:ok, :idle} = Agent.get_status(id)
      refute_receive {:enqueued, _args, _meta}, 50

      assert {:ok, history} = Agent.history(id)
      assert {:denied, ^action_id, "too risky"} = Enum.find(history, &match?({:denied, _, _}, &1))
      assert {:ok, %{action: nil}} = Agent.pending(id)
    end

    test "a mismatched action id is refused and keeps the agent blocked" do
      id = start_agent!()
      _action_id = block_on_permission!(id)

      assert {:error, :unknown_action} = Agent.approve_action(id, "act_bogus")
      assert {:error, :unknown_action} = Agent.reject_action(id, "act_bogus")
      assert {:ok, :awaiting_permission} = Agent.get_status(id)
    end
  end

  describe ":paused" do
    test "emergency_pause locks the agent from any state; resume_agent releases it" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "work")

      :ok = Agent.emergency_pause(id)
      settle(id)
      assert {:ok, :paused} = Agent.get_status(id)
      assert {:error, :paused} = Agent.submit_prompt(id, "more work")

      # a turn that was in flight when the pause hit is absorbed, not acted on
      :ok = Agent.job_finished(id, {:ok, result(result: "late", session_id: "sess-late")})
      settle(id)
      assert {:ok, :paused} = Agent.get_status(id)

      assert :resumed = Agent.resume_agent(id)
      assert {:ok, :idle} = Agent.get_status(id)

      # ...but its session id was kept, so the conversation continues
      :processing = Agent.submit_prompt(id, "carry on")
      assert_receive {:enqueued, %{"prompt" => "carry on", "resume" => "sess-late"}, _meta}
    end
  end

  describe "invalid actions" do
    test "an action invalid for the current state names the state in the error" do
      id = start_agent!()
      assert {:error, :invalid_action, :idle} = Agent.approve_action(id, "act_1")
      assert {:error, :invalid_action, :idle} = Agent.resume_agent(id)
    end

    test "commands against a non-running agent do not message anything" do
      assert {:error, :agent_not_running} = Agent.submit_prompt("ghost", "hi")
      assert {:error, :agent_not_running} = Agent.emergency_pause("ghost")
      assert {:error, :agent_not_running} = Agent.stop_agent("ghost")
    end
  end

  describe "transition telemetry" do
    test "every state change emits [:oban_claude, :agent, :transition]" do
      handler_id = "agent-transitions-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:oban_claude, :agent, :transition],
        fn _event, _measurements, meta, _config -> send(test_pid, {:transition, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      assert_receive {:transition, %{agent_id: ^id, from: :idle, to: :running}}

      :ok = Agent.job_finished(id, {:ok, result("done")})
      assert_receive {:transition, %{agent_id: ^id, from: :running, to: :idle}}
    end
  end

  describe "ObanClaude.Agent.Job routing" do
    test "handle_result and handle_error report back to the agent named in job meta" do
      id = start_agent!()
      job = %Oban.Job{meta: %{"agent_id" => id}}

      :processing = Agent.submit_prompt(id, "turn one")
      assert :ok = ObanClaude.Agent.Job.handle_result(result("done"), job)
      settle(id)
      assert {:ok, :idle} = Agent.get_status(id)

      :processing = Agent.submit_prompt(id, "turn two")
      verdict = {:cancel, :auth}
      assert ^verdict = ObanClaude.Agent.Job.handle_error(verdict, error(:auth), job)
      settle(id)
      assert {:ok, :idle} = Agent.get_status(id)
    end

    test "a job without an agent_id runs normally and reports to no one" do
      assert :ok = ObanClaude.Agent.Job.handle_result(result("done"), %Oban.Job{meta: %{}})

      assert {:error, :x} =
               ObanClaude.Agent.Job.handle_error({:error, :x}, :payload, %Oban.Job{meta: %{}})
    end
  end
end
