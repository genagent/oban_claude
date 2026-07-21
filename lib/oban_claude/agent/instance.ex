defmodule ObanClaude.Agent.Instance do
  @moduledoc """
  One agent as one `:gen_statem` process, its asynchronous turns run as Oban
  jobs. Part of the experimental agent layer (see `ObanClaude.Agent`).

  The process never blocks on claude: a prompt enqueues an `ObanClaude.Worker`
  job and the machine parks in `:running` until the worker's callbacks route
  the outcome back as a `{:job_finished, payload}` cast (via
  `ObanClaude.Agent.job_finished/2`). States:

    * `:idle` -- ready for a prompt
    * `:running` -- an Oban job is in flight; further prompts are `:postpone`d
      and a `:state_timeout` watchdog guards against a turn that never reports
      back. A retryable failed attempt (`ObanClaude.Agent.job_retrying/2`)
      keeps the machine here and re-arms the watchdog, so `:job_timeout` should
      exceed one attempt's backoff plus its execution
    * `:waiting_for_user` -- the last turn asked a question (structured-output
      directive `"ask_user"`); the next prompt is treated as the answer and
      resumes the claude session
    * `:awaiting_permission` -- the last turn requested approval (directive
      `"request_permission"`); `approve` resumes the session with the action
      (under `:approved_args`, see below), `reject` records the denial and
      returns to `:idle`, and prompts are `:postpone`d until the gate clears.
      An approved turn that fails or hits the watchdog RE-GATES (same
      description, fresh id, `{:approval_incomplete, reason}` in history):
      the work was approved but not completed, and a re-approval resumes it
    * `:paused` -- lockdown via `:emergency_pause`; every call is refused until
      an explicit `resume`

  Every state change atomically synchronizes the registry value -- the state
  atom, paired with the pending action or question in the gated states -- so
  `ObanClaude.Agent.status/1` reads both without messaging the process. Each
  change also emits `[:oban_claude, :agent, :transition]` telemetry with
  `%{agent_id, from, to}` metadata (state atoms).

  The claude session id is read off each turn's payload (including rail-stop
  errors) and threaded into the next turn as `resume`, so one agent is one
  persistent claude conversation. Turn count and accumulated cost ride in the
  data (see `ObanClaude.Agent.info/1`).

  ## Config

  `start_agent/2` takes a keyword list or map:

    * `:args` -- default claude args merged under every turn's prompt (build
      with `ObanClaude.Args.defaults/1`; string keys); default `%{}`
    * `:approved_args` -- claude args merged over `:args` for approve
      continuations ONLY, so conversational approval actually unlocks
      something -- e.g. `%{"permission_mode" => "accept_edits"}` or an
      `allowed_tools` grant. Normal turns never carry these. Default `%{}`.
    * `:worker` -- the Oban worker module for turns; default
      `ObanClaude.Agent.Job`
    * `:oban` -- the Oban instance name to insert into; default `Oban`
    * `:job_timeout` -- the `:running` watchdog in milliseconds; default 60000
    * `:max_history` -- cap on retained history entries (newest win); default
      500, so an always-on agent's event log cannot grow without bound
    * `:enqueue_fun` -- a 2-arity `(args, meta) -> {:ok, term} | {:error, term}`
      override of the enqueue itself, for tests (no Oban, no DB)
  """

  @behaviour :gen_statem

  alias ClaudeWrapper.Result

  require Logger

  @registry ObanClaude.Agent.Registry

  @defaults %{
    args: %{},
    approved_args: %{},
    worker: ObanClaude.Agent.Job,
    oban: Oban,
    enqueue_fun: nil,
    job_timeout: 60_000,
    # History is an in-process event log; an always-on agent must not grow it
    # without bound. Newest entries win; the cap is per-entry, not per-turn.
    max_history: 500
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
    config = Map.merge(@defaults, Map.new(config))
    validate_string_keys!(:args, config.args)
    validate_string_keys!(:approved_args, config.approved_args)

    data = %{
      id: agent_id,
      config: config,
      history: [],
      session_id: nil,
      turns: 0,
      cost_usd: 0.0,
      pending_action: nil,
      pending_question: nil,
      # set while an approve continuation is in flight: an approved turn that
      # fails or times out RE-GATES (the action was approved but not
      # completed) instead of falling to :idle with the elevation lost
      in_flight_approval: nil
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

  defp process_event(state, {:call, from}, :info, data) do
    info = %{
      id: data.id,
      state: state,
      session_id: data.session_id,
      turns: data.turns,
      cost_usd: data.cost_usd,
      pending_action: data.pending_action,
      pending_question: data.pending_question
    }

    {:keep_state_and_data, [{:reply, from, {:ok, info}}]}
  end

  # "Drops active scopes": a pending action, question, or in-flight approval
  # does not survive the lockdown; after resume the operator starts clean.
  defp process_event(state, :cast, :emergency_pause, data) when state != :paused do
    data = %{
      record(data, {:paused_from, state})
      | pending_action: nil,
        pending_question: nil,
        in_flight_approval: nil
    }

    {:next_state, :paused, data}
  end

  # ---------------------------------------------------------------------------
  # :paused -- lockdown until an explicit resume
  # ---------------------------------------------------------------------------

  defp process_event(:paused, {:call, from}, :resume, data) do
    {:next_state, :idle, data, [{:reply, from, :resumed}]}
  end

  # A turn that was in flight when the pause hit: absorb the payload (history,
  # session id, spend) but stay locked and ignore its directives.
  defp process_event(:paused, :cast, {:job_finished, payload}, data) do
    {:keep_state, absorb(data, payload)}
  end

  # A cast prompt has no caller to refuse, so lockdown drops it -- recorded, so
  # the drop is visible in history rather than silent.
  defp process_event(:paused, :cast, {:user_prompt, text, _opts}, data) do
    {:keep_state, record(data, {:dropped_prompt, text})}
  end

  defp process_event(:paused, {:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :paused}}]}
  end

  # ---------------------------------------------------------------------------
  # :idle
  # ---------------------------------------------------------------------------

  defp process_event(:idle, {:call, from}, {:user_prompt, text, opts}, data) do
    start_turn(from, text, prompt_data(data, opts))
  end

  defp process_event(:idle, :cast, {:user_prompt, text, opts}, data) do
    start_turn(nil, text, prompt_data(data, opts))
  end

  # A turn that outlived its watchdog: keep its payload, stay idle.
  defp process_event(:idle, :cast, {:job_finished, payload}, data) do
    {:keep_state, absorb(data, payload)}
  end

  # ---------------------------------------------------------------------------
  # :running
  # ---------------------------------------------------------------------------

  # Both the call and the cast form postpone: a called prompt blocks its
  # caller until the turn finishes, a cast one just queues.
  defp process_event(:running, _type, {:user_prompt, _text, _opts}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  defp process_event(:running, :cast, {:job_finished, payload}, data) do
    finish_turn(data, payload)
  end

  # A retryable attempt failed and Oban will re-run the job: the turn is still
  # logically in flight, so stay :running, log it, and re-arm the watchdog to
  # cover the retry's backoff plus its execution.
  defp process_event(:running, :cast, {:job_retrying, retry}, data) do
    {:keep_state, record(data, {:retrying, retry}),
     [{:state_timeout, data.config.job_timeout, :job_watchdog}]}
  end

  defp process_event(:running, :state_timeout, :job_watchdog, data) do
    Logger.warning("ObanClaude.Agent #{data.id}: job watchdog fired")
    regate_or_idle(record(data, :watchdog_timeout), :watchdog_timeout)
  end

  # ---------------------------------------------------------------------------
  # :waiting_for_user -- the next prompt answers the pending question
  # ---------------------------------------------------------------------------

  # A scheduled (tick-origin) prompt must never masquerade as the operator's
  # answer to the pending question -- it queues behind the answer instead.
  # Matching on origin here (not a status pre-check in the scheduler) makes
  # delivery race-safe: however the prompt arrives, it cannot consume the
  # question.
  defp process_event(:waiting_for_user, _type, {:user_prompt, _text, %{origin: :tick}}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  defp process_event(:waiting_for_user, {:call, from}, {:user_prompt, answer, opts}, data) do
    start_turn(from, answer, prompt_data(%{data | pending_question: nil}, opts))
  end

  defp process_event(:waiting_for_user, :cast, {:user_prompt, answer, opts}, data) do
    start_turn(nil, answer, prompt_data(%{data | pending_question: nil}, opts))
  end

  # ---------------------------------------------------------------------------
  # :awaiting_permission
  # ---------------------------------------------------------------------------

  # Prompts queue behind the gate rather than erroring (deviation from the
  # original matrix, from live use): the operator can line up the next thing
  # while deciding on the approval. Call and cast forms alike.
  defp process_event(:awaiting_permission, _type, {:user_prompt, _text, _opts}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  defp process_event(:awaiting_permission, {:call, from}, {:approve_action, id}, data) do
    case data.pending_action do
      %{id: ^id, description: description} ->
        prompt = "Approved: #{description}. Proceed."

        data = %{
          data
          | pending_action: nil,
            in_flight_approval: %{description: description}
        }

        start_turn(from, prompt, data, data.config.approved_args)

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
  # are the config defaults, any per-turn extras (approve continuations carry
  # :approved_args), the prompt, and (from the second turn on) the resume
  # handle of the agent's claude session. `from` is nil on the cast path
  # (no caller to reply to).
  defp start_turn(from, prompt, data, extra_args \\ %{}) do
    args =
      data.config.args
      |> Map.merge(extra_args)
      |> Map.put("prompt", prompt)
      |> maybe_resume(data.session_id)

    case enqueue(data, args) do
      {:ok, _job} ->
        watchdog = {:state_timeout, data.config.job_timeout, :job_watchdog}

        {:next_state, :running, record(data, {:prompt, prompt}),
         reply(from, :processing) ++ [watchdog]}

      {:error, reason} ->
        {:next_state, :idle, record(data, {:enqueue_failed, reason}),
         reply(from, {:error, {:enqueue_failed, reason}})}
    end
  end

  defp reply(nil, _message), do: []
  defp reply(from, message), do: [{:reply, from, message}]

  # `session: :fresh` clears the resume handle at delivery time (not at send
  # time), so it composes correctly with postponed prompts: the turn that
  # finally runs starts a new claude session, and its result seeds the new
  # session id.
  defp prompt_data(data, %{session: :fresh}), do: %{data | session_id: nil}
  defp prompt_data(data, _opts), do: data

  # Route on the finished turn's structured-output directive. A completed
  # approve continuation resolves its approval, whatever it returns.
  defp finish_turn(data, {:ok, %Result{} = result} = payload) do
    data = %{absorb(data, payload) | in_flight_approval: nil}

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

  defp finish_turn(data, {:error, verdict, _payload} = failure) do
    regate_or_idle(absorb(data, failure), verdict)
  end

  # An approved turn that did not complete (failed verdict, watchdog) re-gates:
  # the action was approved but the work is not done, so it goes back to
  # :awaiting_permission (same description, fresh id) rather than silently
  # dropping the elevation on the floor. The captured session id means a
  # re-approval resumes the interrupted work. Unapproved turns fall to :idle.
  defp regate_or_idle(%{in_flight_approval: nil} = data, _reason) do
    {:next_state, :idle, data}
  end

  defp regate_or_idle(%{in_flight_approval: %{description: description}} = data, reason) do
    action = %{id: action_id(), description: description}
    data = record(data, {:approval_incomplete, reason})
    {:next_state, :awaiting_permission, %{data | pending_action: action, in_flight_approval: nil}}
  end

  # Fold a turn's payload into the data: a history entry (the decoded
  # structured output when the turn produced one, the plain text otherwise),
  # the turn/spend counters, and the claude session id when the payload
  # carries one (a rail-stop %Error{} does too).
  defp absorb(data, {:ok, %Result{} = result}) do
    data
    |> record({:result, ObanClaude.structured(result) || result.result})
    |> count_turn(result.cost_usd)
    |> keep_session(result.session_id)
  end

  defp absorb(data, {:error, verdict, payload}) do
    data
    |> record({:job_error, verdict})
    |> count_turn(ObanClaude.cost_usd(payload))
    |> keep_session(ObanClaude.session_id(payload))
  end

  defp count_turn(data, cost) do
    %{data | turns: data.turns + 1, cost_usd: data.cost_usd + (cost || 0.0)}
  end

  defp keep_session(data, session_id), do: %{data | session_id: session_id || data.session_id}

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

  defp record(data, entry) do
    %{data | history: Enum.take([entry | data.history], data.config.max_history)}
  end

  defp sync_transition(from, to, data) do
    Registry.update_value(@registry, data.id, fn _old -> status_value(to, data) end)

    :telemetry.execute(
      [:oban_claude, :agent, :transition],
      %{system_time: System.system_time()},
      %{agent_id: data.id, from: from, to: to}
    )
  end

  # The registry value `ObanClaude.Agent.status/1` serves: the gated states
  # carry their payload so one atomic, messageless read answers both "where is
  # it" and "what is it waiting on" -- no torn status-then-pending reads.
  defp status_value(:awaiting_permission, data), do: {:awaiting_permission, data.pending_action}
  defp status_value(:waiting_for_user, data), do: {:waiting_for_user, data.pending_question}
  defp status_value(state, _data), do: state

  # The same silent-drop trap ObanClaude.Worker guards at compile time (#75):
  # atom keys would vanish in the string-keyed merge with each job's args.
  defp validate_string_keys!(key, args) when is_map(args) do
    case Enum.reject(Map.keys(args), &is_binary/1) do
      [] ->
        :ok

      bad ->
        raise ArgumentError,
              "ObanClaude.Agent config `#{key}` keys must be strings, got #{inspect(bad)}. " <>
                "Build the map with ObanClaude.Args.defaults/1 (atom keys in, string map out)."
    end
  end
end
