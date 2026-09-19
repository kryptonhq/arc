defmodule Arc.Realtime.SocketId do
  @moduledoc """
  Socket ids of the form `<int>.<int>`.

  The first part is a random number chosen once per node at boot; the second is a
  monotonically unique integer on that node. Together they are unique on the node by
  construction and across the cluster unless two nodes draw the same 31-bit prefix.
  """

  @prefix_key {__MODULE__, :prefix}

  @doc false
  def init do
    :persistent_term.put(@prefix_key, :rand.uniform(2_147_483_646))
  end

  @spec generate() :: String.t()
  def generate do
    "#{:persistent_term.get(@prefix_key)}.#{:erlang.unique_integer([:positive, :monotonic])}"
  end

  @doc "True for strings shaped like a socket id."
  def valid?(socket_id) when is_binary(socket_id), do: Regex.match?(~r/\A\d+\.\d+\z/, socket_id)
  def valid?(_), do: false
end
