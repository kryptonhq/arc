defmodule Arc.Realtime do
  @moduledoc """
  The data plane's public interface: publishing, channel queries, and connection
  control. Used by the HTTP API, the dashboard aggregator, and the Apps context.

  Queries that need a cluster-wide answer ask every node in parallel and sum the
  node-local counts; presence is already replicated, so member lists are local reads.
  """

  alias Arc.Apps.Config
  alias Arc.Channels.Channel
  alias Arc.Presence
  alias Arc.Realtime.{Dispatcher, Occupancy, Protocol, Registries}

  @rpc_timeout 5_000

  @doc """
  Publishes one event to one or more channels. `data` is the event's string payload
  and is sent to subscribers exactly as given. `except` is the socket id to exclude.
  """
  @spec publish(Config.t(), [Channel.t()], String.t(), String.t(), String.t() | nil) :: :ok
  def publish(%Config{id: app_id}, channels, event, data, except \\ nil) do
    for channel <- channels do
      frame = Protocol.encode(event, channel.name, data)
      Dispatcher.broadcast(app_id, channel.name, frame, except, cache: Channel.cache?(channel))
      :telemetry.execute([:arc, :message, :sent], %{count: 1}, %{app_id: app_id, source: "api"})
    end

    :ok
  end

  @doc "Closes every connection signed in as `user_id`, on every node."
  def terminate_user_connections(app_id, user_id) do
    Dispatcher.send_all(Registries.Users, {app_id, user_id}, {:arc_close, :terminated})
  end

  @doc "Closes every connection of an app, e.g. after it is deleted or disabled."
  def disconnect_app(app_id, reason \\ :app_disabled) do
    Dispatcher.send_all(Registries.Apps, app_id, {:arc_close, reason})
  end

  @doc """
  Closes every connection on this node with a reconnect-after-backoff code. Called on
  graceful shutdown so clients move to another node.
  """
  def drain_node do
    Registry.select(Registries.Apps, [{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(&send(&1, {:arc_close, :shutting_down}))
  end

  ## Queries

  @doc "Cluster-wide connection count for an app."
  def connection_count(app_id), do: sum_cluster(Occupancy, :connection_count, [app_id])

  @doc "Cluster-wide subscription count for a channel."
  def subscription_count(app_id, channel),
    do: sum_cluster(Occupancy, :subscription_count, [app_id, channel])

  @doc "Distinct presence members on a channel."
  defdelegate user_count(app_id, channel), to: Presence

  @doc "Presence member ids on a channel."
  def user_ids(app_id, channel), do: Presence.members(app_id, channel) |> Enum.map(&elem(&1, 0))

  @doc """
  Occupied channels of an app across the cluster, optionally filtered by prefix, as a
  map of name to cluster-wide subscription count.
  """
  def occupied_channels(app_id, prefix \\ nil) do
    [node() | Node.list()]
    |> :erpc.multicall(Occupancy, :channels, [app_id], @rpc_timeout)
    |> Enum.flat_map(fn
      {:ok, channels} -> channels
      _ -> []
    end)
    |> Enum.reduce(%{}, fn {name, count}, acc ->
      if is_nil(prefix) or String.starts_with?(name, prefix),
        do: Map.update(acc, name, count, &(&1 + count)),
        else: acc
    end)
  end

  defp sum_cluster(module, function, args) do
    [node() | Node.list()]
    |> :erpc.multicall(module, function, args, @rpc_timeout)
    |> Enum.reduce(0, fn
      {:ok, count}, acc when is_integer(count) -> acc + count
      _, acc -> acc
    end)
  end
end
