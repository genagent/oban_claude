defmodule ObanClaude.Agent.Instance do
  @moduledoc """
  One agent as one `:gen_statem` process, its asynchronous turns run as Oban
  jobs (spike, see PR #115).

  The process never blocks on claude: a prompt enqueues an `ObanClaude.Worker`
  job and the machine parks in `:running` until the worker's callbacks route
  the outcome back as a `{:job_finished, payload}` cast (via
  `ObanClaude.Agent.job_finished/2`). States:

    * `:idle` -- ready for a prompt
    * `:running` -- an Oban job is in flight; further prompts are `:postpone`d
      and a `:state_timeout` watchdog guards against a turn that never reports
      back
    * `:waiting_for_user` -- the last turn asked a question (structured-output
      directive `"ask_user"`); the next prompt is treated as the answer and
      resumes the claude session
    * `:awaiting_permission` -- the last turn requested approval (directive
      `"request_permission"`); `approve` resumes the session with the action,
      `reject` records the denial and returns to `:idle`
    * `:paused` -- lockdown via `:emergency_pause`; every call is refused until
      an explicit `resume`

  Every state change synchronizes the registry value (so
  `ObanClaude.Agent.get_status/1` reads status without messaging the process)
  and emits `[:oban_claude, :agent, :transition]` telemetry with
  `%{agent_id, from, to}` metadata.

  The claude session id is read off each turn's payload (including rail-stop
  errors) and threaded into the next turn as `resume`, so one agent is one
  persistent claude conversation.

  ## Config

  `start_agent/2` takes a keyword list or map:

    * `:args` -- default claude args merged under every turn's prompt (build
      with `ObanClaude.Args.defaults/1`); default `%{}`
    * `:worker` -- the Oban worker module for turns; default
      `ObanClaude.Agent.Job`
    * `:oban` -- the Oban instance name to insert into; default `Oban`
    * `:job_timeout` -- the `:running` watchdog in milliseconds; default 60000
    * `:enqueue_fun` -- a 2-arity `(args, meta) -> {:ok, term} | {:error, term}`
      override of the enqueue itself, for tests (no Oban, no DB)
  """

  @behaviour :gen_statem

  alias ClaudeWrapper.Result

  require Logger

  @registry ObanClaude.Agent.Registry

  @defaults %{
    args: %{},
    worker: ObanClaude.Agent.Job,
    oban: Oban,
    enqueue_fun: nil,
    job_timeout: 60_000
  }

  def child_spec({agent_id, config}) do
    %{
      id: {:agent, agent_id},
      start: {__MODULE__, :start_link, [agent_id, config]},
      # Reboot on a crash, but a clean stop stays stopped.
      restart: :transient,
      type: :worker
    }
  end

  def start_link(agent_id, config) do
    :gen_statem.start_link(
      {:via, Registry, {@registry, agent_id, :idle}},
      __MODULE__,
      {agent_id, config},
      []
    )
  end

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init({agent_id, config}) do
    data = %{
      id: agent_id,
      config: Map.merge(@defaults, Map.new(config)),
      history: [],
      session_id: nil,
      pending_action: nil,
      pending_question: nil
    }

    {:ok, :idle, data}
  end

  @impl :gen_statem
  # Centralized wrapper: on every real state change, sync the registry value
  # and emit transition telemetry before gen_statem executes the actions (so a
  # caller that just got its reply already sees the new status).
  def handle_event(type, content, state, data) do
    case process_event(state, type, content, data) do
      {:next_state, next, new_data} when next != state ->
        sync_transition(state, next, new_data)
        {:next_state, next, new_data}

      {:next_state, next, new_data, actions} when next != state ->
        sync_transition(state, next, new_data)
        {:next_state, next, new_data, actions}

      other ->
        other
    end
  end

  # ---------------------------------------------------------------------------
  # any state: introspection and the emergency brake
  # ---------------------------------------------------------------------------

  defp process_event(_state, {:call, from}, :history, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, Enum.reverse(data.history)}}]}
  end

  defp process_event(_state, {:call, from}, :pending, data) do
    pending = %{action: data.pending_action, question: data.pending_question}
    {:keep_state_and_data, [{:reply, from, {:ok, pending}}]}
  end

  defp process_event(state, :cast, :emergency_pause, data) when state != :paused do
    {:next_state, :paused, record(data, {:paused_from, state})}
  end

  # ---------------------------------------------------------------------------
  # :paused -- lockdown until an explicit resume
  # ---------------------------------------------------------------------------

  defp process_event(:paused, {:call, from}, :resume, data) do
    {:next_state, :idle, data, [{:reply, from, :resumed}]}
  end

  # A turn that was in flight when the pause hit: absorb the payload (history,
  # session id) but stay locked and ignore its directives.
  defp process_event(:paused, :cast, {:job_finished, payload}, data) do
    {:keep_state, absorb(data, payload)}
  end

  defp process_event(:paused, {:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :paused}}]}
  end

  # ---------------------------------------------------------------------------
  # :idle
  # ---------------------------------------------------------------------------

  defp process_event(:idle, {:call, from}, {:user_prompt, text}, data) do
    start_turn(from, text, data)
  end

  # A turn that outlived its watchdog: keep its payload, stay idle.
  defp process_event(:idle, :cast, {:job_finished, payload}, data) do
    {:keep_state, absorb(data, payload)}
  end

  # ---------------------------------------------------------------------------
  # :running
  # ---------------------------------------------------------------------------

  defp process_event(:running, {:call, _from}, {:user_prompt, _text}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  defp process_event(:running, :cast, {:job_finished, payload}, data) do
    finish_turn(data, payload)
  end

  defp process_event(:running, :state_timeout, :job_watchdog, data) do
    Logger.warning("ObanClaude.Agent #{data.id}: job watchdog fired, returning to :idle")
    {:next_state, :idle, record(data, :watchdog_timeout)}
  end

  # ---------------------------------------------------------------------------
  # :waiting_for_user -- the next prompt answers the pending question
  # ---------------------------------------------------------------------------

  defp process_event(:waiting_for_user, {:call, from}, {:user_prompt, answer}, data) do
    start_turn(from, answer, %{data | pending_question: nil})
  end

  # ---------------------------------------------------------------------------
  # :awaiting_permission
  # ---------------------------------------------------------------------------

  defp process_event(:awaiting_permission, {:call, from}, {:approve_action, id}, data) do
    case data.pending_action do
      %{id: ^id, description: description} ->
        prompt = "Approved: #{description}. Proceed."
        start_turn(from, prompt, %{data | pending_action: nil})

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :unknown_action}}]}
    end
  end

  defp process_event(:awaiting_permission, {:call, from}, {:reject_action, id, reason}, data) do
    case data.pending_action do
      %{id: ^id} ->
        Logger.info("ObanClaude.Agent #{data.id}: action #{id} rejected: #{reason}")
        data = %{record(data, {:denied, id, reason}) | pending_action: nil}
        {:next_state, :idle, data, [{:reply, from, :rejected}]}

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :unknown_action}}]}
    end
  end

  # ---------------------------------------------------------------------------
  # catch-alls
  # ---------------------------------------------------------------------------

  defp process_event(state, {:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :invalid_action, state}}]}
  end

  defp process_event(_state, _type, _content, _data), do: :keep_state_and_data

  # ---------------------------------------------------------------------------
  # turns
  # ---------------------------------------------------------------------------

  # Enqueue one claude turn and park in :running under the watchdog. The args
  # are the config defaults, the prompt, and (from the second turn on) the
  # resume handle of the agent's claude session.
  defp start_turn(from, prompt, data) do
    args =
      data.config.args
      |> Map.put("prompt", prompt)
      |> maybe_resume(data.session_id)

    case enqueue(data, args) do
      {:ok, _job} ->
        watchdog = {:state_timeout, data.config.job_timeout, :job_watchdog}

        {:next_state, :running, record(data, {:prompt, prompt}),
         [{:reply, from, :processing}, watchdog]}

      {:error, reason} ->
        {:next_state, :idle, record(data, {:enqueue_failed, reason}),
         [{:reply, from, {:error, {:enqueue_failed, reason}}}]}
    end
  end

  # Route on the finished turn's structured-output directive.
  defp finish_turn(data, {:ok, %Result{} = result} = payload) do
    data = absorb(data, payload)

    case directive(result) do
      {:ask_user, question} ->
        {:next_state, :waiting_for_user, %{data | pending_question: question}}

      {:request_permission, description} ->
        action = %{id: action_id(), description: description}
        {:next_state, :awaiting_permission, %{data | pending_action: action}}

      :none ->
        {:next_state, :idle, data}
    end
  end

  defp finish_turn(data, {:error, _verdict, _payload} = failure) do
    {:next_state, :idle, absorb(data, failure)}
  end

  # Fold a turn's payload into the data: a history entry, plus the claude
  # session id when the payload carries one (a rail-stop %Error{} does too).
  defp absorb(data, {:ok, %Result{} = result}) do
    data = record(data, {:result, result.result})
    %{data | session_id: result.session_id || data.session_id}
  end

  defp absorb(data, {:error, verdict, payload}) do
    data = record(data, {:job_error, verdict})
    %{data | session_id: ObanClaude.session_id(payload) || data.session_id}
  end

  defp directive(result) do
    case ObanClaude.structured(result) do
      %{"directive" => "ask_user"} = d ->
        {:ask_user, d["question"]}

      %{"directive" => "request_permission"} = d ->
        {:request_permission, d["action"] || "the pending action"}

      _ ->
        :none
    end
  end

  defp enqueue(%{config: %{enqueue_fun: fun}} = data, args) when is_function(fun, 2) do
    fun.(args, %{"agent_id" => data.id})
  end

  defp enqueue(data, args) do
    args
    |> data.config.worker.new(meta: %{"agent_id" => data.id})
    |> then(&Oban.insert(data.config.oban, &1))
  end

  defp maybe_resume(args, nil), do: args
  defp maybe_resume(args, session_id), do: Map.put(args, "resume", session_id)

  defp action_id, do: "act_" <> Integer.to_string(System.unique_integer([:positive]))

  defp record(data, entry), do: %{data | history: [entry | data.history]}

  defp sync_transition(from, to, data) do
    Registry.update_value(@registry, data.id, fn _old -> to end)

    :telemetry.execute(
      [:oban_claude, :agent, :transition],
      %{system_time: System.system_time()},
      %{agent_id: data.id, from: from, to: to}
    )
  end
end
