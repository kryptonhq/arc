defmodule Arc.ClusterStackTest do
  @moduledoc """
  The behaviour the clustering docs promise, checked against real containers behind a
  real load balancer. Needs the stack from `docker-compose.cluster.yml` running:

      docker compose -f docker-compose.cluster.yml up --build --wait
      mix test --only compose

  Nothing here uses the test database or the in-process endpoint; every assertion goes
  over the published ports, and node failures are injected with the Docker CLI.
  """
  use ExUnit.Case, async: false

  alias Arc.Test.WsClient

  @moduletag :compose
  @moduletag timeout: 400_000

  @lb 4100
  @nodes %{"arc1" => 4101, "arc2" => 4102, "arc3" => 4103}
  @compose ~w(compose -f docker-compose.cluster.yml)
  @credentials "tmp/cluster/arc-cluster.json"

  setup_all do
    creds = @credentials |> File.read!() |> Jason.decode!()

    config = %Arc.Apps.Config{
      id: creds["id"],
      key: creds["key"],
      secret: creds["secret"],
      client_events_enabled: true,
      webhooks: []
    }

    on_exit(fn -> ensure_all_up() end)
    %{config: config}
  end

  setup do
    ensure_all_up()
    :ok
  end

  ## Helpers

  defp compose(args) do
    {out, status} = System.cmd("docker", @compose ++ args, stderr_to_stdout: true)
    if status != 0, do: flunk("docker compose #{Enum.join(args, " ")} failed:\n#{out}")
    out
  end

  defp docker(args) do
    {out, status} = System.cmd("docker", args, stderr_to_stdout: true)
    if status != 0, do: flunk("docker #{Enum.join(args, " ")} failed:\n#{out}")
    out
  end

  defp container(service), do: String.trim(compose(["ps", "-a", "-q", service]))

  defp ready?(port) do
    match?({:ok, %{status: 200}}, Req.get("http://localhost:#{port}/health/ready", retry: false))
  end

  defp await_ready(port, timeout \\ 60_000), do: eventually(fn -> ready?(port) end, timeout)

  # Undo whatever the previous test did to the stack: start stopped containers and
  # put a partitioned one back on the network. Plain `docker start` on the container
  # ids, because `compose start`/`up` re-evaluate depends_on and re-run the seed.
  defp ensure_all_up do
    for name <- Map.keys(@nodes) do
      System.cmd("docker", ["network", "connect", network(), container(name)],
        stderr_to_stdout: true
      )
    end

    docker(["start" | Enum.map(Map.keys(@nodes) ++ ["lb"], &container/1)])
    for {_name, port} <- @nodes, do: await_ready(port)
    await_ready(@lb)

    eventually(
      fn -> peers("arc1") == 2 and peers("arc2") == 2 and peers("arc3") == 2 end,
      120_000
    )
  end

  defp network do
    name = compose(["config", "--format", "json"]) |> Jason.decode!() |> Map.fetch!("name")
    "#{name}_default"
  end

  defp rpc(service, code) do
    compose(["exec", "-T", service, "/app/bin/arc", "rpc", code]) |> String.trim()
  end

  defp peers(service), do: rpc(service, "IO.puts(length(Node.list()))") |> String.to_integer()

  defp connect!(port, config) do
    {:ok, client} = WsClient.connect("/app/#{config.key}?protocol=7", self(), port)
    %{"event" => "pusher:connection_established", "data" => data} = next_frame!(client)
    %{"socket_id" => socket_id} = Jason.decode!(data)
    {client, socket_id}
  end

  defp subscribe!(client, channel, extra \\ %{}) do
    :ok =
      WsClient.send_json(client, %{
        event: "pusher:subscribe",
        data: Map.put(extra, :channel, channel)
      })
  end

  defp subscribe_presence!(client, config, socket_id, channel, user_id) do
    data = Jason.encode!(%{user_id: user_id, user_info: %{}})
    auth = Arc.Channels.Auth.sign_channel(config, socket_id, channel, data)
    subscribe!(client, channel, %{auth: auth, channel_data: data})
    await_event!(client, "pusher_internal:subscription_succeeded")
  end

  # The test client does not answer server pings on its own; over a wait longer than
  # the activity timeout plus the pong window (150 s) Arc would rightly close it.
  # A client that has meanwhile been closed is skipped; the test decides what a close
  # means, not the keepalive.
  defp keep_alive(clients) do
    pid =
      spawn(fn ->
        Stream.interval(20_000)
        |> Enum.each(fn _ ->
          for client <- clients, Process.alive?(client) do
            try do
              WsClient.send_json(client, %{event: "pusher:ping", data: %{}})
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp next_frame!(client, timeout \\ 5_000) do
    receive do
      {:frame, ^client, frame} -> frame
    after
      timeout -> flunk("no frame within #{timeout}ms")
    end
  end

  defp await_event!(client, event, timeout \\ 5_000) do
    receive do
      {:frame, ^client, %{"event" => ^event} = frame} -> frame
    after
      timeout -> flunk("no #{event} within #{timeout}ms")
    end
  end

  defp await_close!(client, timeout \\ 30_000) do
    receive do
      {:closed, ^client, code, reason} -> {code, reason}
    after
      timeout -> flunk("not closed within #{timeout}ms")
    end
  end

  defp publish_ok?(port, config, channel, event) do
    body = Jason.encode!(%{name: event, channel: channel, data: "{}"})
    path = Arc.Test.Fixtures.signed_path(config, "POST", "/apps/#{config.id}/events", body)

    match?(
      {:ok, %{status: 200}},
      Req.post("http://localhost:#{port}" <> path, body: body, retry: false)
    )
  end

  defp publish!(port, config, channel, event, data \\ %{}) do
    body = Jason.encode!(%{name: event, channel: channel, data: Jason.encode!(data)})
    path = Arc.Test.Fixtures.signed_path(config, "POST", "/apps/#{config.id}/events", body)
    resp = Req.post!("http://localhost:#{port}" <> path, body: body, retry: false)
    assert resp.status == 200, "publish via #{port}: #{resp.status} #{inspect(resp.body)}"
  end

  # Nil while a node is unreachable, so it can sit inside `eventually`.
  defp channel_info!(port, config, channel, info) do
    path =
      Arc.Test.Fixtures.signed_path(
        config,
        "GET",
        "/apps/#{config.id}/channels/#{channel}",
        "",
        %{
          "info" => info
        }
      )

    case Req.get("http://localhost:#{port}" <> path, retry: false) do
      {:ok, %{status: 200, body: body}} -> body
      _ -> %{}
    end
  end

  defp eventually(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      result = fun.()
      unless result, do: Process.sleep(200)
      result
    end)
    |> Enum.find(fn result ->
      result || (System.monotonic_time(:millisecond) > deadline && flunk("condition not met"))
    end)
  end

  ## The promises

  test "the three nodes form one cluster and the balancer is ready" do
    for name <- Map.keys(@nodes), do: assert(peers(name) == 2, "#{name} sees two peers")
    assert ready?(@lb)
  end

  test "a publish through the balancer reaches subscribers on every node", %{config: config} do
    clients =
      for {name, port} <- @nodes do
        {client, _} = connect!(port, config)
        subscribe!(client, "cross-node")
        await_event!(client, "pusher_internal:subscription_succeeded")
        {name, client}
      end

    publish!(@lb, config, "cross-node", "hello", %{n: 1})

    for {name, client} <- clients do
      assert %{"event" => "hello"} = await_event!(client, "hello"), "#{name} received it"
    end
  end

  test "presence converges across nodes and a killed node's members leave within seconds",
       %{config: config} do
    channel = "presence-room-#{System.unique_integer([:positive])}"

    {c1, s1} = connect!(4101, config)
    subscribe_presence!(c1, config, s1, channel, "u1")
    {c3, s3} = connect!(4103, config)
    subscribe_presence!(c3, config, s3, channel, "u3")

    assert %{"event" => "pusher_internal:member_added"} =
             await_event!(c1, "pusher_internal:member_added")

    ids = fn port -> channel_info!(port, config, channel, "user_count")["user_count"] end
    for {_n, port} <- @nodes, do: eventually(fn -> ids.(port) == 2 end, 10_000)

    docker(["kill", container("arc3")])

    assert %{"event" => "pusher_internal:member_removed", "data" => data} =
             await_event!(c1, "pusher_internal:member_removed", 15_000)

    assert %{"user_id" => "u3"} = Jason.decode!(data)
    eventually(fn -> ids.(4101) == 1 end, 10_000)
  end

  test "a rotated secret stops verifying on every node", %{config: config} do
    # Rotate on arc2; the API on arc1 and arc3 must refuse the old secret at once.
    new_secret =
      rpc(
        "arc2",
        ~s|{:ok, _app, secret} = Arc.Apps.rotate_secret(Arc.Apps.get_app!(#{config.id})); IO.puts(secret)|
      )

    on_exit(fn ->
      # Put the original back so the credentials file stays valid for other tests.
      rpc(
        "arc1",
        ~s|Arc.Apps.get_app!(#{config.id}) \|> Ecto.Changeset.change(secret: "#{config.secret}") \|> Arc.Repo.update!(); Arc.Apps.refresh(#{config.id})|
      )
    end)

    for {_n, port} <- @nodes do
      eventually(
        fn ->
          body = Jason.encode!(%{name: "x", channel: "c", data: "{}"})
          path = Arc.Test.Fixtures.signed_path(config, "POST", "/apps/#{config.id}/events", body)
          Req.post!("http://localhost:#{port}" <> path, body: body, retry: false).status == 401
        end,
        10_000
      )
    end

    publish!(@lb, %{config | secret: new_secret}, "c", "x")
  end

  test "channel queries sum subscriptions across nodes", %{config: config} do
    channel = "counted-#{System.unique_integer([:positive])}"

    for {_n, port} <- @nodes, _ <- 1..2 do
      {client, _} = connect!(port, config)
      subscribe!(client, channel)
      await_event!(client, "pusher_internal:subscription_succeeded")
    end

    for {_n, port} <- @nodes do
      eventually(
        fn ->
          channel_info!(port, config, channel, "subscription_count")["subscription_count"] == 6
        end,
        10_000
      )
    end
  end

  test "a rolling restart drains: readiness goes 503, clients get 4101 and land elsewhere",
       %{config: config} do
    {victim, _} = connect!(4102, config)
    subscribe!(victim, "survivor")
    await_event!(victim, "pusher_internal:subscription_succeeded")

    {bystander, _} = connect!(4101, config)
    subscribe!(bystander, "survivor")
    await_event!(bystander, "pusher_internal:subscription_succeeded")

    task = Task.async(fn -> compose(["restart", "arc2"]) end)

    # During the drain window the node reports 503 before the client is closed.
    eventually(fn -> not ready?(4102) end, 10_000)

    assert %{"event" => "pusher:error", "data" => %{"code" => 4101}} =
             await_event!(victim, "pusher:error", 20_000)

    assert {4101, _} = await_close!(victim)

    # The bystander on another node never noticed, and the balancer still serves.
    publish!(@lb, config, "survivor", "mid-restart")
    assert %{"event" => "mid-restart"} = await_event!(bystander, "mid-restart")

    # Reconnecting through the balancer lands on a ready node.
    {again, _} = connect!(@lb, config)
    subscribe!(again, "survivor")
    await_event!(again, "pusher_internal:subscription_succeeded")

    Task.await(task, 60_000)
    await_ready(4102)
    eventually(fn -> peers("arc2") == 2 end, 30_000)
  end

  test "losing a node under traffic and getting it back", %{config: config} do
    {c1, _} = connect!(4101, config)
    subscribe!(c1, "loss")
    await_event!(c1, "pusher_internal:subscription_succeeded")

    docker(["kill", container("arc3")])
    eventually(fn -> peers("arc1") == 1 end, 15_000)

    # The balancer needs one failed health check (1 s) to stop routing to the dead
    # node; a publish that lands there in that window is the caller's retry.
    eventually(fn -> publish_ok?(@lb, config, "loss", "still-here") end, 10_000)
    assert %{"event" => "still-here"} = await_event!(c1, "still-here")

    compose(["start", "arc3"])
    await_ready(4103)
    eventually(fn -> peers("arc1") == 2 and peers("arc3") == 2 end, 60_000)
  end

  test "a partitioned node rejoins and presence converges", %{config: config} do
    channel = "presence-split-#{System.unique_integer([:positive])}"
    {c1, s1} = connect!(4101, config)
    subscribe_presence!(c1, config, s1, channel, "a")
    {c3, s3} = connect!(4103, config)
    subscribe_presence!(c3, config, s3, channel, "b")
    await_event!(c1, "pusher_internal:member_added")
    keep_alive([c1, c3])

    docker(["network", "disconnect", network(), container("arc3")])
    # Distribution notices a silent peer after net_ticktime, 60 s by default, and each
    # side notices on its own clock. Heal only once both have, as a real partition
    # would; healing while one side still believes the link is up leaves that side
    # refusing the reconnect until its own tick fires.
    eventually(fn -> peers("arc1") == 1 end, 90_000)
    # The cut node cannot be asked (`arc rpc` dials the node by the address it just
    # lost), so give its own tick the full window before healing.
    Process.sleep(70_000)

    # The cut node stays alive. Its published port is gone with the network, so ask
    # from inside the container.
    assert compose(["exec", "-T", "arc3", "curl", "-fs", "http://127.0.0.1:4000/health/live"]) ==
             "ok"

    Process.sleep(5_000)
    docker(["network", "connect", network(), container("arc3")])
    eventually(fn -> peers("arc1") == 2 and peers("arc3") == 2 end, 90_000)

    # The cut node's published port went with its network, so its client may drop at
    # any point (a Docker artefact, not a protocol one). Whatever happens, both sides
    # must agree on the members that are actually still connected.
    count = fn port -> channel_info!(port, config, channel, "user_count")["user_count"] end

    eventually(
      fn ->
        receive do
          {:closed, ^c3, _code, _reason} -> Process.put(:c3_closed, true)
        after
          0 -> :ok
        end

        survivors = if Process.get(:c3_closed), do: 1, else: 2
        count.(4101) == survivors and count.(4103) == survivors
      end,
      90_000
    )
  end

  test "cache channel retention is per node, as documented", %{config: config} do
    channel = "cache-local-#{System.unique_integer([:positive])}"
    {warm, _} = connect!(4101, config)
    subscribe!(warm, channel)
    await_event!(warm, "pusher_internal:subscription_succeeded")
    publish!(4101, config, channel, "last", %{v: 1})
    await_event!(warm, "last")

    # arc1 saw the event and replays it; a node that did not answers with a miss.
    {same, _} = connect!(4101, config)
    subscribe!(same, channel)
    assert %{"event" => "last"} = await_event!(same, "last")
  end
end
