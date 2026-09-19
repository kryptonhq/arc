defmodule Arc.Admin.OIDC.Oidcc do
  @moduledoc """
  OIDC adapter backed by `oidcc`. Provider discovery and JWKS are loaded and refreshed
  by a supervised configuration worker.
  """
  @behaviour Arc.Admin.OIDC

  @provider Arc.Admin.OIDCProvider
  @scopes ["openid", "email", "profile"]

  # The dashboard is registered as a confidential client with a client secret. Without
  # this, oidcc would try JWT-based client authentication first, which a plain
  # secret-authenticated Keycloak client rejects.
  @auth_methods [:client_secret_basic, :client_secret_post]

  def child_specs do
    issuer = Keyword.fetch!(config(), :issuer)

    # Plain-HTTP providers are only acceptable for local development (the compose
    # stack's Keycloak); anything else must be HTTPS.
    quirks = if String.starts_with?(issuer, "http://"), do: %{allow_unsafe_http: true}, else: %{}

    [
      {Arc.Admin.OIDC.ProviderKeeper,
       %{issuer: issuer, name: @provider, provider_configuration_opts: %{quirks: quirks}}}
    ]
  end

  @impl true
  def authorize_url(redirect_uri, flow) do
    config = config()

    Oidcc.create_redirect_url(@provider, config[:client_id], config[:client_secret], %{
      redirect_uri: redirect_uri,
      scopes: @scopes,
      state: flow.state,
      nonce: flow.nonce,
      pkce_verifier: flow.pkce_verifier,
      require_pkce: true,
      preferred_auth_methods: @auth_methods
    })
    |> case do
      {:ok, url} -> {:ok, IO.iodata_to_binary(url)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  @impl true
  def exchange(code, redirect_uri, flow) do
    config = config()

    case Oidcc.retrieve_token(code, @provider, config[:client_id], config[:client_secret], %{
           redirect_uri: redirect_uri,
           nonce: flow.nonce,
           pkce_verifier: flow.pkce_verifier,
           require_pkce: true,
           preferred_auth_methods: @auth_methods
         }) do
      {:ok, %Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}} -> {:ok, claims}
      {:ok, _token} -> {:error, :no_id_token}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  @impl true
  def logout_url(redirect_uri) do
    config = config()

    case Oidcc.initiate_logout_url(:undefined, @provider, config[:client_id], %{
           post_logout_redirect_uri: redirect_uri
         }) do
      {:ok, url} -> {:ok, IO.iodata_to_binary(url)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:provider_unavailable, reason}}
  end

  defp config, do: Application.fetch_env!(:arc, :oidc)
end
