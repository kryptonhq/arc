defmodule Arc.Test.FakeIdP do
  @moduledoc """
  A minimal OpenID provider over HTTP for exercising the real `oidcc` adapter:
  discovery, JWKS, and a token endpoint that returns an RS256-signed ID token. The
  claims (and the key they are signed with) are set per test.
  """
  @behaviour Plug

  import Plug.Conn

  def start do
    jwk =
      JOSE.JWK.generate_key({:rsa, 2048})
      |> JOSE.JWK.merge(%{"kid" => "test-key", "use" => "sig", "alg" => "RS256"})

    {:ok, agent} = Agent.start(fn -> %{jwk: jwk, sign_with: jwk, claims: %{}} end)

    {:ok, server} =
      Bandit.start_link(plug: {__MODULE__, agent}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{agent: agent, server: server, issuer: "http://127.0.0.1:#{port}/realms/test"}
  end

  @doc "Claims for the next token response; `:sign_with` may be another JWK to forge a signature."
  def set(idp, claims, opts \\ []) do
    Agent.update(idp.agent, fn state ->
      %{state | claims: claims, sign_with: Keyword.get(opts, :sign_with, state.jwk)}
    end)
  end

  @impl true
  def init(agent), do: agent

  @impl true
  def call(conn, agent) do
    state = Agent.get(agent, & &1)
    issuer = "http://#{conn.host}:#{conn.port}/realms/test"

    case conn.path_info do
      ["realms", "test", ".well-known", "openid-configuration"] ->
        json(conn, %{
          issuer: issuer,
          authorization_endpoint: issuer <> "/auth",
          token_endpoint: issuer <> "/token",
          jwks_uri: issuer <> "/jwks",
          userinfo_endpoint: issuer <> "/userinfo",
          end_session_endpoint: issuer <> "/logout",
          response_types_supported: ["code"],
          subject_types_supported: ["public"],
          id_token_signing_alg_values_supported: ["RS256"],
          token_endpoint_auth_methods_supported: ["client_secret_basic", "client_secret_post"],
          code_challenge_methods_supported: ["S256"],
          scopes_supported: ["openid", "email", "profile"]
        })

      ["realms", "test", "jwks"] ->
        {_, public} = state.jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
        json(conn, %{keys: [public]})

      ["realms", "test", "token"] ->
        now = System.system_time(:second)

        claims =
          Map.merge(
            %{"iss" => issuer, "aud" => "arc-dashboard", "iat" => now, "exp" => now + 300},
            state.claims
          )

        {_, id_token} =
          state.sign_with
          |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test-key"}, claims)
          |> JOSE.JWS.compact()

        json(conn, %{
          access_token: "at",
          token_type: "Bearer",
          expires_in: 300,
          id_token: id_token
        })

      _ ->
        send_resp(conn, 404, "")
    end
  end

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end
end
