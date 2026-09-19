defmodule ArcWeb.Plugs.Parsers do
  @moduledoc """
  Body parsing for the whole endpoint.

  Requests to the signed HTTP API (`/apps/...`, `/users/...`) need the exact request bytes, because
  the signature covers their MD5. For those the body is read here, kept verbatim in
  `conn.assigns.raw_body`, and decoded into `conn.assigns.json_body` as either a map
  or `{:invalid, message}`, without raising; malformed JSON is
  answered with a plain-text 400 by the API itself. Every other request goes through
  the standard `Plug.Parsers`.
  """
  @behaviour Plug

  import Plug.Conn

  # Upper bound on an API request body. The per-app payload limit, which is smaller,
  # is enforced on the event data itself.
  @max_api_body 10_485_760

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: [root | _]} = conn, _opts) when root in ["apps", "users"] do
    case read_all(conn, "") do
      {:ok, body, conn} ->
        conn
        |> assign(:raw_body, body)
        |> assign(:json_body, decode(body))
        |> Map.put(:body_params, %{})

      {:error, :too_large, conn} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(413, "Request body exceeds #{@max_api_body} bytes.\n")
        |> halt()

      {:error, _reason, conn} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "Request body could not be read.\n")
        |> halt()
    end
  end

  def call(conn, opts), do: Plug.Parsers.call(conn, opts)

  defp read_all(conn, acc) do
    case read_body(conn, length: 1_000_000) do
      {:ok, chunk, conn} -> check_size(conn, acc <> chunk, :ok)
      {:more, chunk, conn} -> check_size(conn, acc <> chunk, :more)
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp check_size(conn, body, _status) when byte_size(body) > @max_api_body,
    do: {:error, :too_large, conn}

  defp check_size(conn, body, :ok), do: {:ok, body, conn}
  defp check_size(conn, body, :more), do: read_all(conn, body)

  defp decode(""), do: %{}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> map
      {:ok, _other} -> {:invalid, "Request body must be a JSON object"}
      {:error, _} -> {:invalid, "Request body is not valid JSON"}
    end
  end
end
