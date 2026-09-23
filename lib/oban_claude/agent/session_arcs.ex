defmodule ObanClaude.Agent.SessionArcs do
  @moduledoc false

  @default_max 32

  defstruct entries: %{}, clock: 0, max: @default_max

  @type arc_id :: String.t()
  @type t :: %__MODULE__{entries: map(), clock: non_neg_integer(), max: pos_integer()}

  @spec new(map(), pos_integer()) :: t()
  def new(seeds \\ %{}, max \\ @default_max) do
    validate_max!(max)
    validate_seeds!(seeds, max)

    Enum.reduce(Enum.sort(seeds), %__MODULE__{max: max}, fn {arc_id, session_id}, arcs ->
      put(arcs, arc_id, session_id)
    end)
  end

  @spec session(t(), arc_id()) :: String.t() | nil
  def session(%__MODULE__{entries: entries}, arc_id) do
    case Map.get(entries, arc_id) do
      %{session_id: session_id} -> session_id
      nil -> nil
    end
  end

  @spec sessions(t()) :: %{optional(arc_id()) => String.t()}
  def sessions(%__MODULE__{entries: entries}) do
    Map.new(entries, fn {arc_id, entry} -> {arc_id, entry.session_id} end)
  end

  @spec clear(t(), arc_id()) :: t()
  def clear(%__MODULE__{} = arcs, arc_id) do
    %{arcs | entries: Map.delete(arcs.entries, arc_id)}
  end

  @spec touch(t(), arc_id()) :: t()
  def touch(%__MODULE__{} = arcs, arc_id) do
    case Map.fetch(arcs.entries, arc_id) do
      {:ok, entry} -> store(arcs, arc_id, entry.session_id)
      :error -> arcs
    end
  end

  @spec put(t(), arc_id(), String.t()) :: t()
  def put(%__MODULE__{} = arcs, arc_id, session_id) do
    validate_id!(:arc_id, arc_id)
    validate_id!(:session_id, session_id)
    store(arcs, arc_id, session_id)
  end

  defp store(arcs, arc_id, session_id) do
    clock = arcs.clock + 1
    entries = Map.put(arcs.entries, arc_id, %{session_id: session_id, touched_at: clock})
    entries = evict_oldest(entries, arcs.max, arc_id)
    %{arcs | entries: entries, clock: clock}
  end

  defp evict_oldest(entries, max, _protected) when map_size(entries) <= max, do: entries

  defp evict_oldest(entries, _max, protected) do
    {arc_id, _entry} =
      entries
      |> Enum.reject(fn {arc_id, _entry} -> arc_id == protected end)
      |> Enum.min_by(fn {arc_id, entry} -> {entry.touched_at, arc_id} end)

    Map.delete(entries, arc_id)
  end

  defp validate_seeds!(seeds, max) when is_map(seeds) do
    if map_size(seeds) > max do
      raise ArgumentError,
            ":session_arcs contains #{map_size(seeds)} arcs but :max_session_arcs is #{max}"
    end

    Enum.each(seeds, fn {arc_id, session_id} ->
      validate_id!(:arc_id, arc_id)
      validate_id!(:session_id, session_id)
    end)
  end

  defp validate_seeds!(other, _max) do
    raise ArgumentError, ":session_arcs must be a map, got: #{inspect(other)}"
  end

  defp validate_max!(max) when is_integer(max) and max > 0, do: :ok

  defp validate_max!(other) do
    raise ArgumentError, ":max_session_arcs must be a positive integer, got: #{inspect(other)}"
  end

  defp validate_id!(_name, value) when is_binary(value) and byte_size(value) in 1..256, do: :ok

  defp validate_id!(name, value) do
    raise ArgumentError,
          ":#{name} must be a non-empty string of at most 256 bytes, got: #{inspect(value)}"
  end
end
