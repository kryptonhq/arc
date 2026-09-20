defmodule ArcWeb.Plugs.RealtimeUpgrade do
  @moduledoc """
  Upgrades `GET /app/:key` to a client WebSocket, ahead of the rest of the endpoint
  pipeline: a connection handshake needs no session, no body parsing, and no router.

  Protocol and app checks happen after the upgrade, inside `Arc.Realtime.Socket.init/1`,
  so a rejected client receives the error frame and close code its SDK acts on rather
  than an opaque HTTP failure. The one check made before the upgrade is the per-address
  connection-attempt limit: a client reconnecting in a tight loop gets 429 and a
  `Retry-After`, which costs the node nothing.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["app", key]} = conn, _opts) do
    config = Application.fetch_env!(:arc, Arc.Realtime)

    cond do
      not websocket_request?(conn) ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "This endpoint accepts WebSocket connections only.\n")
        |> halt()

      (retry = over_connect_limit(conn.remote_ip, config)) != nil ->
        :telemetry.execute([:arc, :rate_limit, :hit], %{count: 1}, %{app_id: nil, kind: "connect"})

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry))
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many connection attempts from this address. Retry later.\n")
        |> halt()

      true ->
        upgrade(fetch_query_params(conn), key, config)
    end
  end

  def call(conn, _opts), do: conn

  # Refills at `connect_rate_per_minute` tokens per minute with the same burst, so a
  # burst of reconnects after a deploy is fine and a tight loop is not.
  defp over_connect_limit(ip, config) do
    per_minute = Keyword.fetch!(config, :connect_rate_per_minute)

    case Arc.RateLimiter.take({:connect, ip}, per_minute / 60, per_minute) do
      :ok -> nil
      {:error, retry_after_ms} -> max(1, div(retry_after_ms + 999, 1000))
    end
  end

  defp upgrade(conn, key, config) do
    # Server-side liveness is handled by the socket's own ping/pong; this timeout is
    # only a backstop for a connection that never completes that exchange.
    timeout =
      (Keyword.fetch!(config, :activity_timeout) + 60) * 1000 +
        Keyword.fetch!(config, :pong_timeout)

    conn
    |> WebSockAdapter.upgrade(
      Arc.Realtime.Socket,
      %{key: key, params: conn.query_params},
      timeout: timeout,
      max_frame_size: Keyword.fetch!(config, :max_frame_size),
      compress: false
    )
    |> halt()
  end

  defp websocket_request?(conn) do
    get_req_header(conn, "upgrade") |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end
end
