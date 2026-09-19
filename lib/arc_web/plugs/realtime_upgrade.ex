defmodule ArcWeb.Plugs.RealtimeUpgrade do
  @moduledoc """
  Upgrades `GET /app/:key` to a client WebSocket, ahead of the rest of the endpoint
  pipeline: a connection handshake needs no session, no body parsing, and no router.

  Protocol and app checks happen after the upgrade, inside `Arc.Realtime.Socket.init/1`,
  so a rejected client receives the error frame and close code its SDK acts on rather
  than an opaque HTTP failure.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", path_info: ["app", key]} = conn, _opts) do
    if websocket_request?(conn) do
      conn = fetch_query_params(conn)
      config = Application.fetch_env!(:arc, Arc.Realtime)

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
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(400, "This endpoint accepts WebSocket connections only.\n")
      |> halt()
    end
  end

  def call(conn, _opts), do: conn

  defp websocket_request?(conn) do
    get_req_header(conn, "upgrade") |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end
end
