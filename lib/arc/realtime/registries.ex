defmodule Arc.Realtime.Registries do
  @moduledoc """
  The node-local registries connecting names to socket processes. Each is a
  partitioned `Registry` in duplicate mode with one partition per scheduler; entries
  are removed automatically when the socket process exits.

  * `Channels` — `{app_id, channel}` → socket id, one entry per subscription
  * `Users` — `{app_id, user_id}` → socket id, for signed-in connections
  * `Apps` — `app_id` → socket id, one entry per connection
  """

  # Registry names only; these are atoms, not modules.
  @names [__MODULE__.Channels, __MODULE__.Users, __MODULE__.Apps]

  @doc false
  def child_specs do
    partitions = System.schedulers_online()

    for name <- @names do
      Supervisor.child_spec({Registry, keys: :duplicate, name: name, partitions: partitions},
        id: name
      )
    end
  end
end
