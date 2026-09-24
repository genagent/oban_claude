defmodule ObanClaude.AgentTest do
  # The spec's validation suite plus the lifecycle matrix, driven with an
  # injected :enqueue_fun (no Oban, no DB, no claude): the enqueue lands in the
  # test mailbox and the test plays the worker's role with the exact metadata
  # captured at enqueue time.
  use ExUnit.Case, async: true

  import ObanClaude.Testing

  alias ObanClaude.Agent
  alias ObanClaude.Agent.Instance

  setup do
    start_supervised!(ObanClaude.Agent.Supervisor)
    :ok
  end

  # job_finished/3 and emergency_pause/1 are casts; a call (history) queued
  # behind one guarantees it has been processed before the registry is read.
  defp settle(id) do
    {:ok, _} = Agent.history(id)
    :ok
  end

  defp start_agent!(opts \\ []) do
    id = "agent-" <> Integer.to_string(System.unique_integer([:positive]))
    start_named_agent!(id, opts)
    id
  end

  defp start_named_agent!(id, opts) do
    test_pid = self()

    enqueue_fun = fn args, meta ->
      send(test_pid, {:captured_turn, id, meta})
      send(test_pid, {:enqueued, args, meta})
      {:ok, :queued}
    end

    {:ok, _pid} = Agent.start_agent(id, Keyword.merge([enqueue_fun: enqueue_fun], opts))
    :ok
  end

  defp finish_captured(id, payload) do
    assert_receive {:captured_turn, ^id, meta}
    Agent.job_finished(id, payload, meta)
  end

  defp retry_captured(id, retry) do
    assert_receive {:captured_turn, ^id, meta}
    Agent.job_retrying(id, retry, meta)
  end

  defp fail_turn_start(:raise), do: raise("turn start failed")
  defp fail_turn_start(:throw), do: throw(:turn_start_failed)
  defp fail_turn_start(:exit), do: exit(:turn_start_failed)

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

    test "application correlation joins job metadata and lifecycle telemetry" do
      handler = "agent-correlation-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler,
          [
            [:oban_claude, :agent, :transition],
            [:oban_claude, :agent, :turn_completed]
          ],
          fn event, _measurements, meta, _config ->
            send(test_pid, {:lifecycle, event, meta})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      id = start_agent!()
      correlation_id = "request-42"

      assert :processing =
               Agent.submit_prompt(id, "run", correlation_id: correlation_id, arc_id: "operator")

      assert_receive {:captured_turn, ^id,
                      %{
                        "correlation_id" => ^correlation_id,
                        "agent_generation" => generation,
                        "agent_turn_id" => turn_id,
                        "arc_id" => "operator"
                      } = captured}

      assert_receive {:enqueued, %{"prompt" => "run"}, ^captured}

      assert_receive {:lifecycle, [:oban_claude, :agent, :transition],
                      %{
                        from: :idle,
                        to: :running,
                        correlation_id: ^correlation_id,
                        agent_generation: ^generation,
                        agent_turn_id: ^turn_id,
                        arc_id: "operator"
                      }}

      :ok = Agent.job_finished(id, {:ok, result("done")}, captured)

      assert_receive {:lifecycle, [:oban_claude, :agent, :turn_completed],
                      %{
                        outcome: :completed,
                        correlation_id: ^correlation_id,
                        agent_generation: ^generation,
                        agent_turn_id: ^turn_id,
                        arc_id: "operator"
                      }}

      assert_receive {:lifecycle, [:oban_claude, :agent, :transition],
                      %{from: :running, to: :idle, correlation_id: ^correlation_id}}
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

    test "an enqueue failure emits the exact correlated terminal outcome" do
      handler = "agent-correlation-failure-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler,
          [:oban_claude, :agent, :turn_completed],
          fn _event, _measurements, meta, _config -> send(test_pid, {:completed, meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      id = "agent-fail-" <> Integer.to_string(System.unique_integer([:positive]))
      {:ok, _} = Agent.start_agent(id, enqueue_fun: fn _args, _meta -> {:error, :db_down} end)

      assert {:error, {:enqueue_failed, :db_down}} =
               Agent.submit_prompt(id, "go", correlation_id: "request-failed")

      assert_receive {:completed,
                      %{
                        correlation_id: "request-failed",
                        outcome: :enqueue_failed,
                        outcome_reason: :db_down,
                        agent_generation: generation,
                        agent_turn_id: turn_id
                      }}

      assert is_binary(generation)
      assert is_binary(turn_id)
    end

    test "unexpected enqueue failures leave the agent alive and idle" do
      for {kind, reason} <- [
            raise: :turn_start_exception,
            throw: :turn_start_throw,
            exit: :turn_start_exit
          ] do
        id = "agent-#{kind}-" <> Integer.to_string(System.unique_integer([:positive]))

        {:ok, pid} =
          Agent.start_agent(id, enqueue_fun: fn _args, _meta -> fail_turn_start(kind) end)

        assert {:error, {:enqueue_failed, ^reason}} = Agent.submit_prompt(id, "go")
        assert Process.alive?(pid)
        assert {:ok, :idle} = Agent.status(id)
      end
    end
  end

  describe ":running" do
    test "a prompt during :running is postponed until the in-flight turn finishes" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "first")
      assert_receive {:enqueued, %{"prompt" => "first"}, _meta}

      caller = Task.async(fn -> Agent.submit_prompt(id, "second") end)
      refute_receive {:enqueued, %{"prompt" => "second"}, _meta}, 100

      :ok = finish_captured(id, {:ok, result("done")})
      assert :processing = Task.await(caller)
      assert_receive {:enqueued, %{"prompt" => "second"}, _meta}
      assert {:ok, :running} = Agent.status(id)
    end

    test "a postponed prompt keeps its own correlation id" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "first", correlation_id: "request-first")
      assert_receive {:enqueued, %{"prompt" => "first"}, %{"correlation_id" => "request-first"}}

      assert :ok = Agent.cast_prompt(id, "second", correlation_id: "request-second")
      refute_receive {:enqueued, %{"prompt" => "second"}, _meta}, 100

      :ok = finish_captured(id, {:ok, result("done")})

      assert_receive {:enqueued, %{"prompt" => "second"}, %{"correlation_id" => "request-second"}}
    end

    test "a plain result returns the agent to :idle" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      :ok = finish_captured(id, {:ok, result("all done")})

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
      :ok = finish_captured(id, {:error, {:cancel, :max_budget_exceeded}, err})
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

      :ok = finish_captured(id, {:ok, result("done")})
      assert_receive {:enqueued, %{"prompt" => "second"}, _meta}
      assert {:ok, :running} = Agent.status(id)
    end

    test "answers the pending question in :waiting_for_user" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "deploy")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(%{"directive" => "ask_user", "question" => "env?"}, session_id: "s")

      :ok = finish_captured(id, {:ok, turn})
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
      :ok = finish_captured(id, {:ok, result(result: "done", session_id: "sess-1")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "two", session: :fresh)
      assert_receive {:enqueued, %{"prompt" => "two"} = args, _meta}
      refute Map.has_key?(args, "resume")

      # the fresh turn's session becomes the new resume handle
      :ok = finish_captured(id, {:ok, result(result: "ok", session_id: "sess-2")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)
      :processing = Agent.submit_prompt(id, "three")
      assert_receive {:enqueued, %{"prompt" => "three", "resume" => "sess-2"}, _meta}
    end

    test "approval resumes the session produced by a fresh turn" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "plan", session: :fresh)
      assert_receive {:enqueued, %{"prompt" => "plan"} = args, _meta}
      refute Map.has_key?(args, "resume")

      request =
        structured_result(%{"directive" => "request_permission", "action" => "deploy"},
          session_id: "fresh-session"
        )

      :ok = finish_captured(id, {:ok, request})

      assert {:ok, {:awaiting_permission, action}} =
               Agent.await(id, :awaiting_permission, 1_000)

      :processing = Agent.approve_action(id, action.id)

      assert_receive {:enqueued,
                      %{"prompt" => "Approved: deploy. Proceed.", "resume" => "fresh-session"},
                      _meta}

      :ok = finish_captured(id, {:ok, result(result: "deployed", session_id: "fresh-session")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "a tick-origin prompt queues behind a pending question instead of answering it" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "deploy")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(%{"directive" => "ask_user", "question" => "env?"}, session_id: "s")

      :ok = finish_captured(id, {:ok, turn})
      {:ok, {:waiting_for_user, "env?"}} = Agent.await(id, :waiting_for_user, 1_000)

      :ok = Agent.cast_prompt(id, "scheduled beat", origin: :tick)
      settle(id)
      assert {:ok, {:waiting_for_user, "env?"}} = Agent.status(id)
      refute_receive {:enqueued, %{"prompt" => "scheduled beat"}, _meta}, 50

      # the operator's answer still owns the question; the beat runs after
      :processing = Agent.submit_prompt(id, "staging")
      assert_receive {:enqueued, %{"prompt" => "staging"}, _meta}
      :ok = finish_captured(id, {:ok, result("deployed")})
      assert_receive {:enqueued, %{"prompt" => "scheduled beat"}, _meta}
    end

    test "unknown option values raise" do
      assert_raise ArgumentError, fn -> Agent.submit_prompt("x", "p", session: :bogus) end
      assert_raise ArgumentError, fn -> Agent.cast_prompt("x", "p", origin: :cron) end
      assert_raise ArgumentError, fn -> Agent.cast_prompt("x", "p", correlation_id: "") end
    end

    test "job meta carries the arc's origin, and continuations inherit it" do
      id = start_agent!(approved_args: %{"model" => "opus"})

      # an operator prompt stamps origin operator
      :processing = Agent.submit_prompt(id, "how do things look?")
      assert_receive {:enqueued, _args, %{"agent_id" => ^id, "origin" => "operator"}}

      # the approve continuation of that arc keeps the operator origin
      turn =
        structured_result(%{"directive" => "request_permission", "action" => "fix it"},
          session_id: "s"
        )

      :ok = finish_captured(id, {:ok, turn})
      {:ok, {:awaiting_permission, action}} = Agent.await(id, :awaiting_permission, 1_000)
      :processing = Agent.approve_action(id, action.id)
      assert_receive {:enqueued, _args, %{"origin" => "operator"}}
      :ok = finish_captured(id, {:ok, result(result: "fixed", session_id: "s")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      # a scheduled beat flips the arc to tick origin
      :ok = Agent.cast_prompt(id, "do your sweep now", origin: :tick)
      assert_receive {:enqueued, _args, %{"agent_id" => ^id, "origin" => "tick"}}
    end
  end

  describe "retry-aware routing" do
    test "a retryable attempt keeps the machine :running and records the retry" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      assert_receive {:captured_turn, ^id, meta}

      job = %Oban.Job{attempt: 1, max_attempts: 3, meta: meta}
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
      assert_receive {:captured_turn, ^id, meta}

      job = %Oban.Job{attempt: 1, max_attempts: 1, meta: meta}
      ObanClaude.Agent.Job.handle_error({:snooze, 30}, result("parked"), job)
      settle(id)

      assert {:ok, :running} = Agent.status(id)
    end

    test "the final attempt's failure is terminal" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      assert_receive {:captured_turn, ^id, meta}

      job = %Oban.Job{attempt: 3, max_attempts: 3, meta: meta}
      ObanClaude.Agent.Job.handle_error({:error, :timeout}, error(:timeout), job)

      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      assert {:ok, history} = Agent.history(id)
      assert {:job_error, {:error, :timeout}} in history
    end

    test "a cancel verdict is terminal regardless of attempts remaining" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      assert_receive {:captured_turn, ^id, meta}

      job = %Oban.Job{attempt: 1, max_attempts: 3, meta: meta}
      ObanClaude.Agent.Job.handle_error({:cancel, :auth}, error(:auth), job)

      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "a retry re-arms the watchdog" do
      id = start_agent!(job_timeout: 300)
      :processing = Agent.submit_prompt(id, "turn")

      Process.sleep(200)
      :ok = retry_captured(id, %{attempt: 1, max_attempts: 3, verdict: {:error, :timeout}})

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

      :ok = finish_captured(id, {:ok, result(result: "done", session_id: "sess-42")})
      settle(id)

      :processing = Agent.submit_prompt(id, "second")
      assert_receive {:enqueued, %{"prompt" => "second", "resume" => "sess-42"}, _meta}
    end

    test "named arcs retain independent provider sessions" do
      id = start_agent!()

      :processing = Agent.submit_prompt(id, "operator one", arc_id: "operator")

      assert_receive {:enqueued, %{"prompt" => "operator one"},
                      %{
                        "arc_id" => "operator",
                        "continuation_decision" => "fresh",
                        "continuation_reason" => "no_session"
                      }}

      :ok = finish_captured(id, {:ok, result(result: "one", session_id: "operator-session")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "sweep one", arc_id: "sweep")
      assert_receive {:enqueued, %{"prompt" => "sweep one"} = sweep_args, %{"arc_id" => "sweep"}}
      refute Map.has_key?(sweep_args, "resume")
      :ok = finish_captured(id, {:ok, result(result: "two", session_id: "sweep-session")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "operator two", arc_id: "operator")

      assert_receive {:enqueued, %{"prompt" => "operator two", "resume" => "operator-session"},
                      %{
                        "arc_id" => "operator",
                        "session_id" => "operator-session",
                        "continuation_decision" => "resume"
                      }}

      assert {:ok,
              %{
                session_arcs: %{
                  "operator" => "operator-session",
                  "sweep" => "sweep-session"
                }
              }} = Agent.info(id)
    end

    test "a scheduled fresh turn clears only its selected arc" do
      id = start_agent!(session_arcs: %{"operator" => "operator-1", "sweep" => "sweep-1"})

      :processing =
        Agent.submit_prompt(id, "new sweep", arc_id: "sweep", origin: :tick, session: :fresh)

      assert_receive {:enqueued, %{"prompt" => "new sweep"} = args,
                      %{
                        "arc_id" => "sweep",
                        "origin" => "tick",
                        "continuation_decision" => "fresh",
                        "continuation_reason" => "requested"
                      }}

      refute Map.has_key?(args, "resume")
      :ok = finish_captured(id, {:ok, result(result: "swept", session_id: "sweep-2")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "continue", arc_id: "operator")
      assert_receive {:enqueued, %{"resume" => "operator-1"}, %{"arc_id" => "operator"}}
    end

    test "host-seeded arcs resume after an agent process restart" do
      id = "seeded-" <> Integer.to_string(System.unique_integer([:positive]))
      start_named_agent!(id, session_arcs: %{"issue-651" => "seed-session"})

      :processing = Agent.submit_prompt(id, "resume", arc_id: "issue-651")

      assert_receive {:enqueued, %{"resume" => "seed-session"},
                      %{"arc_id" => "issue-651", "continuation_decision" => "resume"}}

      :ok = finish_captured(id, {:ok, result(result: "done", session_id: "seed-session")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      :ok = Agent.stop_agent(id)
      assert {:ok, :offline} = Agent.await(id, :offline, 1_000)

      start_named_agent!(id, session_arcs: %{"issue-651" => "seed-session"})
      :processing = Agent.submit_prompt(id, "resume again", arc_id: "issue-651")
      assert_receive {:enqueued, %{"resume" => "seed-session"}, %{"arc_id" => "issue-651"}}
    end

    test "fork_arc keeps the source and stores the child under the target" do
      id = start_agent!(session_arcs: %{"main" => "parent-session"})

      :processing = Agent.fork_arc(id, "main", "experiment", "try another approach")

      assert_receive {:enqueued,
                      %{
                        "prompt" => "try another approach",
                        "resume" => "parent-session",
                        "fork_session" => true
                      },
                      %{
                        "arc_id" => "experiment",
                        "fork_from_arc_id" => "main",
                        "continuation_decision" => "resume",
                        "continuation_reason" => "fork"
                      }}

      :ok = finish_captured(id, {:ok, result(result: "forked", session_id: "child-session")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      assert {:ok,
              %{
                session_arcs: %{
                  "main" => "parent-session",
                  "experiment" => "child-session"
                }
              }} = Agent.info(id)
    end

    test "a rejected session is typed and a deliberate fresh fallback is recorded" do
      id = start_agent!(session_arcs: %{"work" => "missing-session"})
      :processing = Agent.submit_prompt(id, "resume", arc_id: "work")
      assert_receive {:enqueued, %{"resume" => "missing-session"}, _meta}

      failure = error(:command_failed, reason: :session_not_found)
      :ok = finish_captured(id, {:error, {:cancel, :session_not_found}, failure})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      assert {:ok,
              %{
                continuation: %{
                  arc_id: "work",
                  decision: :resume,
                  outcome: :session_rejected,
                  outcome_reason: {:cancel, :session_not_found}
                }
              }} = Agent.info(id)

      :processing =
        Agent.submit_prompt(id, "recover from handoff", arc_id: "work", session: :fresh_fallback)

      assert_receive {:enqueued, %{"prompt" => "recover from handoff"} = args,
                      %{
                        "arc_id" => "work",
                        "continuation_decision" => "fresh_fallback",
                        "continuation_reason" => "resume_failed"
                      }}

      refute Map.has_key?(args, "resume")
    end

    test "rail stops preserve the selected arc and completion telemetry" do
      id = start_agent!(session_arcs: %{"specialist" => "old-session"})
      handler_id = "arc-completion-" <> Integer.to_string(System.unique_integer([:positive]))
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:oban_claude, :agent, :turn_completed],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:turn_completed, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :processing = Agent.submit_prompt(id, "continue", arc_id: "specialist")
      assert_receive {:enqueued, %{"resume" => "old-session"}, _meta}

      failure =
        error(:max_budget_exceeded, reason: %{session_id: "rail-session", cost_usd: 1.0})

      :ok = finish_captured(id, {:error, {:cancel, :max_budget_exceeded}, failure})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      assert_receive {:turn_completed, [:oban_claude, :agent, :turn_completed], %{system_time: _},
                      %{
                        arc_id: "specialist",
                        session_id: "rail-session",
                        continuation_decision: :resume,
                        outcome: :failed
                      }}

      assert {:ok, %{session_arcs: %{"specialist" => "rail-session"}}} = Agent.info(id)
    end

    test "the arc map is bounded and evicts the least recently used handle" do
      id =
        start_agent!(
          session_arcs: %{"a" => "session-a", "b" => "session-b"},
          max_session_arcs: 2
        )

      :processing = Agent.submit_prompt(id, "touch a", arc_id: "a")
      :ok = finish_captured(id, {:ok, result(result: "a", session_id: "session-a")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "new c", arc_id: "c")
      :ok = finish_captured(id, {:ok, result(result: "c", session_id: "session-c")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      assert {:ok, %{session_arcs: %{"a" => "session-a", "c" => "session-c"}}} = Agent.info(id)
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

      :ok = finish_captured(id, {:ok, turn})

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

      :ok = finish_captured(id, {:ok, turn})

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
      :ok = finish_captured(id, {:ok, result("edited")})
      :processing = Agent.submit_prompt(id, "normal turn")
      assert_receive {:enqueued, %{"prompt" => "normal turn"} = args, _meta}
      refute Map.has_key?(args, "permission_mode")
    end

    test "an approval continuation retains the gated turn correlation" do
      id = start_agent!()

      :processing =
        Agent.submit_prompt(id, "plan", correlation_id: "request-gated")

      assert_receive {:enqueued, %{"prompt" => "plan"}, %{"correlation_id" => "request-gated"}}

      turn =
        structured_result(
          %{"directive" => "request_permission", "action" => "edit the file"},
          session_id: "sess-gated"
        )

      :ok = finish_captured(id, {:ok, turn})

      assert {:ok, {:awaiting_permission, %{id: action_id}}} =
               Agent.await(id, :awaiting_permission, 1_000)

      assert :processing = Agent.approve_action(id, action_id)

      assert_receive {:enqueued, %{"resume" => "sess-gated"},
                      %{"correlation_id" => "request-gated"}}
    end

    test "approve_action's :args size the elevation to this one approval (#121)" do
      id = start_agent!(approved_args: %{"permission_mode" => "bypass_permissions"})
      action_id = block_on_permission!(id)

      assert :processing =
               Agent.approve_action(id, action_id,
                 args: %{"permission_mode" => "default", "max_turns" => 5}
               )

      # the override wins over the standing approved_args, key by key
      assert_receive {:enqueued, %{"permission_mode" => "default", "max_turns" => 5}, _meta}

      # and is not remembered: the next approval is back to the standing args
      :ok = finish_captured(id, {:ok, result("done")})
      next_id = block_on_permission!(id)
      assert :processing = Agent.approve_action(id, next_id)
      assert_receive {:enqueued, %{"permission_mode" => "bypass_permissions"} = args, _meta}
      refute Map.has_key?(args, "max_turns")
    end

    test "approve_action refuses non-string :args keys and leaves the action pending" do
      id = start_agent!()
      action_id = block_on_permission!(id)

      assert {:error, {:invalid_args, [:permission_mode]}} =
               Agent.approve_action(id, action_id, args: %{permission_mode: "default"})

      assert {:ok, {:awaiting_permission, %{id: ^action_id}}} = Agent.status(id)
      refute_receive {:enqueued, _args, _meta}, 50

      assert :processing = Agent.approve_action(id, action_id)
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

  describe "action ids" do
    # One full gate cycle without polling: settle/1 orders the read behind the
    # job_finished cast, and the rejection returns the agent to :idle.
    defp gate_and_reject!(id) do
      :processing = Agent.submit_prompt(id, "plan a refactor")
      assert_receive {:enqueued, _args, _meta}

      turn =
        structured_result(
          %{"directive" => "request_permission", "action" => "rewrite lib/core.ex"},
          session_id: "sess-ids"
        )

      :ok = finish_captured(id, {:ok, turn})
      settle(id)

      {:ok, {:awaiting_permission, %{id: action_id}}} = Agent.status(id)
      :rejected = Agent.reject_action(id, action_id, "next")
      action_id
    end

    test "two generator lifetimes never share an id (#131)" do
      # A VM-local counter restarts with the VM, so the first gate of two
      # lifetimes would both read "act_1". Entropy is fresh per lifetime, so
      # the same position in each lifetime yields a different id.
      positions = 1..50
      lifetime_1 = for p <- positions, do: Instance.build_action_id(<<1::64, p::64>>)
      lifetime_2 = for p <- positions, do: Instance.build_action_id(<<2::64, p::64>>)

      assert length(Enum.uniq(lifetime_1 ++ lifetime_2)) == 100
      assert MapSet.disjoint?(MapSet.new(lifetime_1), MapSet.new(lifetime_2))
    end

    test "the builder is a pure function of its entropy, not of System.unique_integer" do
      entropy = :binary.copy(<<7>>, 16)
      first = Instance.build_action_id(entropy)

      _ = System.unique_integer([:positive])

      assert Instance.build_action_id(entropy) == first
      assert first == "act_" <> Base.url_encode64(entropy, padding: false)
    end

    test "a live gate's id is act_ plus 16 random bytes, not a counter" do
      id = start_agent!()
      action_id = gate_and_reject!(id)

      assert action_id =~ ~r/^act_[A-Za-z0-9_-]+$/
      refute action_id == "act_" <> Integer.to_string(System.unique_integer([:positive]))

      "act_" <> suffix = action_id
      assert {:ok, bytes} = Base.url_decode64(suffix, padding: false)
      assert byte_size(bytes) == 16
    end

    test "1000 gates in one process yield 1000 distinct ids" do
      id = start_agent!()

      ids = for _ <- 1..1_000, do: gate_and_reject!(id)

      assert length(Enum.uniq(ids)) == 1_000
      assert Enum.all?(ids, &String.starts_with?(&1, "act_"))
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
      :ok = finish_captured(id, {:ok, result(result: "late", session_id: "sess-late")})
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
      :ok = finish_captured(id, {:ok, turn})

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
      :ok = finish_captured(id, {:ok, result(result: "done", cost_usd: 0.25, session_id: "s")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "two")
      err = error(:max_budget_exceeded, reason: %{session_id: "s", cost_usd: 1.0})
      :ok = finish_captured(id, {:error, {:cancel, :max_budget_exceeded}, err})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      assert {:ok, %{state: :idle, turns: 2, cost_usd: cost, session_id: "s"}} = Agent.info(id)
      assert_in_delta cost, 1.25, 0.0001
    end

    test "history records the decoded structured output for --json-schema turns" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")

      structured = %{"directive" => "none", "summary" => "did the thing"}
      :ok = finish_captured(id, {:ok, structured_result(structured, [])})
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
        :ok = finish_captured(id, {:ok, result("done #{n}")})
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

      :ok = finish_captured(id, {:ok, turn})

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
      :ok = finish_captured(id, {:error, {:cancel, :max_budget_exceeded}, err})

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

      :ok = finish_captured(id, {:ok, result("edit done")})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "an unapproved failed turn still falls to :idle" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "plain")
      :ok = finish_captured(id, {:error, {:cancel, :auth}, error(:auth)})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "pause during an approved turn drops the in-flight approval" do
      id = start_agent!()
      approve_gated!(id)

      :ok = Agent.emergency_pause(id)
      {:ok, :paused} = Agent.await(id, :paused, 1_000)
      :resumed = Agent.resume_agent(id)

      # the late failure of the approved turn must NOT resurrect the gate
      :ok = finish_captured(id, {:error, {:cancel, :timeout}, error(:timeout)})
      settle(id)
      assert {:ok, :idle} = Agent.status(id)
    end
  end

  describe "turn ownership" do
    test "a timed-out turn cannot finish the next turn" do
      id = start_agent!(job_timeout: 40)
      :processing = Agent.submit_prompt(id, "A")
      assert_receive {:captured_turn, ^id, a_meta}
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "B")
      assert_receive {:captured_turn, ^id, b_meta}

      :ok = Agent.job_finished(id, {:ok, result(result: "A", session_id: "session-a")}, a_meta)
      settle(id)

      assert {:ok, :running} = Agent.status(id)
      assert {:ok, %{turns: 0, session_id: nil}} = Agent.info(id)

      :ok = Agent.job_finished(id, {:ok, result(result: "B", session_id: "session-b")}, b_meta)
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      assert {:ok, %{turns: 1, session_id: "session-b"}} = Agent.info(id)
    end

    test "a previous incarnation cannot finish a replacement with the same id" do
      id = "replacement-" <> Integer.to_string(System.unique_integer([:positive]))
      :ok = start_named_agent!(id, [])
      :processing = Agent.submit_prompt(id, "A")
      assert_receive {:captured_turn, ^id, a_meta}

      :ok = Agent.stop_agent(id)
      assert {:ok, :offline} = Agent.await(id, :offline, 1_000)
      :ok = start_named_agent!(id, [])

      :processing = Agent.submit_prompt(id, "B")
      assert_receive {:captured_turn, ^id, b_meta}
      assert a_meta["agent_generation"] != b_meta["agent_generation"]

      :ok = Agent.job_finished(id, {:ok, result(result: "A", session_id: "session-a")}, a_meta)
      settle(id)
      assert {:ok, :running} = Agent.status(id)
      assert {:ok, %{turns: 0, session_id: nil}} = Agent.info(id)

      :ok = Agent.job_finished(id, {:ok, result(result: "B", session_id: "session-b")}, b_meta)
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "pause records one matching completion but ignores its directives" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "A")
      assert_receive {:captured_turn, ^id, meta}
      :ok = Agent.emergency_pause(id)
      assert {:ok, :paused} = Agent.await(id, :paused, 1_000)

      payload =
        {:ok,
         structured_result(
           %{"directive" => "request_permission", "action" => "rewrite everything"},
           session_id: "session-a"
         )}

      :ok = Agent.job_finished(id, payload, meta)
      settle(id)
      assert {:ok, :paused} = Agent.status(id)
      assert {:ok, %{turns: 1, session_id: "session-a", pending_action: nil}} = Agent.info(id)

      :ok = Agent.job_finished(id, payload, meta)
      settle(id)
      assert {:ok, %{turns: 1, session_id: "session-a"}} = Agent.info(id)
    end

    test "a new turn replaces pause-resume bookkeeping ownership" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "A")
      assert_receive {:captured_turn, ^id, a_meta}
      :ok = Agent.emergency_pause(id)
      assert {:ok, :paused} = Agent.await(id, :paused, 1_000)
      :resumed = Agent.resume_agent(id)

      :processing = Agent.submit_prompt(id, "B")
      assert_receive {:captured_turn, ^id, b_meta}

      :ok = Agent.job_finished(id, {:ok, result(result: "A", session_id: "session-a")}, a_meta)
      settle(id)
      assert {:ok, :running} = Agent.status(id)
      assert {:ok, %{turns: 0, session_id: nil}} = Agent.info(id)

      :ok = Agent.job_finished(id, {:ok, result(result: "B", session_id: "session-b")}, b_meta)
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "a failed new enqueue preserves pause-resume bookkeeping ownership" do
      id = "bookkeeping-fail-" <> Integer.to_string(System.unique_integer([:positive]))
      test_pid = self()

      enqueue_fun = fn args, meta ->
        if args["prompt"] == "B" do
          {:error, :db_down}
        else
          send(test_pid, {:captured_turn, id, meta})
          {:ok, :queued}
        end
      end

      {:ok, _pid} = Agent.start_agent(id, enqueue_fun: enqueue_fun)
      :processing = Agent.submit_prompt(id, "A", arc_id: "arc-a")
      assert_receive {:captured_turn, ^id, a_meta}
      :ok = Agent.emergency_pause(id)
      assert {:ok, :paused} = Agent.await(id, :paused, 1_000)
      :resumed = Agent.resume_agent(id)

      assert {:error, {:enqueue_failed, :db_down}} =
               Agent.submit_prompt(id, "B", arc_id: "arc-b")

      assert {:ok, :idle} = Agent.status(id)

      :ok = Agent.job_finished(id, {:ok, result(result: "A", session_id: "session-a")}, a_meta)
      settle(id)

      assert {:ok,
              %{
                turns: 1,
                session_id: nil,
                session_arcs: %{"arc-a" => "session-a"},
                active_arc_id: "arc-b"
              }} = Agent.info(id)
    end

    test "duplicate completion and late retry are diagnostic only" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      assert_receive {:captured_turn, ^id, meta}
      payload = {:ok, result(result: "done", session_id: "session")}

      :ok = Agent.job_finished(id, payload, meta)
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
      :ok = Agent.job_finished(id, payload, meta)

      :ok =
        Agent.job_retrying(
          id,
          %{attempt: 2, max_attempts: 3, verdict: {:error, :timeout}},
          meta
        )

      settle(id)
      assert {:ok, %{turns: 1, session_id: "session"}} = Agent.info(id)
      assert {:ok, history} = Agent.history(id)
      assert Enum.count(history, &match?({:callback_rejected, _, _, _}, &1)) == 2
    end

    test "matching retries advance one watermark across both Oban snooze shapes" do
      id = start_agent!(job_timeout: 1_000)
      :processing = Agent.submit_prompt(id, "turn")
      assert_receive {:captured_turn, ^id, meta}

      retry = fn attempt, snoozed ->
        Agent.job_retrying(
          id,
          %{attempt: attempt, max_attempts: 5, verdict: {:snooze, 10}},
          Map.put(meta, "snoozed", snoozed)
        )
      end

      :ok = retry.(1, 0)
      :ok = retry.(2, 0)
      :ok = retry.(2, 0)
      :ok = retry.(1, 2)
      :ok = retry.(1, 2)
      settle(id)

      assert {:ok, history} = Agent.history(id)
      assert Enum.count(history, &match?({:retrying, _}, &1)) == 3
      assert Enum.count(history, &match?({:callback_rejected, :retrying, _, _}, &1)) == 2

      :ok = Agent.job_finished(id, {:ok, result("done")}, meta)
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "an old completion cannot replace a newer approval or session" do
      id = start_agent!(job_timeout: 40)
      :processing = Agent.submit_prompt(id, "A")
      assert_receive {:captured_turn, ^id, a_meta}
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "B")
      assert_receive {:captured_turn, ^id, b_meta}

      request =
        structured_result(
          %{"directive" => "request_permission", "action" => "deploy"},
          session_id: "session-b"
        )

      :ok = Agent.job_finished(id, {:ok, request}, b_meta)

      assert {:ok, {:awaiting_permission, %{id: action_id}}} =
               Agent.await(id, :awaiting_permission, 1_000)

      :ok = Agent.job_finished(id, {:ok, result(result: "A", session_id: "session-a")}, a_meta)
      settle(id)

      assert {:ok, {:awaiting_permission, %{id: ^action_id}}} = Agent.status(id)
      assert {:ok, %{turns: 1, session_id: "session-b"}} = Agent.info(id)
    end

    test "malformed identities and deprecated callbacks fail closed" do
      id = start_agent!()
      :processing = Agent.submit_prompt(id, "turn")
      assert_receive {:captured_turn, ^id, meta}

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      deprecated_finish = apply(Agent, :job_finished, [id, {:ok, result("old")}])
      assert {:error, :turn_identity_required} = deprecated_finish

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      deprecated_retry = apply(Agent, :job_retrying, [id, %{attempt: 1, max_attempts: 3}])
      assert {:error, :turn_identity_required} = deprecated_retry

      :ok = Agent.job_finished(id, {:ok, result("malformed")}, Map.put(meta, "agent_turn_id", ""))
      settle(id)
      assert {:ok, :running} = Agent.status(id)
      assert {:ok, %{turns: 0}} = Agent.info(id)

      :ok = Agent.job_finished(id, {:ok, result("done")}, meta)
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "a failed approval enqueue preserves the pending gate" do
      id = "approval-fail-" <> Integer.to_string(System.unique_integer([:positive]))
      test_pid = self()

      enqueue_fun = fn args, meta ->
        send(test_pid, {:captured_turn, id, meta})

        if String.starts_with?(args["prompt"], "Approved:") do
          {:error, :db_down}
        else
          {:ok, :queued}
        end
      end

      {:ok, _pid} = Agent.start_agent(id, enqueue_fun: enqueue_fun)
      :processing = Agent.submit_prompt(id, "plan")
      assert_receive {:captured_turn, ^id, meta}

      request =
        structured_result(%{"directive" => "request_permission", "action" => "deploy"})

      :ok = Agent.job_finished(id, {:ok, request}, meta)

      assert {:ok, {:awaiting_permission, %{id: action_id}}} =
               Agent.await(id, :awaiting_permission, 1_000)

      assert {:error, {:enqueue_failed, :db_down}} = Agent.approve_action(id, action_id)
      assert {:ok, {:awaiting_permission, %{id: ^action_id}}} = Agent.status(id)
      assert {:ok, %{pending_action: %{id: ^action_id}}} = Agent.info(id)
    end

    test "unexpected approval enqueue failures preserve the exact pending gate" do
      for {kind, reason} <- [
            raise: :turn_start_exception,
            throw: :turn_start_throw,
            exit: :turn_start_exit
          ] do
        id = "approval-#{kind}-" <> Integer.to_string(System.unique_integer([:positive]))
        test_pid = self()

        enqueue_fun = fn args, meta ->
          if String.starts_with?(args["prompt"], "Approved:") do
            fail_turn_start(kind)
          else
            send(test_pid, {:captured_turn, id, meta})
            {:ok, :queued}
          end
        end

        {:ok, pid} = Agent.start_agent(id, enqueue_fun: enqueue_fun)
        :processing = Agent.submit_prompt(id, "plan")
        assert_receive {:captured_turn, ^id, meta}

        request =
          structured_result(%{"directive" => "request_permission", "action" => "deploy"})

        :ok = Agent.job_finished(id, {:ok, request}, meta)

        assert {:ok, {:awaiting_permission, action}} =
                 Agent.await(id, :awaiting_permission, 1_000)

        assert {:error, {:enqueue_failed, ^reason}} = Agent.approve_action(id, action.id)
        assert Process.alive?(pid)
        assert {:ok, {:awaiting_permission, %{id: action_id}}} = Agent.status(id)
        assert action_id == action.id
        assert {:ok, %{pending_action: ^action}} = Agent.info(id)
      end
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

      :ok = finish_captured(id, {:ok, result("done")})
      assert_receive {:transition, %{agent_id: ^id, from: :running, to: :idle}}
    end
  end

  describe "ObanClaude.Agent.Job routing" do
    test "handle_result and handle_error report back to the agent named in job meta" do
      id = start_agent!()

      :processing = Agent.submit_prompt(id, "turn one")
      assert_receive {:captured_turn, ^id, first_meta}
      assert :ok = ObanClaude.Agent.Job.handle_result(result("done"), %Oban.Job{meta: first_meta})
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

      :processing = Agent.submit_prompt(id, "turn two")
      assert_receive {:captured_turn, ^id, second_meta}
      verdict = {:cancel, :auth}

      assert ^verdict =
               ObanClaude.Agent.Job.handle_error(
                 verdict,
                 error(:auth),
                 %Oban.Job{meta: second_meta}
               )

      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "a job without an agent_id runs normally and reports to no one" do
      assert :ok = ObanClaude.Agent.Job.handle_result(result("done"), %Oban.Job{meta: %{}})

      assert {:error, :x} =
               ObanClaude.Agent.Job.handle_error({:error, :x}, :payload, %Oban.Job{meta: %{}})
    end
  end
end
