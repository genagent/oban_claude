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
      assert {:ok, :idle} = Agent.status(id)
    end

    test "an unknown agent reads :offline" do
      assert {:ok, :offline} = Agent.status("never-started")
    end

    test "start_agent is idempotent for an already-running id" do
      id = start_agent!()
      [{pid, _}] = Registry.lookup(ObanClaude.Agent.Registry, id)
      assert {:ok, ^pid} = Agent.start_agent(id)
    end

    test "a stopped agent reads :offline again" do
      id = start_agent!()
      assert :ok = Agent.stop_agent(id)
      # Registry cleanup after a process death is asynchronous (monitor-based),
      # so :offline is eventually-consistent -- await it rather than assert it.
      assert {:ok, :offline} = Agent.await(id, :offline, 1_000)
    end

    test "list/0 inventories running agents with their status payloads" do
      a = start_agent!()
      b = start_agent!()
      :processing = Agent.submit_prompt(b, "turn")

      listed = Map.new(Agent.list())
      assert listed[a] == :idle
      assert listed[b] == :running
    end

    test "atom keys in :args fail fast at start" do
      assert {:error, %ArgumentError{message: message}} =
               Agent.start_agent("bad-args", args: %{model: "sonnet"})

      assert message =~ "keys must be strings"
    end
  end

  describe ":idle -> :running" do
    test "submit_prompt enqueues a turn tagged with the agent id and replies :processing" do
      id = start_agent!()
      assert :processing = Agent.submit_prompt(id, "run deep code audit step")
      assert {:ok, :running} = Agent.status(id)
      assert_receive {:enqueued, %{"prompt" => "run deep code audit step"}, %{"agent_id" => ^id}}
    end

    test "config default args ride under the prompt; approved_args do not" do
      id =
        start_agent!(
          args: %{"model" => "sonnet"},
          approved_args: %{"permission_mode" => "accept_edits"}
        )

      :processing = Agent.submit_prompt(id, "go")
      assert_receive {:enqueued, %{"prompt" => "go", "model" => "sonnet"} = args, _meta}
      refute Map.has_key?(args, "permission_mode")
    end

    test "an enqueue failure stays :idle and surfaces the reason" do
      id = "agent-fail-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, _} = Agent.start_agent(id, enqueue_fun: fn _args, _meta -> {:error, :db_down} end)

      assert {:error, {:enqueue_failed, :db_down}} = Agent.submit_prompt(id, "go")
      assert {:ok, :idle} = Agent.status(id)
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
      assert {:ok, :running} = Agent.status(id)
    end

    test "a plain result returns the agent to :idle" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      :ok = Agent.job_finished(id, {:ok, result("all done")})

      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      assert {:ok, history} = Agent.history(id)
      assert {:result, "all done"} in history
    end

    test "the watchdog returns a hung turn to :idle" do
      id = start_agent!(job_timeout: 50)
      :processing = Agent.submit_prompt(id, "hang")
      assert {:ok, :running} = Agent.status(id)

      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      assert {:ok, history} = Agent.history(id)
      assert :watchdog_timeout in history
    end

    test "a failed turn returns to :idle and still captures a rail-stop session id" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "expensive")

      err = error(:max_budget_exceeded, reason: %{session_id: "sess-9", cost_usd: 1.5})
      :ok = Agent.job_finished(id, {:error, {:cancel, :max_budget_exceeded}, err})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "pick it back up")
      assert_receive {:enqueued, %{"prompt" => "pick it back up", "resume" => "sess-9"}, _meta}
    end
  end

  describe "cast_prompt/2" do
    test "fires a turn without blocking and without a reply" do
      id = start_agent!()
      assert :ok = Agent.cast_prompt(id, "async go")
      assert {:ok, :running} = Agent.await(id, :running, 1_000)
      assert_receive {:enqueued, %{"prompt" => "async go"}, %{"agent_id" => ^id}}
    end

    test "queues behind an in-flight turn like the call form" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "first")
      assert_receive {:enqueued, %{"prompt" => "first"}, _meta}

      assert :ok = Agent.cast_prompt(id, "second")
      refute_receive {:enqueued, %{"prompt" => "second"}, _meta}, 100

      :ok = Agent.job_finished(id, {:ok, result("done")})
      assert_receive {:enqueued, %{"prompt" => "second"}, _meta}
      assert {:ok, :running} = Agent.status(id)
    end

    test "answers the pending question in :waiting_for_user" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "deploy")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(%{"directive" => "ask_user", "question" => "env?"}, session_id: "s")

      :ok = Agent.job_finished(id, {:ok, turn})
      {:ok, {:waiting_for_user, "env?"}} = Agent.await(id, :waiting_for_user, 1_000)

      assert :ok = Agent.cast_prompt(id, "staging")
      assert_receive {:enqueued, %{"prompt" => "staging", "resume" => "s"}, _meta}
    end

    test "is dropped and recorded in :paused" do
      id = start_agent!()
      :ok = Agent.emergency_pause(id)
      {:ok, :paused} = Agent.await(id, :paused, 1_000)

      assert :ok = Agent.cast_prompt(id, "into the void")
      settle(id)
      assert {:ok, :paused} = Agent.status(id)

      :resumed = Agent.resume_agent(id)
      refute_receive {:enqueued, _args, _meta}, 50
      assert {:ok, history} = Agent.history(id)
      assert {:dropped_prompt, "into the void"} in history
    end
  end

  describe "prompt options" do
    test "session: :fresh starts a new claude session for that turn" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "one")
      :ok = Agent.job_finished(id, {:ok, result(result: "done", session_id: "sess-1")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "two", session: :fresh)
      assert_receive {:enqueued, %{"prompt" => "two"} = args, _meta}
      refute Map.has_key?(args, "resume")

      # the fresh turn's session becomes the new resume handle
      :ok = Agent.job_finished(id, {:ok, result(result: "ok", session_id: "sess-2")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)
      :processing = Agent.submit_prompt(id, "three")
      assert_receive {:enqueued, %{"prompt" => "three", "resume" => "sess-2"}, _meta}
    end

    test "a tick-origin prompt queues behind a pending question instead of answering it" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "deploy")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(%{"directive" => "ask_user", "question" => "env?"}, session_id: "s")

      :ok = Agent.job_finished(id, {:ok, turn})
      {:ok, {:waiting_for_user, "env?"}} = Agent.await(id, :waiting_for_user, 1_000)

      :ok = Agent.cast_prompt(id, "scheduled beat", origin: :tick)
      settle(id)
      assert {:ok, {:waiting_for_user, "env?"}} = Agent.status(id)
      refute_receive {:enqueued, %{"prompt" => "scheduled beat"}, _meta}, 50

      # the operator's answer still owns the question; the beat runs after
      :processing = Agent.submit_prompt(id, "staging")
      assert_receive {:enqueued, %{"prompt" => "staging"}, _meta}
      :ok = Agent.job_finished(id, {:ok, result("deployed")})
      assert_receive {:enqueued, %{"prompt" => "scheduled beat"}, _meta}
    end

    test "unknown option values raise" do
      assert_raise ArgumentError, fn -> Agent.submit_prompt("x", "p", session: :bogus) end
      assert_raise ArgumentError, fn -> Agent.cast_prompt("x", "p", origin: :cron) end
    end
  end

  describe "retry-aware routing" do
    test "a retryable attempt keeps the machine :running and records the retry" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")

      job = %Oban.Job{attempt: 1, max_attempts: 3, meta: %{"agent_id" => id}}
      verdict = {:error, :timeout}
      assert ^verdict = ObanClaude.Agent.Job.handle_error(verdict, error(:timeout), job)
      settle(id)

      assert {:ok, :running} = Agent.status(id)
      assert {:ok, history} = Agent.history(id)

      assert {:retrying, %{attempt: 1, max_attempts: 3, verdict: ^verdict}} =
               Enum.find(history, &match?({:retrying, _}, &1))
    end

    test "a snooze is never terminal" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")

      job = %Oban.Job{attempt: 1, max_attempts: 1, meta: %{"agent_id" => id}}
      ObanClaude.Agent.Job.handle_error({:snooze, 30}, result("parked"), job)
      settle(id)

      assert {:ok, :running} = Agent.status(id)
    end

    test "the final attempt's failure is terminal" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")

      job = %Oban.Job{attempt: 3, max_attempts: 3, meta: %{"agent_id" => id}}
      ObanClaude.Agent.Job.handle_error({:error, :timeout}, error(:timeout), job)

      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      assert {:ok, history} = Agent.history(id)
      assert {:job_error, {:error, :timeout}} in history
    end

    test "a cancel verdict is terminal regardless of attempts remaining" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")

      job = %Oban.Job{attempt: 1, max_attempts: 3, meta: %{"agent_id" => id}}
      ObanClaude.Agent.Job.handle_error({:cancel, :auth}, error(:auth), job)

      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "a retry re-arms the watchdog" do
      id = start_agent!(job_timeout: 300)
      :processing = Agent.submit_prompt(id, "turn")

      Process.sleep(200)
      :ok = Agent.job_retrying(id, %{attempt: 1, max_attempts: 3, verdict: {:error, :timeout}})

      # past the original 300ms deadline but inside the re-armed one
      Process.sleep(200)
      assert {:ok, :running} = Agent.status(id)

      # the re-armed watchdog still fires if the retry never reports back
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      assert {:ok, history} = Agent.history(id)
      assert :watchdog_timeout in history
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

      # one atomic read: the state and the question it is gated on
      assert {:ok, {:waiting_for_user, "which environment?"}} =
               Agent.await(id, :waiting_for_user, 1_000)

      assert :processing = Agent.submit_prompt(id, "staging")
      assert_receive {:enqueued, %{"prompt" => "staging", "resume" => "sess-1"}, _meta}
      assert {:ok, :running} = Agent.status(id)
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

      assert {:ok, {:awaiting_permission, %{id: action_id, description: "rewrite lib/core.ex"}}} =
               Agent.await(id, :awaiting_permission, 1_000)

      action_id
    end

    test "approve_action resumes the session with the approved action under approved_args" do
      id = start_agent!(approved_args: %{"permission_mode" => "accept_edits"})
      action_id = block_on_permission!(id)

      assert :processing = Agent.approve_action(id, action_id)

      assert_receive {:enqueued,
                      %{
                        "prompt" => prompt,
                        "resume" => "sess-2",
                        "permission_mode" => "accept_edits"
                      }, _meta}

      assert prompt =~ "rewrite lib/core.ex"
      assert {:ok, :running} = Agent.status(id)

      # the elevation is per-approval: the next normal turn runs locked down
      :ok = Agent.job_finished(id, {:ok, result("edited")})
      :processing = Agent.submit_prompt(id, "normal turn")
      assert_receive {:enqueued, %{"prompt" => "normal turn"} = args, _meta}
      refute Map.has_key?(args, "permission_mode")
    end

    test "reject_action records the denial and returns to :idle without enqueuing" do
      id = start_agent!()
      action_id = block_on_permission!(id)

      assert :rejected = Agent.reject_action(id, action_id, "too risky")
      assert {:ok, :idle} = Agent.status(id)
      refute_receive {:enqueued, _args, _meta}, 50

      assert {:ok, history} = Agent.history(id)
      assert {:denied, ^action_id, "too risky"} = Enum.find(history, &match?({:denied, _, _}, &1))
    end

    test "a mismatched action id is refused and keeps the agent blocked" do
      id = start_agent!()
      _action_id = block_on_permission!(id)

      assert {:error, :unknown_action} = Agent.approve_action(id, "act_bogus")
      assert {:error, :unknown_action} = Agent.reject_action(id, "act_bogus")
      assert {:ok, {:awaiting_permission, _action}} = Agent.status(id)
    end

    test "a prompt during :awaiting_permission queues behind the gate" do
      id = start_agent!()
      action_id = block_on_permission!(id)

      caller = Task.async(fn -> Agent.submit_prompt(id, "next thing") end)
      refute_receive {:enqueued, %{"prompt" => "next thing"}, _meta}, 100

      # clearing the gate releases the queued prompt
      assert :rejected = Agent.reject_action(id, action_id, "not now")
      assert :processing = Task.await(caller)
      assert_receive {:enqueued, %{"prompt" => "next thing"}, _meta}
      assert {:ok, :running} = Agent.status(id)
    end
  end

  describe ":paused" do
    test "emergency_pause locks the agent from any state; resume_agent releases it" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "work")

      :ok = Agent.emergency_pause(id)
      assert {:ok, :paused} = Agent.await(id, :paused, 1_000)
      assert {:error, :paused} = Agent.submit_prompt(id, "more work")

      # a turn that was in flight when the pause hit is absorbed, not acted on
      :ok = Agent.job_finished(id, {:ok, result(result: "late", session_id: "sess-late")})
      settle(id)
      assert {:ok, :paused} = Agent.status(id)

      assert :resumed = Agent.resume_agent(id)
      assert {:ok, :idle} = Agent.status(id)

      # ...but its session id was kept, so the conversation continues
      :processing = Agent.submit_prompt(id, "carry on")
      assert_receive {:enqueued, %{"prompt" => "carry on", "resume" => "sess-late"}, _meta}
    end

    test "pausing a gated agent drops the pending action (lockdown drops scopes)" do
      id = start_agent!()
      _action_id = block_on_permission!(id)

      :ok = Agent.emergency_pause(id)
      assert {:ok, :paused} = Agent.await(id, :paused, 1_000)

      :resumed = Agent.resume_agent(id)
      assert {:ok, %{pending_action: nil, pending_question: nil}} = Agent.info(id)
    end
  end

  describe "await/3" do
    test "returns the gated status with its payload once the state lands" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")

      task = Task.async(fn -> Agent.await(id, [:idle, :awaiting_permission], 1_000) end)
      turn = structured_result(%{"directive" => "request_permission", "action" => "do it"}, [])
      :ok = Agent.job_finished(id, {:ok, turn})

      assert {:ok, {:awaiting_permission, %{id: _, description: "do it"}}} = Task.await(task)
    end

    test "times out when the state never arrives" do
      id = start_agent!()
      assert {:error, :timeout} = Agent.await(id, :paused, 100)
    end
  end

  describe "info/1 and history/1" do
    test "info accumulates turns and spend across successes and failures" do
      id = start_agent!()

      :processing = Agent.submit_prompt(id, "one")
      :ok = Agent.job_finished(id, {:ok, result(result: "done", cost_usd: 0.25, session_id: "s")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "two")
      err = error(:max_budget_exceeded, reason: %{session_id: "s", cost_usd: 1.0})
      :ok = Agent.job_finished(id, {:error, {:cancel, :max_budget_exceeded}, err})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      assert {:ok, %{state: :idle, turns: 2, cost_usd: cost, session_id: "s"}} = Agent.info(id)
      assert_in_delta cost, 1.25, 0.0001
    end

    test "history records the decoded structured output for --json-schema turns" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")

      structured = %{"directive" => "none", "summary" => "did the thing"}
      :ok = Agent.job_finished(id, {:ok, structured_result(structured, [])})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      assert {:ok, history} = Agent.history(id)
      assert {:result, ^structured} = Enum.find(history, &match?({:result, _}, &1))
    end
  end

  describe "history cap" do
    test "history retains only the newest max_history entries" do
      id = start_agent!(max_history: 3)

      for n <- 1..3 do
        :processing = Agent.submit_prompt(id, "turn #{n}")
        :ok = Agent.job_finished(id, {:ok, result("done #{n}")})
        {:ok, :idle} = Agent.await(id, :idle, 1_000)
      end

      # 3 turns = 6 entries recorded; only the newest 3 survive
      assert {:ok, history} = Agent.history(id)

      assert history == [
               {:result, "done 2"},
               {:prompt, "turn 3"},
               {:result, "done 3"}
             ]
    end
  end

  describe "approval continuity (re-gate on incomplete approved work)" do
    defp approve_gated!(id) do
      :processing = Agent.submit_prompt(id, "plan")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(
          %{"directive" => "request_permission", "action" => "rewrite lib/core.ex"},
          session_id: "sess-a"
        )

      :ok = Agent.job_finished(id, {:ok, turn})

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(id, :awaiting_permission, 1_000)

      :processing = Agent.approve_action(id, action_id)
      assert_receive {:enqueued, %{"prompt" => "Approved: " <> _rest}, _meta}
      action_id
    end

    test "a failed approved turn re-gates with the same description and a fresh id" do
      id = start_agent!(approved_args: %{"permission_mode" => "accept_edits"})
      first_action_id = approve_gated!(id)

      err = error(:max_budget_exceeded, reason: %{session_id: "sess-b", cost_usd: 1.5})
      :ok = Agent.job_finished(id, {:error, {:cancel, :max_budget_exceeded}, err})

      assert {:ok, {:awaiting_permission, %{id: new_id, description: "rewrite lib/core.ex"}}} =
               Agent.await(id, :awaiting_permission, 1_000)

      assert new_id != first_action_id

      {:ok, history} = Agent.history(id)
      assert Enum.any?(history, &match?({:approval_incomplete, {:cancel, _}}, &1))

      # a re-approval resumes the interrupted session, still elevated
      :processing = Agent.approve_action(id, new_id)

      assert_receive {:enqueued,
                      %{
                        "prompt" => "Approved: " <> _rest,
                        "resume" => "sess-b",
                        "permission_mode" => "accept_edits"
                      }, _meta}
    end

    test "a watchdog timeout of an approved turn re-gates too" do
      id = start_agent!(job_timeout: 50)
      approve_gated!(id)

      assert {:ok, {:awaiting_permission, %{description: "rewrite lib/core.ex"}}} =
               Agent.await(id, :awaiting_permission, 1_000)
    end

    test "a completed approved turn resolves the approval (no re-gate)" do
      id = start_agent!()
      approve_gated!(id)

      :ok = Agent.job_finished(id, {:ok, result("edit done")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "an unapproved failed turn still falls to :idle" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "plain")
      :ok = Agent.job_finished(id, {:error, {:cancel, :auth}, error(:auth)})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "pause during an approved turn drops the in-flight approval" do
      id = start_agent!()
      approve_gated!(id)

      :ok = Agent.emergency_pause(id)
      {:ok, :paused} = Agent.await(id, :paused, 1_000)
      :resumed = Agent.resume_agent(id)

      # the late failure of the approved turn must NOT resurrect the gate
      :ok = Agent.job_finished(id, {:error, {:cancel, :timeout}, error(:timeout)})
      settle(id)
      assert {:ok, :idle} = Agent.status(id)
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
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "turn two")
      verdict = {:cancel, :auth}
      assert ^verdict = ObanClaude.Agent.Job.handle_error(verdict, error(:auth), job)
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "a job without an agent_id runs normally and reports to no one" do
      assert :ok = ObanClaude.Agent.Job.handle_result(result("done"), %Oban.Job{meta: %{}})

      assert {:error, :x} =
               ObanClaude.Agent.Job.handle_error({:error, :x}, :payload, %Oban.Job{meta: %{}})
    end
  end
end
