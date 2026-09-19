defmodule Arc.Test.Fixtures do
  @moduledoc "Test data and helpers shared across suites."

  alias Arc.Apps

  def app_fixture(attrs \\ %{}) do
    {:ok, app, _secret} =
      Apps.create_app(
        Map.merge(%{"name" => "test app #{System.unique_integer([:positive])}"}, attrs)
      )

    app
  end

  @doc "App fixture plus its cached runtime config."
  def app_config_fixture(attrs \\ %{}) do
    app = app_fixture(attrs)
    {app, Apps.get_config(app.id)}
  end

  @doc """
  Signs an API request exactly as the server SDKs do, independently of the server
  implementation. Returns the full path with query string.
  """
  def signed_path(config, method, path, body \\ "", params \\ %{}) do
    params =
      params
      |> Map.merge(%{
        "auth_key" => config.key,
        "auth_timestamp" => Integer.to_string(System.system_time(:second)),
        "auth_version" => "1.0"
      })
      |> then(fn params ->
        if body == "", do: params, else: Map.put(params, "body_md5", md5(body))
      end)

    query = params |> Enum.sort() |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

    signature =
      :crypto.mac(:hmac, :sha256, config.secret, "#{method}\n#{path}\n#{query}")
      |> Base.encode16(case: :lower)

    path <> "?" <> URI.encode_query(Map.put(params, "auth_signature", signature))
  end

  defp md5(body), do: :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
end
