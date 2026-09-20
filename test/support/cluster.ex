defmodule Arc.Test.Cluster do
  @moduledoc """
  Starts Arc on extra BEAM nodes connected to the test node, each serving the
  WebSocket endpoint on its own port.
  """

  @doc """
  True when this VM was started with partition policing disabled, which the partition
  test needs. `mix test.cluster` starts it that way.
  """
  def partition_safe? do
    :application.get_env(:kernel, :prevent_overlapping_partitions) == {:ok, false}
  end

  @doc "Makes the test node distributed. Idempotent."
  def ensure_distributed do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = :net_kernel.start([:"arc_primary@127.0.0.1", :longnames])
    end

    :ok
  end

  @doc "Starts a peer node running Arc on `port`. Returns `{peer_pid, node}`."
  def start_node(name, port) do
    {:ok, peer, node} =
      :peer.start(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        # Control the peer over stdio, not distribution, so partition tests can cut
        # the distribution link without the peer shutting itself down.
        connection: :standard_io,
        args: [
          ~c"-setcookie",
          Atom.to_charlist(Node.get_cookie()),
          # Without this, OTP's protection against overlapping partitions responds to
          # the partition test by disconnecting nodes that were not part of it.
          ~c"-kernel",
          ~c"prevent_overlapping_partitions",
          ~c"false"
        ]
      })

    true = Node.connect(node)
    :ok = :erpc.call(node, :code, :add_paths, [:code.get_path()])

    for {app, _, _} <- Application.loaded_applications(), app not in [:kernel, :stdlib] do
      env = Application.get_all_env(app)
      :erpc.call(node, Application, :load, [app])
      for {key, value} <- env, do: :erpc.call(node, Application, :put_env, [app, key, value])
    end

    endpoint = Application.get_env(:arc, ArcWeb.Endpoint)
    endpoint = Keyword.merge(endpoint, http: [ip: {127, 0, 0, 1}, port: port], server: true)
    :erpc.call(node, Application, :put_env, [:arc, ArcWeb.Endpoint, endpoint])
    # Peers talk to Postgres directly rather than through the test sandbox.
    repo =
      Application.get_env(:arc, Arc.Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    :erpc.call(node, Application, :put_env, [:arc, Arc.Repo, repo])
    :erpc.call(node, Application, :put_env, [:logger, :level, :error])
    :erpc.call(node, Logger, :configure, [[level: :error]])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:arc])
    true = Node.connect(node)
    {peer, node}
  end
end
