defmodule Arc.Presence do
  @moduledoc """
  Presence channel membership, replicated across the cluster as a CRDT.

  Each subscribing connection is tracked under the topic `"<app_id>:<channel>"` with
  its user id as the key, so one user id may have many entries (one per connection).
  Membership events are about user ids, not connections: `member_added` fires when a
  user id goes from zero connections to one, and `member_removed` only when its last
  connection leaves. The per-user reference count is kept in each shard's state and
  updated from every diff the tracker reports, local or remote, so it always mirrors
  the replicated set, including after a netsplit heals or a node dies.

  Every node delivers membership events to its own local subscribers. Webhooks are
  raised once per cluster: by the node that owned the connection, or, when that node
  is gone, by the lowest-named surviving node.
  """
  use Phoenix.Tracker

  alias Arc.Realtime.{Dispatcher, Protocol}

  @members_table :arc_presence_members

  @doc "Creates the per-app member counter table. Called once by the realtime supervisor."
  def create_tables do
    :ets.new(@members_table, [:named_table, :public, :set, write_concurrency: true])
    :ok
  end

  @doc "Distinct presence members per app, summed over channels, as a map."
  def members_by_app, do: :ets.tab2list(@members_table) |> Map.new()

  def start_link(opts) do
    opts =
      Keyword.merge(
        [
          name: __MODULE__,
          pubsub_server: Arc.PubSub,
          pool_size: System.schedulers_online(),
          broadcast_period: 250
        ],
        opts
      )

    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @doc "Tracker topic for a channel."
  def topic(app_id, channel), do: "#{app_id}:#{channel}"

  @doc "Tracks the calling connection as `user_id` on a presence channel."
  def track(app_id, channel, socket_id, user_id, user_info) do
    meta = %{socket_id: socket_id, user_info: user_info, node: node()}
    Phoenix.Tracker.track(__MODULE__, self(), topic(app_id, channel), user_id, meta)
  end

  @doc "Stops tracking the calling connection on a presence channel."
  def untrack(app_id, channel, user_id) do
    Phoenix.Tracker.untrack(__MODULE__, self(), topic(app_id, channel), user_id)
  end

  @doc """
  Distinct members of a channel as an ordered list of `{user_id, user_info}`. When a
  user has several connections, the earliest connection's `user_info` is used.
  """
  def members(app_id, channel) do
    __MODULE__
    |> Phoenix.Tracker.list(topic(app_id, channel))
    |> Enum.reduce({[], MapSet.new()}, fn {user_id, meta}, {acc, seen} ->
      if MapSet.member?(seen, user_id),
        do: {acc, seen},
        else: {[{user_id, meta.user_info} | acc], MapSet.put(seen, user_id)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "Number of distinct user ids on a channel."
  def user_count(app_id, channel), do: members(app_id, channel) |> length()

  @doc "True if `user_id` already has a connection on the channel."
  def member?(app_id, channel, user_id) do
    Phoenix.Tracker.get_by_key(__MODULE__, topic(app_id, channel), user_id) != []
  end

  @doc "The `presence` payload of `subscription_succeeded`."
  def subscription_payload(app_id, channel) do
    members = members(app_id, channel)

    %{
      presence: %{
        ids: Enum.map(members, &elem(&1, 0)),
        hash: Map.new(members, fn {id, info} -> {id, info} end),
        count: length(members)
      }
    }
  end

  ## Tracker callbacks

  @impl true
  def init(_opts), do: {:ok, %{counts: %{}}}

  @impl true
  def handle_diff(diff, state) do
    counts =
      Enum.reduce(diff, state.counts, fn {topic, {joins, leaves}}, counts ->
        apply_topic_diff(topic, joins, leaves, counts)
      end)

    {:ok, %{state | counts: counts}}
  end

  defp apply_topic_diff(topic, joins, leaves, counts) do
    {app_id, channel} = parse_topic(topic)

    deltas =
      Enum.reduce(joins, %{}, fn {user_id, _meta}, acc ->
        Map.update(acc, user_id, 1, &(&1 + 1))
      end)

    deltas =
      Enum.reduce(leaves, deltas, fn {user_id, _meta}, acc ->
        Map.update(acc, user_id, -1, &(&1 - 1))
      end)

    Enum.reduce(deltas, counts, fn {user_id, delta}, counts ->
      key = {topic, user_id}
      before = Map.get(counts, key, 0)
      after_count = max(before + delta, 0)

      cond do
        before == 0 and after_count > 0 ->
          {_, meta} = Enum.find(joins, fn {id, _} -> id == user_id end)
          frame = Protocol.member_added(channel, user_id, meta.user_info)
          Dispatcher.dispatch_local(app_id, channel, frame, meta.socket_id)
          :ets.update_counter(@members_table, app_id, 1, {app_id, 0})
          :telemetry.execute([:arc, :presence, :member_added], %{count: 1}, %{app_id: app_id})
          if webhook_owner?(meta), do: Arc.Webhooks.Events.member_added(app_id, channel, user_id)

        before > 0 and after_count == 0 ->
          {_, meta} = Enum.find(leaves, fn {id, _} -> id == user_id end)
          Dispatcher.dispatch_local(app_id, channel, Protocol.member_removed(channel, user_id))
          :ets.update_counter(@members_table, app_id, {2, -1, 0, 0}, {app_id, 1})
          :telemetry.execute([:arc, :presence, :member_removed], %{count: 1}, %{app_id: app_id})

          if webhook_owner?(meta),
            do: Arc.Webhooks.Events.member_removed(app_id, channel, user_id)

        true ->
          :ok
      end

      if after_count == 0, do: Map.delete(counts, key), else: Map.put(counts, key, after_count)
    end)
  end

  defp parse_topic(topic) do
    [app_id, channel] = String.split(topic, ":", parts: 2)
    {String.to_integer(app_id), channel}
  end

  defp webhook_owner?(%{node: origin}) do
    alive = [node() | Node.list()]

    cond do
      origin == node() -> true
      origin in alive -> false
      true -> node() == Enum.min(alive)
    end
  end

  defp webhook_owner?(_meta), do: true
end
