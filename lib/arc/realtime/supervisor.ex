defmodule Arc.Realtime.Supervisor do
  @moduledoc "Supervises the connection layer: registries, counters, fan-out, and presence."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Tables are owned by this supervisor so they survive restarts of the workers
    # that write to them.
    Arc.Realtime.SocketId.init()
    Arc.Realtime.Occupancy.create_tables()
    Arc.Presence.create_tables()

    children =
      Arc.Realtime.Registries.child_specs() ++
        [
          Arc.Realtime.ChannelCache,
          Arc.Realtime.Occupancy,
          Arc.Realtime.Dispatcher,
          Arc.Presence
        ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
