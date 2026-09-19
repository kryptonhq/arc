defmodule ArcWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates requests to the HTTP API.

  Every request carries `auth_key`, `auth_timestamp`, `auth_version=1.0`,
  `auth_signature`, and, when there is a body, `body_md5`. The signature is the hex
  HMAC-SHA256, keyed by the app secret, of:

      <UPPERCASE METHOD>\\n<path>\\n<query params except auth_signature, sorted by key, key=value joined with &>

  Values in the string to sign are the decoded parameter values. Timestamps more than
  600 seconds from server time are rejected, as is a body whose MD5 does not match.
  All secret comparisons are constant time.

  On success the app config is in `conn.assigns.app`. Errors are plain text, because
  server SDKs hand the status and body straight to the developer.
  """
  @behaviour Plug

  import Plug.Conn
  require Logger

  alias Arc.Apps.Cache
  alias Arc.Crypto

  @max_skew 600

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    start = System.monotonic_time()
    conn = register_before_send(conn, &record(&1, start))

    params = URI.query_decoder(conn.query_string) |> Enum.to_list()

    with {:ok, app} <- resolve_app(conn, params),
         {:ok, auth} <- required_params(params),
         :ok <- check_key(app, auth.key),
         :ok <- check_version(auth.version),
         :ok <- check_timestamp(auth.timestamp),
         :ok <- check_body(conn.assigns[:raw_body] || "", params),
         :ok <- check_signature(conn, app, params, auth.signature),
         :ok <- check_rate(app) do
      conn
      |> assign(:app, app)
      |> assign(:query, Map.new(params))
    else
      {:error, status, message, reason} ->
        if status == 401 do
          :telemetry.execute([:arc, :auth, :failure], %{count: 1}, %{
            app_id: conn.path_params["app_id"],
            reason: reason
          })

          Logger.info(
            "API request rejected app_id=#{conn.path_params["app_id"]} reason=#{reason}"
          )
        end

        # Unknown ids come from the caller and must not become metric labels.
        label = if status == 404, do: "unknown", else: conn.path_params["app_id"] || "unknown"

        conn
        |> assign(:app_id_label, label)
        |> put_resp_content_type("text/plain")
        |> send_resp(status, message <> "\n")
        |> halt()
    end
  end

  # Most routes carry the app id in the path. Some SDK calls (terminating a user's
  # connections) do not, and the app is identified by its key alone.
  defp resolve_app(%{path_params: %{"app_id" => id}}, _params), do: fetch_app(id)

  defp resolve_app(_conn, params) do
    with {_, key} <- List.keyfind(params, "auth_key", 0),
         %{} = app <- Cache.get_by_key(key) do
      fetch_app(app.id)
    else
      _ -> {:error, 401, "auth_key is missing or does not belong to any app.", "invalid_key"}
    end
  end

  defp fetch_app(id) do
    case Cache.get(id || "") do
      nil -> {:error, 404, "Unknown app id #{inspect(id)}.", "unknown_app"}
      %{enabled: false} -> {:error, 403, "App #{id} is disabled.", "app_disabled"}
      app -> {:ok, app}
    end
  end

  defp required_params(params) do
    lookup = Map.new(params)

    missing =
      Enum.reject(
        ~w(auth_key auth_timestamp auth_version auth_signature),
        &Map.has_key?(lookup, &1)
      )

    if missing == [] do
      {:ok,
       %{
         key: lookup["auth_key"],
         timestamp: lookup["auth_timestamp"],
         version: lookup["auth_version"],
         signature: lookup["auth_signature"]
       }}
    else
      {:error, 401, "Missing required query parameters: #{Enum.join(missing, ", ")}.",
       "missing_params"}
    end
  end

  defp check_key(app, key) do
    if Crypto.secure_compare(app.key, key),
      do: :ok,
      else: {:error, 401, "auth_key does not match this app.", "invalid_key"}
  end

  defp check_version("1.0"), do: :ok
  defp check_version(_), do: {:error, 401, "auth_version must be 1.0.", "invalid_version"}

  defp check_timestamp(timestamp) do
    case Integer.parse(timestamp) do
      {ts, ""} ->
        skew = abs(System.system_time(:second) - ts)

        if skew <= @max_skew,
          do: :ok,
          else:
            {:error, 401,
             "Timestamp expired: auth_timestamp is #{skew} seconds from server time; the limit is #{@max_skew}. Check the clock on the calling server.",
             "timestamp"}

      _ ->
        {:error, 401, "auth_timestamp must be a Unix timestamp in seconds.", "timestamp"}
    end
  end

  defp check_body("", _params), do: :ok

  defp check_body(body, params) do
    case List.keyfind(params, "body_md5", 0) do
      {_, md5} ->
        if Crypto.secure_compare(Crypto.md5_hex(body), String.downcase(md5)),
          do: :ok,
          else: {:error, 401, "body_md5 does not match the MD5 of the request body.", "body_md5"}

      nil ->
        {:error, 401, "Requests with a body must include body_md5.", "body_md5"}
    end
  end

  defp check_signature(conn, app, params, signature) do
    query =
      params
      |> Enum.reject(fn {key, _} -> key == "auth_signature" end)
      |> Enum.sort()
      |> Enum.map_join("&", fn {key, value} -> key <> "=" <> value end)

    # Clients differ in whether they sign the path before or after percent-encoding it;
    # both forms are accepted.
    paths = Enum.uniq([conn.request_path, URI.decode(conn.request_path)])

    if Enum.any?(
         paths,
         &Crypto.valid_hmac?(app.secret, "#{conn.method}\n#{&1}\n#{query}", signature)
       ) do
      :ok
    else
      {:error, 401,
       "Invalid signature: expected HMAC SHA256 hex digest of " <>
         inspect("#{conn.method}\n#{conn.request_path}\n#{query}") <> ".", "invalid_signature"}
    end
  end

  defp check_rate(app) do
    config = Application.fetch_env!(:arc, Arc.Realtime)

    case Arc.RateLimiter.take(
           {:api, app.id},
           Keyword.fetch!(config, :api_rate),
           Keyword.fetch!(config, :api_burst)
         ) do
      :ok ->
        :ok

      {:error, _retry_after} ->
        :telemetry.execute([:arc, :rate_limit, :hit], %{count: 1}, %{app_id: app.id, kind: "api"})

        {:error, 429, "Rate limit exceeded for app #{app.id}. Slow down and retry.",
         "rate_limited"}
    end
  end

  defp record(conn, start) do
    :telemetry.execute(
      [:arc, :api, :request],
      %{duration: System.monotonic_time() - start},
      %{
        app_id:
          (conn.assigns[:app] && conn.assigns.app.id) || conn.assigns[:app_id_label] || "unknown",
        endpoint: endpoint_label(conn),
        status: conn.status
      }
    )

    conn
  end

  defp endpoint_label(conn) do
    case conn.private[:phoenix_action] do
      nil -> "unknown"
      action -> Atom.to_string(action)
    end
  end
end
