defmodule Arc.Webhooks.Events do
  @moduledoc """
  Turns channel and presence transitions into webhook events.

  `channel_vacated` and `member_removed` are held for the debounce window (2 seconds
  by default). If the channel is occupied again, or the user rejoins, inside the
  window, the pending event is cancelled and the matching `channel_occupied` /
  `member_added` is suppressed too, so a reconnecting client produces no webhook
  traffic at all.

  Occupancy transitions arrive from each node's local counts. Before a
  `channel_occupied` or `channel_vacated` is emitted the other nodes are asked for
  their counts, so only the first subscriber in the cluster and the last one out
  produce events.

  Work is spread over shards by channel, so a burst on one channel does not delay
  another's timers. Nothing here runs unless the app has an endpoint that wants the
  event.
  """
  use GenServer

  alias Arc.Apps.{Cache, Config}
  alias Arc.Webhooks.Batcher

  @shards 16

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

  def occupied(app_id, channel),
    do:
      cast_if(
        app_id,
        channel,
        ["channel_occupied", "channel_vacated"],
        {:occupied, app_id, channel}
      )

  def vacated(app_id, channel),
    do:
      cast_if(
        app_id,
        channel,
        ["channel_occupied", "channel_vacated"],
        {:vacated, app_id, channel}
      )

  def member_added(app_id, channel, user_id),
    do:
      cast_if(
        app_id,
        channel,
        ["member_added", "member_removed"],
        {:member_added, app_id, channel, user_id}
      )

  def member_removed(app_id, channel, user_id),
    do:
      cast_if(
        app_id,
        channel,
        ["member_added", "member_removed"],
        {:member_removed, app_id, channel, user_id}
      )

  def cache_miss(app_id, channel) do
    if wanted?(app_id, "cache_miss"),
      do: Batcher.add(app_id, %{name: "cache_miss", channel: channel})

    :ok
  end

  def client_event(
        app_id,
        %{channel: channel, event: event, data: data, socket_id: socket_id} = info
      ) do
    if wanted?(app_id, "client_event") do
      event =
        %{name: "client_event", channel: channel, event: event, data: data, socket_id: socket_id}
        |> put_present(:user_id, Map.get(info, :user_id))

      Batcher.add(app_id, event)
    end

    :ok
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp cast_if(app_id, channel, events, message) do
    if Enum.any?(events, &wanted?(app_id, &1)) do
      GenServer.cast(shard_name(:erlang.phash2({app_id, channel}, @shards)), message)
    end

    :ok
  end

  defp wanted?(app_id, event) do
    case Cache.get(app_id) do
      %Config{} = config -> Config.webhook_enabled?(config, event)
      nil -> false
    end
  end

  ## Shard

  @impl true
  def init(_index), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_cast({:occupied, app_id, channel}, state) do
    key = {:vacated, app_id, channel}

    case Map.pop(state.pending, key) do
      {nil, _} ->
        # This node just went from 0 to 1; the channel is newly occupied only if no
        # other node already has subscribers.
        if remote_subscriptions(app_id, channel) == 0 do
          emit(app_id, "channel_occupied", %{channel: channel})
        end

        {:noreply, state}

      {timer, pending} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_cast({:vacated, app_id, channel}, state),
    do: {:noreply, schedule(state, {:vacated, app_id, channel})}

  def handle_cast({:member_added, app_id, channel, user_id}, state) do
    key = {:member_removed, app_id, channel, user_id}

    case Map.pop(state.pending, key) do
      {nil, _} ->
        emit(app_id, "member_added", %{channel: channel, user_id: user_id})
        {:noreply, state}

      {timer, pending} ->
        Process.cancel_timer(timer)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_cast({:member_removed, app_id, channel, user_id}, state),
    do: {:noreply, schedule(state, {:member_removed, app_id, channel, user_id})}

  @impl true
  def handle_info({:fire, key}, state) do
    case Map.pop(state.pending, key) do
      {nil, _} ->
        {:noreply, state}

      {_timer, pending} ->
        fire(key)
        {:noreply, %{state | pending: pending}}
    end
  end

  defp schedule(state, key) do
    if Map.has_key?(state.pending, key) do
      state
    else
      timer = Process.send_after(self(), {:fire, key}, debounce_ms())
      %{state | pending: Map.put(state.pending, key, timer)}
    end
  end

  defp fire({:vacated, app_id, channel}) do
    if cluster_subscriptions(app_id, channel) == 0 do
      emit(app_id, "channel_vacated", %{channel: channel})
    end
  end

  defp fire({:member_removed, app_id, channel, user_id}) do
    unless Arc.Presence.member?(app_id, channel, user_id) do
      emit(app_id, "member_removed", %{channel: channel, user_id: user_id})
    end
  end

  defp cluster_subscriptions(app_id, channel),
    do: Arc.Realtime.subscription_count(app_id, channel)

  defp remote_subscriptions(app_id, channel) do
    case Node.list() do
      [] ->
        0

      nodes ->
        nodes
        |> :erpc.multicall(Arc.Realtime.Occupancy, :subscription_count, [app_id, channel], 5_000)
        |> Enum.reduce(0, fn
          {:ok, count}, acc -> acc + count
          _, acc -> acc
        end)
    end
  end

  defp emit(app_id, name, fields) do
    if wanted?(app_id, name), do: Batcher.add(app_id, Map.put(fields, :name, name))
  end

  defp debounce_ms, do: Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(:debounce_ms)

  defp shard_name(index), do: :"#{__MODULE__}.#{index}"
end
