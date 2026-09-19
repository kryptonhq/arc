defmodule ArcWeb.Api.ApiController do
  @moduledoc """
  The signed HTTP API used by application backends. Requests reach these actions only
  after `ArcWeb.Plugs.ApiAuth` has verified the signature; `conn.assigns.app` holds
  the app config and `conn.assigns.json_body` the decoded body.
  """
  use ArcWeb, :controller

  alias Arc.Events

  def events(conn, _params) do
    with {:ok, body} <- body(conn),
         {:ok, event} <- Events.validate(conn.assigns.app, body) do
      case Events.publish(conn.assigns.app, event) do
        info when info == %{} -> json(conn, %{})
        info -> json(conn, %{channels: info})
      end
    end
    |> respond(conn)
  end

  def batch_events(conn, _params) do
    with {:ok, body} <- body(conn),
         {:ok, events} <- Events.validate_batch(conn.assigns.app, body) do
      results = Enum.map(events, &Events.publish(conn.assigns.app, &1))

      if Enum.any?(events, &(&1.info != [])) do
        json(conn, %{batch: Enum.map(results, &(&1 |> Map.values() |> List.first() || %{}))})
      else
        json(conn, %{})
      end
    end
    |> respond(conn)
  end

  def channels(conn, _params) do
    with {:ok, result} <- Events.list_channels(conn.assigns.app, conn.assigns.query) do
      json(conn, result)
    end
    |> respond(conn)
  end

  def channel(conn, %{"channel_name" => name}) do
    with {:ok, result} <- Events.channel(conn.assigns.app, name, conn.assigns.query) do
      json(conn, result)
    end
    |> respond(conn)
  end

  def users(conn, %{"channel_name" => name}) do
    with {:ok, result} <- Events.users(conn.assigns.app, name) do
      json(conn, result)
    end
    |> respond(conn)
  end

  def terminate_connections(conn, %{"user_id" => user_id}) do
    with {:ok, result} <- Events.terminate_user_connections(conn.assigns.app, user_id) do
      json(conn, result)
    end
    |> respond(conn)
  end

  defp body(conn) do
    case conn.assigns[:json_body] do
      %{} = body -> {:ok, body}
      {:invalid, message} -> {:error, 400, message <> "."}
      nil -> {:ok, %{}}
    end
  end

  defp respond(%Plug.Conn{} = conn, _original), do: conn

  defp respond({:error, status, message}, conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message <> "\n")
  end
end
