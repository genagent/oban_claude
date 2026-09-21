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
      generation: identity_token(),
      current_turn: nil,
      # set while an approve continuation is in flight: an approved turn that
      # fails or times out RE-GATES (the action was approved but not
      # completed) instead of falling to :idle with the elevation lost
      in_flight_approval: nil,
      # the origin of the current conversational arc (:operator or :tick),
      # stamped into every enqueued job's meta so downstream consumers
      # (feeds, dashboards) can tell an operator's question from scheduled
      # work. Approve/reject continuations inherit the arc's origin.
      origin: :tick
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
  # does not survive the lockdown; after resume the operator starts clean. An
  # actually in-flight turn retains bookkeeping ownership so its matching
  # outcome can still contribute history, spend, and a session without acting.
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
    start_turn(from, text, prompt_data(data, opts))
  end

  defp process_event(:idle, :cast, {:user_prompt, text, opts}, data) do
    start_turn(nil, text, prompt_data(data, opts))
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

  defp process_event(:waiting_for_user, {:call, from}, {:user_prompt, answer, opts}, data) do
    candidate = prompt_data(%{data | pending_question: nil}, opts)
    start_turn(from, answer, candidate, %{}, :waiting_for_user, data)
  end

  defp process_event(:waiting_for_user, :cast, {:user_prompt, answer, opts}, data) do
    candidate = prompt_data(%{data | pending_question: nil}, opts)
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

        data = %{
          data
          | pending_action: nil,
            in_flight_approval: %{description: description}
        }

        start_turn(
          from,
          prompt,
          data,
          Map.merge(data.config.approved_args, args),
          :awaiting_permission,
          %{data | pending_action: %{id: id, description: description}, in_flight_approval: nil}
        )

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

  # Enqueue one claude turn and park in :running under the watchdog. The args
  # are the config defaults, any per-turn extras (approve continuations carry
  # :approved_args), the prompt, and (from the second turn on) the resume
  # handle of the agent's claude session. `from` is nil on the cast path
  # (no caller to reply to).
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

    args =
      data.config.args
      |> Map.merge(extra_args)
      |> Map.put("prompt", prompt)
      |> maybe_resume(data.session_id)

    case enqueue(data, args, turn_id) do
      {:ok, _job} ->
        current_turn = %{id: turn_id, retry_watermark: 0}
        data = %{data | current_turn: current_turn}
        watchdog = watchdog(data)

        {:next_state, :running, record(data, {:prompt, prompt}),
         reply(from, :processing) ++ [watchdog]}

      {:error, reason} ->
        {:next_state, fallback_state, record(fallback_data, {:enqueue_failed, reason}),
         reply(from, {:error, {:enqueue_failed, reason}})}
    end
  end

  defp reply(nil, _message), do: []
  defp reply(from, message), do: [{:reply, from, message}]

  # `session: :fresh` clears the resume handle at delivery time (not at send
  # time), so it composes correctly with postponed prompts: the turn that
  # finally runs starts a new claude session, and its result seeds the new
  # session id.
  defp prompt_data(data, %{session: :fresh} = opts) do
    %{data | session_id: nil, origin: Map.get(opts, :origin, :operator)}
  end

  defp prompt_data(data, opts) do
    %{data | origin: Map.get(opts, :origin, :operator)}
  end

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

  defp enqueue(%{config: %{enqueue_fun: fun}} = data, args, turn_id) when is_function(fun, 2) do
    fun.(args, job_meta(data, turn_id))
  end

  defp enqueue(data, args, turn_id) do
    meta = job_meta(data, turn_id)
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
  defp job_meta(data, turn_id) do
    %{
      "agent_id" => data.id,
      "agent_generation" => data.generation,
      "agent_turn_id" => turn_id,
      "origin" => to_string(data.origin)
    }
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
    case identity_status(data, meta) do
      :ok when state == :running ->
        data
        |> retire_turn()
        |> finish_turn(payload)

      :ok when state in [:paused, :idle] ->
        data = data |> retire_turn() |> absorb(payload)
        {:keep_state, data}

      :ok ->
        {:keep_state, reject_callback(data, :finished, meta, {:invalid_state, state})}

      {:error, reason} ->
        {:keep_state, reject_callback(data, :finished, meta, reason)}
    end
  end

  defp correlated_retry(data, retry, meta), do: correlated_retry(:running, data, retry, meta)

  defp correlated_retry(state, data, retry, meta) do
    with :ok <- identity_status(data, meta),
         :running <- state,
         {:ok, watermark} <- retry_watermark(retry, meta),
         true <- watermark > data.current_turn.retry_watermark do
      current_turn = %{data.current_turn | retry_watermark: watermark}
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
end
