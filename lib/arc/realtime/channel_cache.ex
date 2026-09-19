defmodule Arc.Realtime.ChannelCache do
  @moduledoc """
  Last-event retention for cache channels.

  The most recent event frame published to each cache channel is held in ETS on every
  node that receives it, and replayed to a new subscriber right after
  `subscription_succeeded`. Entries expire after `ttl` (30 minutes by default) and do
  not survive a restart. This is the documented behaviour of cache channels: they are
  a convenience for "current state" channels, not a durable store.
  """
  use GenServer

  @table :arc_channel_cache
  @default_ttl :timer.minutes(30)
  @sweep_interval :timer.minutes(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Retains `frame` as the last event of a cache channel."
  def put(app_id, channel, frame) do
    :ets.insert(@table, {{app_id, channel}, frame, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "The retained frame for a channel, if one exists and has not expired."
  def get(app_id, channel) do
    case :ets.lookup(@table, {app_id, channel}) do
      [{_, frame, stored_at}] ->
        if System.monotonic_time(:millisecond) - stored_at <= ttl(), do: {:ok, frame}, else: :miss

      [] ->
        :miss
    end
  end

  @doc "Drops every retained event for an app."
  def delete_app(app_id), do: :ets.match_delete(@table, {{app_id, :_}, :_, :_})

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:millisecond) - ttl()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp ttl,
    do: Application.get_env(:arc, Arc.Realtime, []) |> Keyword.get(:cache_ttl, @default_ttl)
end
