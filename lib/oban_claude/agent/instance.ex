defmodule ObanClaude.Agent.Instance do
  @moduledoc """
  One agent as one `:gen_statem` process, its asynchronous turns run as Oban
  jobs. Part of the experimental agent layer (see `ObanClaude.Agent`).

  The process never blocks on claude: a prompt enqueues an `ObanClaude.Worker`
  job and the machine parks in `:running` until the worker's callbacks route
  the outcome back as a `{:job_finished, payload}` cast (via
  `ObanClaude.Agent.job_finished/3`). States:

    * `:idle` -- ready for a prompt
    * `:running` -- an Oban job is in flight; further prompts are `:postpone`d
      and a `:state_timeout` watchdog guards against a turn that never reports
      back. A retryable failed attempt (`ObanClaude.Agent.job_retrying/3`)
      keeps the machine here and re-arms the watchdog, so `:job_timeout` should
      exceed one attempt's backoff plus its execution
    * `:waiting_for_user` -- the last turn asked a question (structured-output
      directive `"ask_user"`); the next prompt is treated as the answer and
      resumes the claude session
    * `:awaiting_permission` -- the last turn requested approval (directive
      `"request_permission"`); `approve` resumes the session with the action
      (under `:approved_args`, plus any per-approval `:args`, see below), `reject` records the denial and
      returns to `:idle`, and prompts are `:postpone`d until the gate clears.
      An approved turn that fails or hits the watchdog RE-GATES (same
      description, fresh id, `{:approval_incomplete, reason}` in history):
      the work was approved but not completed, and a re-approval resumes it
    * `:paused` -- lockdown via `:emergency_pause`, a correlated
      `ObanClaude.Agent.pause_after_turn/3`, or a host-requested
      `ObanClaude.Agent.quiesce/2`; every call is refused until an explicit
      `resume`

  Every state change atomically synchronizes the registry value -- the state
  atom, paired with the pending action or question in the gated states -- so
  `ObanClaude.Agent.status/1` reads both without messaging the process. Each
  change also emits `[:oban_claude, :agent, :transition]` telemetry with
  `%{agent_id, from, to}` metadata (state atoms). Turn transitions also carry
  the wrapper-owned generation, turn and arc identities, plus the optional
  application `correlation_id` and applied `config_revision`.

  Claude session ids are retained in bounded, host-named conversation arcs.
  Prompts that omit an arc use `"default"`, preserving the original one-agent,
  one-conversation behavior. Turn count and accumulated cost ride in the data
  (see `ObanClaude.Agent.info/1`).

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
    * `:session_arcs` -- optional `%{arc_id => session_id}` seed map for
      restoring provider conversations after this process restarts; default
      `%{}`
    * `:max_session_arcs` -- maximum retained provider handles; least-recently
      used inactive arcs are evicted as new ones arrive; default 32
    * `:config_revision` -- optional opaque non-empty string identifying the
      immutable host configuration applied to this process; default `nil`
    * `:enqueue_fun` -- a 2-arity `(args, meta) -> {:ok, term} | {:error, term}`
      override of the enqueue itself, for tests (no Oban, no DB)
  """

  @behaviour :gen_statem

  alias ClaudeWrapper.Result
  alias ObanClaude.Agent.{Execution, SessionArcs}

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
    max_history: 500,
    session_arcs: %{},
    max_session_arcs: 32,
    config_revision: nil
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

  # The pure half of action id generation, public only so a test can feed it
  # chosen entropy. Callers get ids from the gated states, never from here.
  @doc false
  @spec build_action_id(binary()) :: String.t()
  def build_action_id(entropy) when is_binary(entropy) do
    "act_" <> Base.url_encode64(entropy, padding: false)
  end

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init({agent_id, config}) do
    config = Map.merge(@defaults, Map.new(config))
    validate_string_keys!(:args, config.args)
    validate_string_keys!(:approved_args, config.approved_args)
    validate_config_revision!(config.config_revision)
    arcs = SessionArcs.new(config.session_arcs, config.max_session_arcs)

    data = %{
      id: agent_id,
      config: config,
      history: [],
      arcs: arcs,
      turns: 0,
      cost_usd: 0.0,
      pending_action: nil,
      pending_question: nil,
      gate_turn: nil,
      generation: identity_token(),
      current_turn: nil,
      deferred_pause: nil,
      pause_context: nil,
      # set while an approve continuation is in flight: an approved turn that
      # fails or times out RE-GATES (the action was approved but not
      # completed) instead of falling to :idle with the elevation lost
      in_flight_approval: nil,
      # the origin of the current conversational arc (:operator or :tick),
      # stamped into every enqueued job's meta so downstream consumers
      # (feeds, dashboards) can tell an operator's question from scheduled
      # work. Approve/reject continuations inherit the arc's origin.
      origin: :tick,
      active_arc_id: "default",
      continuation_request: :resume,
      fork_from_arc_id: nil,
      correlation_id: nil,
      last_continuation: nil
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
        {transition_context, new_data} = Map.pop(new_data, :transition_context, %{})
        new_data = sync_transition(state, next, new_data, transition_context)
        {:next_state, next, new_data}

      {:next_state, next, new_data, actions} when next != state ->
        {transition_context, new_data} = Map.pop(new_data, :transition_context, %{})
        new_data = sync_transition(state, next, new_data, transition_context)
        {:next_state, next, new_data, actions}

      other ->
        other
    end
  end

  # ---------------------------------------------------------------------------
  # any state: introspection and the emergency brake
  # ---------------------------------------------------------------------------

  defp process_event(state, {:call, {caller, _tag} = from}, {:job_started, meta}, data) do
    with :ok <- identity_status(data, meta),
         true <- state in [:running, :paused, :idle],
         {:ok, execution} <- Execution.start(data.current_turn, meta, caller) do
      turn = %{data.current_turn | execution: execution}
      data = %{data | current_turn: turn}
      emit_execution(data, :execution_started, %{})
      {:keep_state, data, [{:reply, from, {:ok, {self(), execution.reference}}}]}
    else
      false -> {:keep_state_and_data, [{:reply, from, {:error, :control_disabled}}]}
      {:error, reason} -> {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp process_event(
         _state,
         :info,
         {reference, %ClaudeWrapper.SessionObservation{} = observation},
         data
       )
       when is_reference(reference) do
    accept_observation(data, reference, observation)
  end

  defp process_event(_state, {:call, from}, :history, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, Enum.reverse(data.history)}}]}
  end

  defp process_event(state, {:call, from}, :info, data) do
    info = %{
      id: data.id,
      state: state,
      session_id: SessionArcs.session(data.arcs, "default"),
      session_arcs: SessionArcs.sessions(data.arcs),
      active_arc_id: data.active_arc_id,
      continuation: current_or_last_continuation(data),
      turns: data.turns,
      cost_usd: data.cost_usd,
      pending_action: data.pending_action,
      pending_question: data.pending_question,
      deferred_pause: data.deferred_pause,
      pause_context: data.pause_context,
      config_revision: data.config.config_revision
    }

    {:keep_state_and_data, [{:reply, from, {:ok, info}}]}
  end

  defp process_event(state, {:call, from}, {:pause_after_turn, reason, meta}, data) do
    case pause_identity_status(state, data, meta) do
      :already_latched ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      :ok
      when state in [:running, :waiting_for_user, :awaiting_permission] and
             is_nil(data.deferred_pause) ->
        deferred_pause = new_correlated_pause(state, data, reason, meta)

        data =
          data
          |> Map.put(:deferred_pause, deferred_pause)
          |> record({:pause_after_turn, reason})

        {:keep_state, data, [{:reply, from, :ok}]}

      :ok when state in [:running, :waiting_for_user, :awaiting_permission] ->
        {:keep_state, transfer_deferred_pause(data), [{:reply, from, :ok}]}

      :ok ->
        {:keep_state_and_data, [{:reply, from, {:error, {:invalid_state, state}}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp process_event(:paused, {:call, from}, {:quiesce, _reason}, data) do
    reply = if is_nil(data.current_turn), do: :already_paused, else: :draining
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  defp process_event(:idle, {:call, from}, {:quiesce, reason}, data) do
    data =
      data
      |> record({:quiesced, reason})
      |> put_transition_context(%{
        cause: :quiesce,
        pause_reason: reason,
        pause_action: :applied
      })

    reply = if is_nil(data.current_turn), do: :paused, else: :draining
    {:next_state, :paused, data, [{:reply, from, reply}]}
  end

  defp process_event(state, {:call, from}, {:quiesce, reason}, data)
       when state in [:running, :waiting_for_user, :awaiting_permission] do
    data =
      if is_nil(data.deferred_pause) do
        data
        |> Map.put(:deferred_pause, new_quiesce_pause(state, data, reason))
        |> record({:quiesce, reason})
      else
        data
      end

    {:keep_state, data, [{:reply, from, :armed}]}
  end

  # "Drops active scopes": a pending action, question, or in-flight approval
  # does not survive the lockdown; after resume the operator starts clean. An
  # actually in-flight turn retains bookkeeping ownership so its matching
  # outcome can still contribute history, spend, and a session without acting.
  defp process_event(state, :cast, :emergency_pause, data),
    do: process_event(state, :cast, {:emergency_pause, emergency_pause_context()}, data)

  defp process_event(state, :cast, {:emergency_pause, context}, data) when is_map(context) do
    apply_emergency_pause(state, data, context, [])
  end

  defp process_event(state, {:call, from}, {:emergency_pause, context}, data)
       when is_map(context) do
    apply_emergency_pause(state, data, context, [{:reply, from, :ok}])
  end

  # ---------------------------------------------------------------------------
  # :paused -- lockdown until an explicit resume
  # ---------------------------------------------------------------------------

  defp process_event(:paused, {:call, from}, :resume, data) do
    data =
      data
      |> put_pause_transition(:cleared)
      |> Map.put(:deferred_pause, nil)

    {:next_state, :idle, data, [{:reply, from, :resumed}]}
  end

  # A turn that was in flight when the pause hit: absorb the payload (history,
  # session id, spend) but stay locked and ignore its directives.
  defp process_event(:paused, :cast, {:job_finished, payload, meta}, data) do
    correlated_finish(:paused, data, payload, meta)
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
    start_turn(from, text, prompt_data(data, opts, "default"))
  end

  defp process_event(:idle, :cast, {:user_prompt, text, opts}, data) do
    start_turn(nil, text, prompt_data(data, opts, "default"))
  end

  # A turn that completed after pause/resume, but before another prompt took
  # ownership, may still contribute bookkeeping without controlling state.
  defp process_event(:idle, :cast, {:job_finished, payload, meta}, data) do
    correlated_finish(:idle, data, payload, meta)
  end

  # ---------------------------------------------------------------------------
  # :running
  # ---------------------------------------------------------------------------

  # Both the call and the cast form postpone: a called prompt blocks its
  # caller until the turn finishes, a cast one just queues.
  defp process_event(:running, _type, {:user_prompt, _text, _opts}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  defp process_event(:running, :cast, {:job_finished, payload, meta}, data) do
    correlated_finish(:running, data, payload, meta)
  end

  # A retryable attempt failed and Oban will re-run the job: the turn is still
  # logically in flight, so stay :running, log it, and re-arm the watchdog to
  # cover the retry's backoff plus its execution.
  defp process_event(:running, :cast, {:job_retrying, retry, meta}, data) do
    correlated_retry(data, retry, meta)
  end

  defp process_event(:running, :state_timeout, {:job_watchdog, identity}, data) do
    if owns_identity?(data, identity) do
      Logger.warning("ObanClaude.Agent #{data.id}: job watchdog fired")

      data
      |> complete_watchdog()
      |> retire_turn()
      |> record(:watchdog_timeout)
      |> regate_or_idle(:watchdog_timeout)
    else
      {:keep_state, reject_callback(data, :watchdog, %{}, :stale_turn)}
    end
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

  defp process_event(
         :waiting_for_user,
         _type,
         {:user_prompt, _text, %{fork_from: fork_from}},
         _data
       )
       when is_binary(fork_from) do
    {:keep_state_and_data, [:postpone]}
  end

  defp process_event(:waiting_for_user, {:call, from}, {:user_prompt, answer, opts}, data) do
    question = data.pending_question

    candidate =
      %{data | pending_question: nil, gate_turn: nil}
      |> prompt_data(opts, data.active_arc_id)
      |> put_pause_transition(:continued, %{gate_outcome: :answered, question: question})

    start_turn(from, answer, candidate, %{}, :waiting_for_user, data)
  end

  defp process_event(:waiting_for_user, :cast, {:user_prompt, answer, opts}, data) do
    question = data.pending_question

    candidate =
      %{data | pending_question: nil, gate_turn: nil}
      |> prompt_data(opts, data.active_arc_id)
      |> put_pause_transition(:continued, %{gate_outcome: :answered, question: question})

    start_turn(nil, answer, candidate, %{}, :waiting_for_user, data)
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

  # `args` is the caller's override for this one continuation, merged over
  # the standing :approved_args. A bad map is refused and the gate stays open:
  # it arrives in a call, and a call must never raise inside the agent.
  defp process_event(:awaiting_permission, {:call, from}, {:approve_action, id, args}, data) do
    case {data.pending_action, invalid_keys(args)} do
      {%{id: ^id}, [_bad | _rest] = keys} ->
        {:keep_state_and_data, [{:reply, from, {:error, {:invalid_args, keys}}}]}

      {%{id: ^id, description: description}, []} ->
        prompt = "Approved: #{description}. Proceed."

        candidate = %{
          data
          | pending_action: nil,
            gate_turn: nil,
            in_flight_approval: %{description: description}
        }

        candidate =
          put_pause_transition(candidate, :continued, %{
            gate_outcome: :approved,
            action_id: id
          })

        start_turn(
          from,
          prompt,
          candidate,
          Map.merge(candidate.config.approved_args, args),
          :awaiting_permission,
          data
        )

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :unknown_action}}]}
    end
  end

  defp process_event(:awaiting_permission, {:call, from}, {:reject_action, id, reason}, data) do
    case data.pending_action do
      %{id: ^id, description: description} ->
        Logger.info("ObanClaude.Agent #{data.id}: action #{id} rejected: #{reason}")

        data = %{
          record(data, {:denied, id, reason})
          | pending_action: nil,
            gate_turn: nil
        }

        case data.deferred_pause do
          nil ->
            {:next_state, :idle, data, [{:reply, from, :rejected}]}

          _deferred_pause ->
            data =
              put_pause_transition(data, :applied, %{
                gate_outcome: :rejected,
                action_id: id,
                action: description,
                rejection_reason: reason
              })

            {:next_state, :paused, data, [{:reply, from, :rejected}]}
        end

      _ ->
        {:keep_state_and_data, [{:reply, from, {:error, :unknown_action}}]}
    end
  end

  # Correlated callbacks are always inspected, even in a gated state, so a
  # rejected delivery leaves a bounded diagnostic instead of disappearing.
  defp process_event(state, :cast, {:job_finished, payload, meta}, data) do
    correlated_finish(state, data, payload, meta)
  end

  defp process_event(state, :cast, {:job_retrying, retry, meta}, data) do
    correlated_retry(state, data, retry, meta)
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

  # Enqueue one Claude turn and park in :running under the watchdog. The
  # selected arc supplies the only resume handle that may be used. `from` is
  # nil on the cast path (no caller to reply to).
  defp start_turn(
         from,
         prompt,
         data,
         extra_args \\ %{},
         fallback_state \\ :idle,
         fallback_data \\ nil
       ) do
    fallback_data = fallback_data || data
    turn_id = identity_token()

    base_args =
      data.config.args
      |> Map.merge(extra_args)
      |> Map.put("prompt", prompt)

    case prepare_turn(data, base_args, turn_id) do
      {:ok, continuation, job} ->
        current_turn = %{
          id: turn_id,
          job_id: if(is_struct(job, Oban.Job), do: job.id),
          execution: nil,
          retry_watermark: 0,
          continuation: continuation
        }

        data =
          data
          |> Map.put(:current_turn, current_turn)
          |> Map.put(:last_continuation, continuation)
          |> transfer_deferred_pause()

        watchdog = watchdog(data)

        {:next_state, :running, record(data, {:prompt, prompt}),
         reply(from, :processing) ++ [watchdog]}

      {:error, reason} ->
        failed = continuation_failure(data, reason, :enqueue_failed, turn_id)
        emit_completion(data, failed)

        fallback_data =
          fallback_data
          |> Map.delete(:transition_context)
          |> Map.put(:last_continuation, failed)

        {:next_state, fallback_state, record(fallback_data, {:enqueue_failed, reason}),
         reply(from, {:error, {:enqueue_failed, reason}})}
    end
  end

  defp prepare_turn(data, base_args, turn_id) do
    with {:ok, continuation, args} <- continuation_args(data, base_args),
         continuation <- identify_continuation(data, continuation, turn_id),
         {:ok, job} <- enqueue(data, args, turn_id, continuation) do
      {:ok, continuation, job}
    else
      {:error, reason} -> {:error, reason}
      _unexpected -> {:error, :unexpected_turn_start_result}
    end
  rescue
    exception ->
      Logger.error(
        "ObanClaude.Agent #{data.id}: turn start raised #{inspect(exception.__struct__)}"
      )

      {:error, :turn_start_exception}
  catch
    :throw, _reason ->
      Logger.error("ObanClaude.Agent #{data.id}: turn start threw")
      {:error, :turn_start_throw}

    :exit, _reason ->
      Logger.error("ObanClaude.Agent #{data.id}: turn start exited")
      {:error, :turn_start_exit}
  end

  defp reply(nil, _message), do: []
  defp reply(from, message), do: [{:reply, from, message}]

  # Freshness is applied at delivery time, so postponed prompts clear only
  # their selected arc immediately before enqueue.
  defp prompt_data(data, opts, fallback_arc_id) do
    arc_id = Map.get(opts, :arc_id) || fallback_arc_id
    request = Map.fetch!(opts, :session)

    arcs =
      case request do
        mode when mode in [:fresh, :fresh_fallback] -> SessionArcs.clear(data.arcs, arc_id)
        :resume -> SessionArcs.touch(data.arcs, arc_id)
      end

    arcs =
      case Map.get(opts, :fork_from) do
        fork_from when is_binary(fork_from) -> SessionArcs.touch(arcs, fork_from)
        nil -> arcs
      end

    %{
      data
      | arcs: arcs,
        active_arc_id: arc_id,
        continuation_request: request,
        fork_from_arc_id: Map.get(opts, :fork_from),
        origin: Map.get(opts, :origin, :operator),
        correlation_id: Map.get(opts, :correlation_id)
    }
  end

  # Route on the finished turn's structured-output directive. A completed
  # approve continuation resolves its approval, whatever it returns.
  defp finish_turn(data, {:ok, %Result{} = result} = payload) do
    data = %{complete_turn(data, payload) | in_flight_approval: nil}
    data = retire_turn(data)

    case directive(result) do
      {:ask_user, question} ->
        data =
          data
          |> Map.put(:pending_question, question)
          |> Map.put(:gate_turn, data.last_continuation)
          |> put_pause_transition(:continued, %{
            gate_outcome: :opened,
            question: question
          })

        {:next_state, :waiting_for_user, data}

      {:request_permission, description} ->
        action = %{id: action_id(), description: description}

        data =
          data
          |> Map.put(:pending_action, action)
          |> Map.put(:gate_turn, data.last_continuation)
          |> put_pause_transition(:continued, %{
            gate_outcome: :opened,
            action_id: action.id
          })

        {:next_state, :awaiting_permission, data}

      :none ->
        pause_or_idle(data)
    end
  end

  defp finish_turn(data, {:error, verdict, _payload} = failure) do
    data = data |> complete_turn(failure) |> retire_turn()
    regate_or_idle(data, verdict)
  end

  # An approved turn that did not complete (failed verdict, watchdog) re-gates:
  # the action was approved but the work is not done, so it goes back to
  # :awaiting_permission (same description, fresh id) rather than silently
  # dropping the elevation on the floor. The captured session id means a
  # re-approval resumes the interrupted work. A deferred pause remains latched
  # while the gate is open; an unapproved turn applies it immediately.
  defp regate_or_idle(%{in_flight_approval: %{description: description}} = data, reason) do
    action = %{id: action_id(), description: description}

    data =
      data
      |> record({:approval_incomplete, reason})
      |> Map.put(:pending_action, action)
      |> Map.put(:gate_turn, data.last_continuation)
      |> Map.put(:in_flight_approval, nil)
      |> put_pause_transition(:continued, %{
        gate_outcome: :incomplete,
        action_id: action.id
      })

    {:next_state, :awaiting_permission, data}
  end

  defp regate_or_idle(%{in_flight_approval: nil} = data, _reason) do
    pause_or_idle(data)
  end

  defp pause_or_idle(%{deferred_pause: nil} = data), do: {:next_state, :idle, data}

  defp pause_or_idle(data) do
    {:next_state, :paused, put_pause_transition(data, :applied)}
  end

  # Fold a turn's payload into the data: a history entry (the decoded
  # structured output when the turn produced one, the plain text otherwise),
  # the turn/spend counters, and the claude session id when the payload
  # carries one (a rail-stop %Error{} does too).
  defp absorb(data, {:ok, %Result{} = result}) do
    data
    |> record({:result, ObanClaude.structured(result) || result.result})
    |> count_turn(result.cost_usd)
    |> keep_session(result.session_id, data.current_turn.continuation.arc_id)
  end

  defp absorb(data, {:error, verdict, payload}) do
    data
    |> record({:job_error, verdict})
    |> count_turn(ObanClaude.cost_usd(payload))
    |> keep_session(ObanClaude.session_id(payload), data.current_turn.continuation.arc_id)
  end

  defp count_turn(data, cost) do
    %{data | turns: data.turns + 1, cost_usd: data.cost_usd + (cost || 0.0)}
  end

  defp keep_session(data, nil, _arc_id), do: data

  defp keep_session(data, session_id, arc_id) do
    %{data | arcs: SessionArcs.put(data.arcs, arc_id, session_id)}
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

  defp enqueue(%{config: %{enqueue_fun: fun}} = data, args, turn_id, continuation)
       when is_function(fun, 2) do
    fun.(args, job_meta(data, turn_id, continuation))
  end

  defp enqueue(data, args, turn_id, continuation) do
    meta = job_meta(data, turn_id, continuation)
    changeset = data.config.worker.new(args, meta: meta)

    with :ok <- reject_replacement(changeset) do
      conf = Oban.config(data.config.oban)

      Oban.Repo.transaction(
        conf,
        fn -> insert_and_validate(data.config.oban, changeset, meta, conf) end,
        retry: false
      )
    end
  end

  defp insert_and_validate(oban, changeset, meta, conf) do
    with {:ok, %Oban.Job{} = job} <- Oban.insert(oban, changeset),
         :ok <- validate_inserted_job(job, meta) do
      job
    else
      {:error, reason} -> Oban.Repo.rollback(conf, reason)
    end
  end

  # Job meta identifies the turn for downstream telemetry consumers: whose
  # turn it is, and whether the conversational arc began with an operator
  # prompt or a scheduled tick.
  defp job_meta(data, turn_id, continuation) do
    %{
      "agent_id" => data.id,
      "agent_generation" => data.generation,
      "agent_turn_id" => turn_id,
      "origin" => to_string(data.origin),
      "arc_id" => continuation.arc_id,
      "continuation_decision" => to_string(continuation.decision),
      "continuation_reason" => to_string(continuation.reason)
    }
    |> maybe_put_meta("config_revision", data.config.config_revision)
    |> maybe_put_meta("correlation_id", continuation.correlation_id)
    |> maybe_put_meta("session_id", continuation.session_id)
    |> maybe_put_meta("fork_from_arc_id", continuation.fork_from_arc_id)
  end

  defp reject_replacement(changeset) do
    case Ecto.Changeset.get_field(changeset, :replace) do
      nil -> :ok
      [] -> :ok
      _rules -> {:error, :agent_job_replacement_not_supported}
    end
  end

  defp validate_inserted_job(%Oban.Job{conflict?: true}, _meta),
    do: {:error, :agent_job_conflict}

  defp validate_inserted_job(%Oban.Job{} = job, meta) do
    cond do
      not persisted_job?(job) -> {:error, :agent_job_not_persisted}
      same_identity?(job.meta, meta) -> :ok
      true -> {:error, :agent_job_identity_mismatch}
    end
  end

  # Oban's public type promises an id, but an engine can violate that contract.
  # Keep the runtime boundary defensive because an unpersisted uniqueness
  # candidate must never become the current logical turn.
  @dialyzer {:nowarn_function, persisted_job?: 1}
  defp persisted_job?(job), do: is_integer(Map.get(job, :id))

  defp correlated_finish(state, data, payload, meta) do
    case callback_status(data, meta) do
      :ok when state == :running ->
        finish_turn(data, payload)

      :ok when state in [:paused, :idle] ->
        data = data |> complete_turn(payload) |> retire_turn()
        {:keep_state, data}

      :ok ->
        {:keep_state, reject_callback(data, :finished, meta, {:invalid_state, state})}

      {:error, reason} ->
        {:keep_state, reject_callback(data, :finished, meta, reason)}
    end
  end

  defp correlated_retry(data, retry, meta), do: correlated_retry(:running, data, retry, meta)

  defp correlated_retry(state, data, retry, meta) do
    with :ok <- callback_status(data, meta),
         :running <- state,
         {:ok, watermark} <- retry_watermark(retry, meta),
         true <- watermark > data.current_turn.retry_watermark do
      current_turn = %{
        data.current_turn
        | retry_watermark: watermark,
          execution: Execution.close(data.current_turn.execution)
      }

      data = %{record(data, {:retrying, retry}) | current_turn: current_turn}
      {:keep_state, data, [watchdog(data)]}
    else
      {:error, reason} ->
        {:keep_state, reject_callback(data, :retrying, meta, reason)}

      false ->
        {:keep_state, reject_callback(data, :retrying, meta, :retry_replayed)}

      other_state when is_atom(other_state) ->
        {:keep_state, reject_callback(data, :retrying, meta, {:control_disabled, other_state})}
    end
  end

  defp callback_status(data, meta) do
    with :ok <- identity_status(data, meta),
         do: Execution.callback_status(data.current_turn, meta)
  end

  defp accept_observation(%{current_turn: nil} = data, _reference, _observation),
    do: {:keep_state, data}

  defp accept_observation(data, reference, observation) do
    turn = data.current_turn

    case Execution.observe(turn.execution, reference, observation) do
      {:ok, execution} -> retain_observation(data, execution)
      _ignored -> {:keep_state, data}
    end
  end

  defp retain_observation(data, execution) do
    turn = data.current_turn
    continuation = turn.continuation

    if continuation.fork_from_arc_id && execution.session_id == continuation.session_id do
      {:keep_state, data}
    else
      turn = %{turn | execution: execution}
      arcs = SessionArcs.put(data.arcs, continuation.arc_id, execution.session_id)
      data = %{data | current_turn: turn, arcs: arcs}
      emit_execution(data, :session_observed, Map.take(execution, [:session_id, :source]))
      {:keep_state, data}
    end
  end

  defp emit_execution(data, event, extra) do
    continuation = data.current_turn.continuation

    metadata =
      %{
        agent_id: data.id,
        agent_generation: data.generation,
        agent_turn_id: data.current_turn.id,
        arc_id: continuation.arc_id,
        correlation_id: continuation.correlation_id,
        continuation_decision: continuation.decision,
        continuation_reason: continuation.reason
      }
      |> Map.merge(Execution.metadata(data.current_turn.execution))
      |> Map.merge(extra)
      |> maybe_put_meta(:config_revision, data.config.config_revision)

    :telemetry.execute(
      [:oban_claude, :agent, event],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp retry_watermark(%{attempt: attempt}, meta) when is_integer(attempt) and attempt > 0 do
    snoozed = Map.get(meta, "snoozed", 0)

    if is_integer(snoozed) and snoozed >= 0 do
      {:ok, attempt + snoozed}
    else
      {:error, :invalid_retry_watermark}
    end
  end

  defp retry_watermark(_retry, _meta), do: {:error, :invalid_retry_watermark}

  defp identity_status(data, meta) when is_map(meta) do
    generation = Map.get(meta, "agent_generation")
    turn_id = Map.get(meta, "agent_turn_id")

    cond do
      Map.get(meta, "agent_id") !== data.id ->
        {:error, :agent_id_mismatch}

      not valid_identity_token?(generation) or not valid_identity_token?(turn_id) ->
        {:error, :malformed_identity}

      generation != data.generation ->
        {:error, :foreign_generation}

      is_nil(data.current_turn) ->
        {:error, :retired_turn}

      turn_id != data.current_turn.id ->
        {:error, :stale_turn}

      true ->
        :ok
    end
  end

  defp identity_status(_data, _meta), do: {:error, :malformed_identity}

  defp pause_identity_status(state, %{deferred_pause: deferred_pause} = data, meta)
       when not is_nil(deferred_pause) do
    if deferred_pause_identity?(data, deferred_pause, meta) do
      :already_latched
    else
      pause_unlatched_identity_status(state, data, meta)
    end
  end

  defp pause_identity_status(state, data, meta),
    do: pause_unlatched_identity_status(state, data, meta)

  defp pause_unlatched_identity_status(state, data, meta) do
    case identity_status(data, meta) do
      {:error, :retired_turn} when state in [:waiting_for_user, :awaiting_permission] ->
        completed_identity_status(data, meta)

      status ->
        status
    end
  end

  defp completed_identity_status(data, meta) when is_map(meta) do
    generation = Map.get(meta, "agent_generation")
    turn_id = Map.get(meta, "agent_turn_id")
    completed = data.gate_turn

    cond do
      Map.get(meta, "agent_id") !== data.id ->
        {:error, :agent_id_mismatch}

      not valid_identity_token?(generation) or not valid_identity_token?(turn_id) ->
        {:error, :malformed_identity}

      generation != data.generation ->
        {:error, :foreign_generation}

      is_nil(completed) ->
        {:error, :retired_turn}

      turn_id != completed.agent_turn_id ->
        {:error, :stale_turn}

      true ->
        :ok
    end
  end

  defp deferred_pause_identity?(data, deferred_pause, meta) when is_map(meta) do
    source? =
      Map.get(meta, "agent_generation") === deferred_pause.source_generation and
        Map.get(meta, "agent_turn_id") === deferred_pause.source_turn_id

    owner? =
      Map.get(meta, "agent_generation") === deferred_pause.owner_generation and
        Map.get(meta, "agent_turn_id") === deferred_pause.owner_turn_id

    Map.get(meta, "agent_id") === data.id and (source? or owner?)
  end

  defp deferred_pause_identity?(_data, _deferred_pause, _meta), do: false

  defp new_correlated_pause(state, data, reason, meta) do
    continuation = pause_owner_continuation(state, data)

    deferred_pause(
      :pause_after_turn,
      reason,
      Map.fetch!(meta, "agent_generation"),
      Map.fetch!(meta, "agent_turn_id"),
      continuation
    )
  end

  defp new_quiesce_pause(state, data, reason) do
    continuation = pause_owner_continuation(state, data)

    deferred_pause(
      :quiesce,
      reason,
      continuation.agent_generation,
      continuation.agent_turn_id,
      continuation
    )
  end

  defp deferred_pause(cause, reason, source_generation, source_turn_id, continuation) do
    %{
      cause: cause,
      reason: reason,
      source_generation: source_generation,
      source_turn_id: source_turn_id,
      owner_generation: continuation.agent_generation,
      owner_turn_id: continuation.agent_turn_id,
      owner_arc_id: continuation.arc_id,
      owner_correlation_id: continuation.correlation_id
    }
  end

  defp pause_owner_continuation(:running, data), do: data.current_turn.continuation

  defp pause_owner_continuation(state, data)
       when state in [:waiting_for_user, :awaiting_permission],
       do: data.gate_turn

  defp transfer_deferred_pause(%{deferred_pause: nil} = data), do: data

  defp transfer_deferred_pause(%{current_turn: nil} = data), do: data

  defp transfer_deferred_pause(data) do
    continuation = data.current_turn.continuation

    deferred_pause = %{
      data.deferred_pause
      | owner_generation: data.generation,
        owner_turn_id: data.current_turn.id,
        owner_arc_id: continuation.arc_id,
        owner_correlation_id: continuation.correlation_id
    }

    %{data | deferred_pause: deferred_pause}
  end

  defp same_identity?(left, right) do
    Enum.all?(~w(agent_id agent_generation agent_turn_id), fn key ->
      Map.get(left, key) === Map.get(right, key)
    end)
  end

  defp valid_identity_token?(token), do: is_binary(token) and byte_size(token) > 0

  defp retire_turn(data), do: %{data | current_turn: nil}

  defp watchdog(data) do
    identity = %{generation: data.generation, turn_id: data.current_turn.id}
    {:state_timeout, data.config.job_timeout, {:job_watchdog, identity}}
  end

  defp owns_identity?(%{current_turn: nil}, _identity), do: false

  defp owns_identity?(data, %{generation: generation, turn_id: turn_id}) do
    generation == data.generation and turn_id == data.current_turn.id
  end

  defp owns_identity?(_data, _identity), do: false

  defp reject_callback(data, kind, meta, reason) do
    diagnostic = %{
      generation: bounded_identity(Map.get(meta, "agent_generation")),
      turn_id: bounded_identity(Map.get(meta, "agent_turn_id"))
    }

    :telemetry.execute(
      [:oban_claude, :agent, :callback_rejected],
      %{system_time: System.system_time()},
      %{agent_id: data.id, kind: kind, reason: reason, identity: diagnostic}
    )

    record(data, {:callback_rejected, kind, reason, diagnostic})
  end

  defp bounded_identity(value) when is_binary(value),
    do: binary_part(value, 0, min(128, byte_size(value)))

  defp bounded_identity(value) do
    value
    |> inspect(limit: 5, printable_limit: 128)
    |> bounded_identity()
  end

  defp identity_token do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp continuation_args(data, args) do
    args = Map.drop(args, ["resume", "session_id", "fork_session"])
    arc_id = data.active_arc_id

    case data.fork_from_arc_id do
      fork_from when is_binary(fork_from) ->
        case SessionArcs.session(data.arcs, fork_from) do
          nil ->
            {:error, {:unknown_arc, fork_from}}

          session_id ->
            continuation =
              continuation(data, :resume, :fork, session_id, fork_from_arc_id: fork_from)

            args = args |> Map.put("resume", session_id) |> Map.put("fork_session", true)
            {:ok, continuation, args}
        end

      nil ->
        session_id = SessionArcs.session(data.arcs, arc_id)

        request = effective_continuation_request(data.continuation_request, session_id)

        case {request, session_id} do
          {:resume, nil} ->
            {:ok, continuation(data, :fresh, :no_session, nil), args}

          {:resume, session_id} ->
            {:ok, continuation(data, :resume, :session_available, session_id),
             Map.put(args, "resume", session_id)}

          {:fresh, nil} ->
            {:ok, continuation(data, :fresh, :requested, nil), args}

          {:fresh_fallback, nil} ->
            {:ok, continuation(data, :fresh_fallback, :resume_failed, nil), args}
        end
    end
  end

  defp effective_continuation_request(request, session_id)
       when request in [:fresh, :fresh_fallback] and is_binary(session_id),
       do: :resume

  defp effective_continuation_request(request, _session_id), do: request

  defp continuation(data, decision, reason, session_id, opts \\ []) do
    %{
      arc_id: data.active_arc_id,
      decision: decision,
      reason: reason,
      session_id: session_id,
      result_session_id: nil,
      fork_from_arc_id: Keyword.get(opts, :fork_from_arc_id),
      origin: data.origin,
      correlation_id: data.correlation_id,
      outcome: :running,
      outcome_reason: nil
    }
  end

  defp continuation_failure(data, reason, outcome, turn_id) do
    session_id = SessionArcs.session(data.arcs, data.active_arc_id)

    data
    |> continuation(
      failure_decision(data, session_id),
      failure_reason(data, session_id),
      session_id,
      fork_from_arc_id: data.fork_from_arc_id
    )
    |> then(&identify_continuation(data, &1, turn_id))
    |> Map.merge(%{outcome: outcome, outcome_reason: reason, execution_state: :not_started})
  end

  defp identify_continuation(data, continuation, turn_id) do
    Map.merge(continuation, %{
      agent_generation: data.generation,
      agent_turn_id: turn_id
    })
  end

  defp failure_decision(%{fork_from_arc_id: fork_from}, _session_id) when is_binary(fork_from),
    do: :resume

  defp failure_decision(%{continuation_request: :fresh_fallback}, _session_id),
    do: :fresh_fallback

  defp failure_decision(%{continuation_request: :fresh}, _session_id), do: :fresh
  defp failure_decision(_data, nil), do: :fresh
  defp failure_decision(_data, _session_id), do: :resume

  defp failure_reason(%{fork_from_arc_id: fork_from}, _session_id) when is_binary(fork_from),
    do: :fork

  defp failure_reason(%{continuation_request: :fresh_fallback}, _session_id), do: :resume_failed
  defp failure_reason(%{continuation_request: :fresh}, _session_id), do: :requested
  defp failure_reason(_data, nil), do: :no_session
  defp failure_reason(_data, _session_id), do: :session_available

  defp complete_turn(data, payload) do
    previous_arcs = data.arcs
    data = data |> absorb(payload) |> retain_completed_session(payload, previous_arcs)
    continuation = completed_continuation(data, payload)
    continuation = Map.merge(continuation, Execution.metadata(data.current_turn.execution))
    emit_completion(data, continuation)
    %{data | last_continuation: continuation}
  end

  defp retain_completed_session(data, payload, previous_arcs) do
    continuation = data.current_turn.continuation

    case completion_outcome(payload) do
      {:session_rejected, _reason} ->
        rejected_arc = continuation.fork_from_arc_id || continuation.arc_id
        %{data | arcs: SessionArcs.clear(previous_arcs, rejected_arc)}

      {:failed, _reason} when is_binary(continuation.fork_from_arc_id) ->
        data = %{data | arcs: previous_arcs}
        restore_observed_session(data, data.current_turn.execution)

      _other ->
        restore_observed_session(data, data.current_turn.execution)
    end
  end

  defp restore_observed_session(data, %{session_id: id}) when is_binary(id) do
    arc_id = data.current_turn.continuation.arc_id
    %{data | arcs: SessionArcs.put(data.arcs, arc_id, id)}
  end

  defp restore_observed_session(data, _execution), do: data

  defp complete_watchdog(data) do
    continuation =
      data.current_turn.continuation
      |> Map.merge(%{
        outcome: :timed_out,
        outcome_reason: :watchdog_timeout,
        result_session_id: SessionArcs.session(data.arcs, data.current_turn.continuation.arc_id)
      })

    continuation =
      Map.merge(continuation, watchdog_execution_metadata(data.current_turn.execution))

    emit_completion(data, continuation)
    %{data | last_continuation: continuation}
  end

  defp watchdog_execution_metadata(nil), do: %{execution_state: :not_started}
  defp watchdog_execution_metadata(execution), do: Execution.metadata(execution)

  defp completed_continuation(data, payload) do
    {outcome, reason} = completion_outcome(payload)
    arc_id = data.current_turn.continuation.arc_id

    data.current_turn.continuation
    |> Map.merge(%{
      outcome: outcome,
      outcome_reason: reason,
      result_session_id: SessionArcs.session(data.arcs, arc_id)
    })
  end

  defp completion_outcome({:ok, %Result{}}), do: {:completed, nil}

  defp completion_outcome({:error, verdict, payload}) do
    if session_rejected?(verdict) or session_rejected?(payload) do
      {:session_rejected, verdict}
    else
      {:failed, verdict}
    end
  end

  defp session_rejected?(value)
       when value in [:session_not_found, :invalid_session, :unknown_session, :session_rejected],
       do: true

  defp session_rejected?({tag, value}) when tag in [:cancel, :error],
    do: session_rejected?(value)

  defp session_rejected?(%{reason: reason}), do: session_rejected?(reason)
  defp session_rejected?(_other), do: false

  defp emit_completion(data, continuation) do
    :telemetry.execute(
      [:oban_claude, :agent, :turn_completed],
      %{system_time: System.system_time()},
      %{
        agent_id: data.id,
        agent_generation: continuation.agent_generation,
        agent_turn_id: continuation.agent_turn_id,
        arc_id: continuation.arc_id,
        correlation_id: continuation.correlation_id,
        session_id: completion_session_id(continuation),
        continuation_decision: continuation.decision,
        continuation_reason: continuation.reason,
        outcome: continuation.outcome,
        outcome_reason: continuation.outcome_reason
      }
      |> Map.merge(
        Map.take(continuation, [:execution_state, :job_id, :job_attempt, :job_snoozed])
      )
      |> Map.merge(rejection_metadata(continuation))
      |> maybe_put_meta(:fork_from_arc_id, continuation.fork_from_arc_id)
      |> maybe_put_meta(:config_revision, data.config.config_revision)
    )
  end

  defp completion_session_id(%{outcome: :session_rejected, fork_from_arc_id: nil}), do: nil

  defp completion_session_id(%{fork_from_arc_id: id} = continuation) when is_binary(id),
    do: continuation.result_session_id

  defp completion_session_id(continuation),
    do: continuation.result_session_id || continuation.session_id

  defp rejection_metadata(%{outcome: :session_rejected} = continuation) do
    %{
      rejected_arc_id: continuation.fork_from_arc_id || continuation.arc_id,
      rejected_session_id: continuation.session_id || continuation.result_session_id
    }
  end

  defp rejection_metadata(_continuation), do: %{}

  defp current_or_last_continuation(%{current_turn: turn}) when not is_nil(turn),
    do: Execution.public_continuation(turn.continuation, turn.execution)

  defp current_or_last_continuation(%{
         last_continuation: %{execution_state: :started} = continuation
       }),
       do: Map.put(continuation, :session_id, completion_session_id(continuation))

  defp current_or_last_continuation(data), do: data.last_continuation

  defp maybe_put_meta(meta, _key, nil), do: meta
  defp maybe_put_meta(meta, key, value), do: Map.put(meta, key, value)

  # Random, not System.unique_integer/1: that counter restarts with the VM, so
  # after a restart a durable downstream gate record could share an id with a
  # fresh live gate (#131). 16 random bytes make a collision negligible.
  defp action_id, do: build_action_id(:crypto.strong_rand_bytes(16))

  defp record(data, entry) do
    %{data | history: Enum.take([entry | data.history], data.config.max_history)}
  end

  defp sync_transition(from, to, data, context) do
    data = retain_pause_context(from, to, data, context)

    Registry.update_value(@registry, data.id, fn _old -> status_value(to, data) end)

    :telemetry.execute(
      [:oban_claude, :agent, :transition],
      %{system_time: System.system_time()},
      transition_meta(from, to, data, context)
    )

    data
  end

  defp retain_pause_context(_from, :paused, data, context),
    do: %{data | pause_context: context}

  defp retain_pause_context(:paused, _to, data, _context),
    do: %{data | pause_context: nil}

  defp retain_pause_context(_from, _to, data, _context), do: data

  defp transition_meta(from, to, data, context) do
    continuation =
      cond do
        to == :running -> current_or_last_continuation(data)
        from == :running -> current_or_last_continuation(data)
        true -> nil
      end

    %{agent_id: data.id, from: from, to: to}
    |> Map.merge(context)
    |> put_continuation_identity(continuation)
    |> maybe_put_meta(:config_revision, data.config.config_revision)
  end

  defp put_continuation_identity(meta, nil), do: meta

  defp put_continuation_identity(meta, continuation) do
    meta
    |> Map.put(:agent_generation, continuation.agent_generation)
    |> Map.put(:agent_turn_id, continuation.agent_turn_id)
    |> Map.put(:arc_id, continuation.arc_id)
    |> maybe_put_meta(:correlation_id, continuation.correlation_id)
  end

  defp put_pause_transition(data, action, extra \\ %{})

  defp put_pause_transition(%{deferred_pause: nil} = data, _action, _extra), do: data

  defp put_pause_transition(data, action, extra) do
    data =
      if action == :applied do
        record(data, {:paused_after_turn, data.deferred_pause.reason})
      else
        data
      end

    context =
      extra
      |> Map.merge(%{
        cause: data.deferred_pause.cause,
        pause_reason: data.deferred_pause.reason,
        pause_action: action,
        agent_generation: data.deferred_pause.owner_generation,
        agent_turn_id: data.deferred_pause.owner_turn_id,
        arc_id: data.deferred_pause.owner_arc_id
      })
      |> maybe_put_meta(:correlation_id, data.deferred_pause.owner_correlation_id)

    put_transition_context(data, context)
  end

  defp put_transition_context(data, context) do
    Map.put(data, :transition_context, context)
  end

  defp apply_emergency_pause(state, data, context, actions) when state != :paused do
    data = %{
      record(data, {:paused_from, state})
      | pending_action: nil,
        pending_question: nil,
        gate_turn: nil,
        in_flight_approval: nil,
        deferred_pause: nil
    }

    data = put_transition_context(data, emergency_pause_context(context))

    {:next_state, :paused, data, actions}
  end

  defp apply_emergency_pause(:paused, data, context, actions) do
    data = %{
      data
      | pending_action: nil,
        pending_question: nil,
        gate_turn: nil,
        in_flight_approval: nil,
        deferred_pause: nil,
        pause_context: emergency_pause_context(context)
    }

    {:keep_state, data, actions}
  end

  defp emergency_pause_context do
    %{
      cause: :emergency_pause,
      pause_reason: :emergency_pause,
      pause_action: :applied
    }
  end

  defp emergency_pause_context(context) do
    context = normalize_pause_context_keys(context)

    context
    |> Map.put(:cause, Map.get(context, :cause) || :emergency_pause)
    |> Map.put(
      :pause_reason,
      Map.get(context, :pause_reason) || Map.get(context, :reason) || :emergency_pause
    )
    |> Map.put(:pause_action, :applied)
  end

  @pause_context_keys %{
    "cause" => :cause,
    "reason" => :reason,
    "pause_reason" => :pause_reason,
    "pause_action" => :pause_action,
    "agent_generation" => :agent_generation,
    "agent_turn_id" => :agent_turn_id,
    "arc_id" => :arc_id,
    "correlation_id" => :correlation_id
  }
  defp normalize_pause_context_keys(context) do
    Map.new(context, fn {key, value} ->
      {Map.get(@pause_context_keys, key, key), value}
    end)
  end

  # The registry value `ObanClaude.Agent.status/1` serves: the gated states
  # carry their payload so one atomic, messageless read answers both "where is
  # it" and "what is it waiting on" -- no torn status-then-pending reads.
  defp status_value(:awaiting_permission, data), do: {:awaiting_permission, data.pending_action}
  defp status_value(:waiting_for_user, data), do: {:waiting_for_user, data.pending_question}
  defp status_value(state, _data), do: state

  # The same silent-drop trap ObanClaude.Worker guards at compile time (#75):
  # atom keys would vanish in the string-keyed merge with each job's args.
  defp invalid_keys(args) when is_map(args), do: Enum.reject(Map.keys(args), &is_binary/1)
  defp invalid_keys(other), do: [other]

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

  defp validate_config_revision!(nil), do: :ok

  defp validate_config_revision!(revision)
       when is_binary(revision) and byte_size(revision) in 1..256,
       do: :ok

  defp validate_config_revision!(revision) do
    raise ArgumentError,
          ":config_revision must be a non-empty string of at most 256 bytes, got: " <>
            inspect(revision)
  end
end
