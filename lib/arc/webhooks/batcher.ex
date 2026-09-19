defmodule Arc.Webhooks.Batcher do
  @moduledoc """
  Collects webhook events per app for a short window and turns each window into one
  delivery per interested endpoint, so a burst of channel activity becomes a handful
  of requests instead of one per event.

  Body shape: `{"time_ms": <unix ms>, "events": [...]}`.
  """
  use GenServer

  alias Arc.Apps.Cache
  alias Arc.Webhooks.Deliverer

  @shards 8

  @doc false
  def child_spec(_opts) do
    children =
      for index <- 0..(@shards - 1) do
        %{id: {__MODULE__, index}, start: {__MODULE__, :start_link, [index]}}
      end

    %{
      id: __MODULE__,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
    }
  end

  def start_link(index), do: GenServer.start_link(__MODULE__, index, name: shard_name(index))

  @doc "Queues an event for the app's next batch."
  def add(app_id, event) do
    GenServer.cast(shard_name(:erlang.phash2(app_id, @shards)), {:add, app_id, event})
  end

  @doc "Flushes every pending batch on this node immediately. Used by tests and on shutdown."
  def flush_all do
    for index <- 0..(@shards - 1), do: GenServer.call(shard_name(index), :flush)
    :ok
  end

  @impl true
  def init(_index) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:add, app_id, event}, batches) do
    batches =
      case batches do
        %{^app_id => events} ->
          Map.put(batches, app_id, [event | events])

        _ ->
          Process.send_after(self(), {:flush, app_id}, window())
          Map.put(batches, app_id, [event])
      end

    {:noreply, batches}
  end

  @impl true
  def handle_call(:flush, _from, batches) do
    Enum.each(batches, fn {app_id, events} -> flush(app_id, events) end)
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_info({:flush, app_id}, batches) do
    case Map.pop(batches, app_id) do
      {nil, batches} ->
        {:noreply, batches}

      {events, batches} ->
        flush(app_id, events)
        {:noreply, batches}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, batches), do: {:noreply, batches}

  @impl true
  def terminate(_reason, batches) do
    Enum.each(batches, fn {app_id, events} -> flush(app_id, events) end)
  end

  defp flush(app_id, events) do
    events = Enum.reverse(events)
    time_ms = System.system_time(:millisecond)

    case Cache.get(app_id) do
      nil ->
        :ok

      config ->
        for endpoint <- config.webhooks,
            wanted = Enum.filter(events, &MapSet.member?(endpoint.events, &1.name)),
            wanted != [] do
          Deliverer.enqueue(app_id, endpoint.id, %{time_ms: time_ms, events: wanted})
        end
    end
  end

  defp window, do: Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(:batch_window)

  defp shard_name(index), do: :"#{__MODULE__}.#{index}"
end
