defmodule ObanClaude.Agent.Execution do
  @moduledoc false

  def job_meta(%Oban.Job{id: id, attempt: attempt, meta: meta}) do
    Map.merge(meta, %{
      "job_id" => id,
      "job_attempt" => attempt,
      "job_snoozed" => Map.get(meta, "snoozed", 0)
    })
  end

  def start(turn, meta, caller) do
    with :ok <- job_status(turn, meta),
         {:ok, watermark} <- watermark(meta),
         true <- watermark > latest_watermark(turn) do
      {:ok,
       %{
         job_id: meta["job_id"],
         job_attempt: meta["job_attempt"],
         job_snoozed: meta["job_snoozed"],
         watermark: watermark,
         worker: caller,
         reference: make_ref(),
         active?: true,
         session_id: nil,
         source: nil
       }}
    else
      false -> {:error, :execution_replayed}
      {:error, _reason} = error -> error
    end
  end

  def callback_status(%{execution: nil} = turn, meta) do
    if is_integer(turn.job_id) and Map.has_key?(meta, "job_id"),
      do: job_status(turn, meta),
      else: :ok
  end

  def callback_status(%{execution: execution} = turn, meta) do
    with :ok <- job_status(turn, meta),
         true <- execution.active?,
         true <- execution.job_attempt == meta["job_attempt"],
         true <- execution.job_snoozed == meta["job_snoozed"],
         true <- execution.worker == meta[:callback_pid] do
      :ok
    else
      _ -> {:error, :stale_execution}
    end
  end

  def observe(
        %{active?: true, reference: ref} = execution,
        ref,
        %ClaudeWrapper.SessionObservation{session_id: id, source: :system_init}
      )
      when is_binary(id) and byte_size(id) in 1..256 do
    cond do
      not String.valid?(id) or String.trim(id) == "" -> {:error, :invalid_session_observation}
      execution.session_id == id -> :duplicate
      is_nil(execution.session_id) -> {:ok, %{execution | session_id: id, source: :system_init}}
      true -> {:error, :conflicting_session_observation}
    end
  end

  def observe(_execution, _ref, _observation), do: {:error, :stale_session_observation}

  def close(nil), do: nil
  def close(execution), do: %{execution | active?: false}

  def metadata(nil), do: %{}

  def metadata(execution) do
    Map.take(execution, [:job_id, :job_attempt, :job_snoozed])
    |> Map.put(:execution_state, :started)
  end

  def public_continuation(continuation, nil), do: continuation

  def public_continuation(continuation, execution) do
    continuation
    |> Map.merge(metadata(execution))
    |> Map.merge(%{session_id: execution.session_id, source: execution.source})
  end

  defp job_status(turn, meta) do
    cond do
      not is_integer(turn.job_id) or turn.job_id <= 0 -> {:error, :job_identity_required}
      meta["job_id"] != turn.job_id -> {:error, :job_id_mismatch}
      meta["arc_id"] != turn.continuation.arc_id -> {:error, :arc_id_mismatch}
      true -> :ok
    end
  end

  defp watermark(%{"job_attempt" => attempt, "job_snoozed" => snoozed})
       when is_integer(attempt) and attempt > 0 and is_integer(snoozed) and snoozed >= 0,
       do: {:ok, attempt + snoozed}

  defp watermark(_meta), do: {:error, :invalid_execution_identity}

  defp latest_watermark(%{execution: nil, retry_watermark: watermark}), do: watermark

  defp latest_watermark(turn),
    do: max(turn.retry_watermark, turn.execution.watermark)
end
