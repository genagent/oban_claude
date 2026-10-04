defmodule ObanClaude.AgentObservationTest do
  use ExUnit.Case, async: false

  import ObanClaude.Testing
  alias ClaudeWrapper.SessionObservation
  alias ObanClaude.Agent
  alias ObanClaude.Agent.Job

  defmodule ObservedRunner do
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: raise("unexpected legacy execution")

    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: []

    @impl true
    def run_observed(_binary, args, _opts, _timeout, observe) do
      init = Jason.encode!(%{type: "system", subtype: "init", session_id: "live-early"})
      :observed = observe.(init)

      send(
        Application.fetch_env!(:oban_claude, :observation_test_pid),
        {:runner_blocked, self(), args}
      )

      receive do
        :finish ->
          terminal =
            Jason.encode!(%{
              type: "result",
              subtype: "success",
              is_error: false,
              result: "done",
              session_id: "live-early",
              total_cost_usd: 0.0
            })

          {:ok, {init <> "\n" <> terminal <> "\n", 0, ""}}
      end
    end
  end

  setup do
    start_supervised!(ObanClaude.Agent.Supervisor)
    test_pid = self()
    handler = "observations-#{System.unique_integer([:positive])}"

    events =
      for event <- [:execution_started, :session_observed, :turn_completed],
          do: [:oban_claude, :agent, event]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _measurements, meta, _config ->
          send(test_pid, {List.last(event), meta})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "default Port runner preserves ordinary one-shot Agent execution" do
    previous = Application.get_env(:claude_wrapper, :runner)
    Application.delete_env(:claude_wrapper, :runner)

    binary =
      Path.join(System.tmp_dir!(), "oban_claude-port-#{System.unique_integer([:positive])}")

    File.write!(
      binary,
      "#!/bin/sh\ncat <<'RESULT'\n" <>
        ~S({"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"port-session","total_cost_usd":0.0}) <>
        "\nRESULT\n"
    )

    File.chmod!(binary, 0o700)

    on_exit(fn ->
      if previous, do: Application.put_env(:claude_wrapper, :runner, previous)
      File.rm(binary)
    end)

    {id, job} = start_turn(args: %{"binary" => binary})
    assert :ok = Job.perform(job)
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert_receive {:execution_started, %{job_id: job_id}}
    assert_receive {:turn_completed, %{job_id: ^job_id, session_id: "port-session"}}
    refute_receive {:session_observed, _}, 10
    assert {:ok, %{session_arcs: %{"work" => "port-session"}}} = Agent.info(id)
  end

  test "default worker observes the wrapper session while transport is still blocked" do
    previous = Application.get_env(:claude_wrapper, :runner)
    Application.put_env(:claude_wrapper, :runner, ObservedRunner)
    Application.put_env(:oban_claude, :observation_test_pid, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:claude_wrapper, :runner, previous),
        else: Application.delete_env(:claude_wrapper, :runner)

      Application.delete_env(:oban_claude, :observation_test_pid)
    end)

    {id, job} = start_turn()
    task = Task.async(fn -> Job.perform(job) end)
    assert_receive {:runner_blocked, runner, args}
    assert "stream-json" in args
    assert_receive {:execution_started, %{job_id: job_id}}
    assert_receive {:session_observed, %{session_id: "live-early", job_id: ^job_id}}
    assert {:ok, %{turns: 0, continuation: %{session_id: "live-early"}}} = Agent.info(id)
    assert Task.yield(task, 0) == nil
    send(runner, :finish)
    assert Task.await(task) == :ok
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert_receive {:turn_completed, %{session_id: "live-early", job_id: ^job_id}}
  end

  test "retains the first accepted session before completion and fences public metadata" do
    {id, job} = start_turn(session_arcs: %{"work" => "old"})
    assert {:ok, {pid, ref}} = Agent.job_started(id, job)
    assert_receive {:execution_started, started}
    assert started.job_id == job.id
    assert started.job_attempt == 1
    assert started.job_snoozed == 0
    assert {:ok, %{continuation: %{session_id: nil, arc_id: "work"}}} = Agent.info(id)

    send(pid, {ref, %SessionObservation{session_id: "early"}})
    assert_receive {:session_observed, observed}
    assert observed.source == :system_init

    assert Map.take(observed, [:job_id, :job_attempt, :job_snoozed]) ==
             Map.take(started, [:job_id, :job_attempt, :job_snoozed])

    assert {:ok,
            %{turns: 0, continuation: %{session_id: "early"}, session_arcs: %{"work" => "early"}}} =
             Agent.info(id)

    send(pid, {ref, %SessionObservation{session_id: "early"}})
    send(pid, {ref, %SessionObservation{session_id: "conflict"}})
    assert :ok = Job.handle_result(result(result: "done", session_id: "terminal-conflict"), job)
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

    assert_receive {:turn_completed,
                    %{session_id: "early", execution_state: :started} = completed}

    assert completed.job_id == job.id
    assert {:ok, %{continuation: %{session_id: "early"}}} = Agent.info(id)
    refute_receive {:session_observed, _}, 10
  end

  test "registration rejects foreign generation, turn, arc, job and invalid attempt" do
    {id, job} = start_turn()

    for {key, value} <- [
          {"agent_generation", "other"},
          {"agent_turn_id", "other"},
          {"arc_id", "other"}
        ] do
      assert {:error, _} = Agent.job_started(id, %{job | meta: Map.put(job.meta, key, value)})
    end

    assert {:error, :job_id_mismatch} = Agent.job_started(id, %{job | id: job.id + 1})
    assert {:error, :invalid_execution_identity} = Agent.job_started(id, %{job | attempt: 0})

    assert {:error, :invalid_execution_identity} =
             Agent.job_started(id, %{job | meta: Map.put(job.meta, "snoozed", -1)})

    refute_receive {:execution_started, _}, 10
  end

  test "wrong references and sources cannot retain a session" do
    {id, job} = start_turn()
    {:ok, {pid, ref}} = Agent.job_started(id, job)
    send(pid, {make_ref(), %SessionObservation{session_id: "wrong-ref"}})
    send(pid, {ref, %SessionObservation{session_id: "wrong-source", source: :other}})
    send(pid, {ref, %SessionObservation{session_id: " \t\n"}})
    send(pid, {ref, %SessionObservation{session_id: String.duplicate("x", 257)}})
    assert {:ok, %{session_arcs: %{}}} = Agent.info(id)
    refute_receive {:session_observed, _}, 10
  end

  test "retry retires the old reference and late terminal callback" do
    {id, job} = start_turn()
    {:ok, {pid, old_ref}} = Agent.job_started(id, job)
    send(pid, {old_ref, %SessionObservation{session_id: "first"}})
    assert_receive {:session_observed, _}
    assert {:error, :timeout} = Job.handle_error({:error, :timeout}, error(:timeout), job)
    assert {:ok, _} = Agent.info(id)
    send(pid, {old_ref, %SessionObservation{session_id: "late"}})
    assert :ok = Job.handle_result(result("late"), job)
    assert {:ok, :running} = Agent.status(id)

    next = %{job | attempt: 2}
    assert {:ok, {^pid, next_ref}} = Agent.job_started(id, next)
    assert {:error, :execution_replayed} = Agent.job_started(id, job)
    send(pid, {old_ref, %SessionObservation{session_id: "old"}})
    send(pid, {next_ref, %SessionObservation{session_id: "second"}})
    assert_receive {:session_observed, %{session_id: "second", job_attempt: 2}}
    assert :ok = Job.handle_result(result("done"), next)
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert {:ok, %{session_arcs: %{"work" => "second"}}} = Agent.info(id)
  end

  test "snoozes advance execution ownership when Oban repeats the attempt number" do
    {id, job} = start_turn()
    {:ok, _} = Agent.job_started(id, job)
    assert {:snooze, 1} = Job.handle_error({:snooze, 1}, error(:timeout), job)
    assert {:ok, _} = Agent.info(id)
    next = %{job | meta: Map.put(job.meta, "snoozed", 1)}
    assert {:ok, {pid, ref}} = Agent.job_started(id, next)
    send(pid, {ref, %SessionObservation{session_id: "snoozed"}})
    assert_receive {:session_observed, %{job_attempt: 1, job_snoozed: 1}}
  end

  test "another process cannot complete the same registered execution" do
    {id, job} = start_turn()
    {:ok, _} = Agent.job_started(id, job)
    Task.async(fn -> Job.handle_result(result("wrong owner"), job) end) |> Task.await()
    assert {:ok, %{turns: 0}} = Agent.info(id)
    assert {:ok, :running} = Agent.status(id)
  end

  test "pause accepts only bookkeeping and does not act on completion directives" do
    {id, job} = start_turn()
    {:ok, {pid, ref}} = Agent.job_started(id, job)
    :ok = Agent.emergency_pause(id)
    assert {:ok, :paused} = Agent.await(id, :paused, 1_000)
    send(pid, {ref, %SessionObservation{session_id: "paused"}})

    :ok =
      Job.handle_result(
        structured_result(%{"directive" => "request_permission", "action" => "deploy"}),
        job
      )

    assert {:ok, %{state: :paused, pending_action: nil, session_arcs: %{"work" => "paused"}}} =
             Agent.info(id)
  end

  test "watchdog retains the observed handle and rejects observations after retirement" do
    {id, job} = start_turn(job_timeout: 80)
    {:ok, {pid, ref}} = Agent.job_started(id, job)
    send(pid, {ref, %SessionObservation{session_id: "interrupted"}})
    assert_receive {:session_observed, _}
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

    assert_receive {:turn_completed,
                    %{session_id: "interrupted", outcome: :timed_out, job_id: job_id}}

    assert job_id == job.id
    send(pid, {ref, %SessionObservation{session_id: "late"}})
    :processing = Agent.submit_prompt(id, "continue", arc_id: "work")
    assert_receive {:job, resumed}
    assert resumed.args["resume"] == "interrupted"
  end

  test "explicit rejection clears the selected handle while generic failure retains it" do
    {id, job} = start_turn(session_arcs: %{"work" => "old"})
    {:ok, {pid, ref}} = Agent.job_started(id, job)
    send(pid, {ref, %SessionObservation{session_id: "observed"}})
    assert_receive {:session_observed, _}

    {:cancel, :session_not_found} =
      Job.handle_error(
        {:cancel, :session_not_found},
        error(:command_failed, reason: :session_not_found),
        job
      )

    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert {:ok, %{session_arcs: %{}}} = Agent.info(id)

    assert_receive {:turn_completed,
                    %{
                      outcome: :session_rejected,
                      session_id: nil,
                      rejected_arc_id: "work",
                      rejected_session_id: "old"
                    }}
  end

  test "failed fork keeps an observed child and never assigns its source to target" do
    id = start_agent(session_arcs: %{"source" => "parent", "work" => "old-target"})
    :processing = Agent.fork_arc(id, "source", "work", "fork")
    assert_receive {:job, job}
    {:ok, {pid, ref}} = Agent.job_started(id, job)
    send(pid, {ref, %SessionObservation{session_id: "parent"}})
    assert {:ok, %{session_arcs: %{"work" => "old-target"}}} = Agent.info(id)
    send(pid, {ref, %SessionObservation{session_id: "child"}})
    assert_receive {:session_observed, %{session_id: "child"}}

    {:cancel, :timeout} =
      Job.handle_error({:cancel, :timeout}, error(:timeout, reason: %{session_id: "parent"}), job)

    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert {:ok, %{session_arcs: %{"source" => "parent", "work" => "child"}}} = Agent.info(id)
  end

  test "failed fork without an observed child cannot attach its source to target" do
    id = start_agent(session_arcs: %{"source" => "parent", "work" => "old-target"})
    :processing = Agent.fork_arc(id, "source", "work", "fork")
    assert_receive {:job, job}
    {:ok, {pid, ref}} = Agent.job_started(id, job)
    send(pid, {ref, %SessionObservation{session_id: "parent"}})

    {:cancel, :timeout} =
      Job.handle_error({:cancel, :timeout}, error(:timeout, reason: %{session_id: "parent"}), job)

    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

    assert {:ok, %{session_arcs: %{"source" => "parent", "work" => "old-target"}}} =
             Agent.info(id)

    assert_receive {:turn_completed, %{session_id: "old-target"}}
  end

  test "fork rejection clears the rejected source and preserves unrelated target" do
    id = start_agent(session_arcs: %{"source" => "parent", "work" => "old-target"})
    :processing = Agent.fork_arc(id, "source", "work", "fork")
    assert_receive {:job, job}
    {:ok, _} = Agent.job_started(id, job)

    {:cancel, :session_not_found} =
      Job.handle_error(
        {:cancel, :session_not_found},
        error(:command_failed, reason: :session_not_found),
        job
      )

    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert {:ok, %{session_arcs: arcs}} = Agent.info(id)
    assert arcs == %{"work" => "old-target"}

    assert_receive {:turn_completed,
                    %{
                      session_id: "old-target",
                      rejected_arc_id: "source",
                      rejected_session_id: "parent",
                      fork_from_arc_id: "source"
                    }}
  end

  test "a queued watchdog after a completed turn is explicitly unstarted" do
    {id, first} = start_turn(job_timeout: 80)
    {:ok, {pid, ref}} = Agent.job_started(id, first)
    send(pid, {ref, %SessionObservation{session_id: "retained"}})
    assert_receive {:session_observed, _}
    :ok = Job.handle_result(result("done"), first)
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert_receive {:turn_completed, %{execution_state: :started}}

    :processing = Agent.submit_prompt(id, "queued", arc_id: "work")
    assert_receive {:job, _queued}
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

    assert_receive {:turn_completed,
                    %{execution_state: :not_started, outcome: :timed_out, session_id: "retained"} =
                      meta}

    refute Map.has_key?(meta, :job_id)
    refute Map.has_key?(meta, :job_attempt)
    refute Map.has_key?(meta, :job_snoozed)
    assert {:ok, %{session_arcs: %{"work" => "retained"}}} = Agent.info(id)
  end

  test "enqueue failure is explicitly unstarted and tuple free" do
    id = start_agent(enqueue_fun: fn _args, _meta -> {:error, :unavailable} end)

    assert {:error, {:enqueue_failed, :unavailable}} =
             Agent.submit_prompt(id, "fail", arc_id: "work")

    assert_receive {:turn_completed,
                    %{execution_state: :not_started, outcome: :enqueue_failed} = meta}

    refute Map.has_key?(meta, :job_id)
  end

  test "invalid args complete the registered worker attempt without claiming CLI execution" do
    {id, job} = start_turn(args: %{"permission_mode" => "invalid"})
    assert {:cancel, {:invalid_args, _message}} = Job.perform(job)
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)

    assert_receive {:execution_started,
                    %{job_id: job_id, job_attempt: attempt, job_snoozed: snoozed}}

    assert_receive {:turn_completed,
                    %{
                      execution_state: :started,
                      outcome: :failed,
                      job_id: ^job_id,
                      job_attempt: ^attempt,
                      job_snoozed: ^snoozed
                    }}

    assert job_id == job.id
    refute_receive {:session_observed, _}, 10
  end

  test "injected query functions keep their existing keyword contract" do
    {id, job} = start_turn()
    test_pid = self()

    query = fn prompt, opts ->
      send(test_pid, {:query_opts, opts})
      {:ok, result(prompt)}
    end

    assert {:ok, _} = ObanClaude.run(job.args, job: job, query_fun: query)
    assert_receive {:query_opts, opts}
    refute Keyword.has_key?(opts, :session_observer)
    assert_receive {:execution_started, _}
    :ok = Job.handle_result(result("done"), job)
    assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    assert Jason.encode!(job.meta)
  end

  defp start_turn(opts \\ []) do
    id = start_agent(opts)
    :processing = Agent.submit_prompt(id, "prompt", arc_id: "work")
    assert_receive {:job, job}
    {id, job}
  end

  defp start_agent(opts) do
    id = "observation-#{System.unique_integer([:positive])}"
    test_pid = self()

    enqueue = fn args, meta ->
      job = %Oban.Job{
        id: System.unique_integer([:positive]),
        args: args,
        meta: meta,
        attempt: 1,
        max_attempts: 3
      }

      send(test_pid, {:job, job})
      {:ok, job}
    end

    {:ok, _pid} = Agent.start_agent(id, Keyword.merge([enqueue_fun: enqueue], opts))
    id
  end
end
