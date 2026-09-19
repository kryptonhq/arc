defmodule ArcWeb.MetricsController do
  @moduledoc """
  Prometheus scrape endpoint. When `ARC_METRICS_AUTH_TOKEN` is set, requests must
  carry it as a bearer token.
  """
  use ArcWeb, :controller

  def index(conn, _params) do
    if authorized?(conn) do
      conn
      |> put_resp_content_type("text/plain; version=0.0.4")
      |> send_resp(200, TelemetryMetricsPrometheus.Core.scrape(:arc_prometheus))
    else
      conn
      |> put_resp_header("www-authenticate", "Bearer")
      |> put_resp_content_type("text/plain")
      |> send_resp(401, "A valid bearer token is required.\n")
    end
  end

  defp authorized?(conn) do
    case Application.get_env(:arc, :metrics_auth_token) do
      token when token in [nil, ""] ->
        true

      token ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> given] -> Arc.Crypto.secure_compare(given, token)
          _ -> false
        end
    end
  end
end
