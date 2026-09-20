defmodule Arc.Admin.OIDC do
  @moduledoc """
  The authorization-code flow with PKCE against the configured OIDC provider
  (Keycloak in the reference deployment).

  The implementation is chosen by `config :arc, :oidc_adapter`, so tests can stand in
  for the provider. The production adapter, `Arc.Admin.OIDC.Oidcc`, validates the ID
  token signature against the provider's JWKS and checks `iss`, `aud`, `exp`, and
  `nonce` before any claim is trusted.
  """

  @type flow :: %{state: String.t(), nonce: String.t(), pkce_verifier: String.t()}

  @callback authorize_url(redirect_uri :: String.t(), flow()) ::
              {:ok, String.t()} | {:error, term()}
  @callback exchange(code :: String.t(), redirect_uri :: String.t(), flow()) ::
              {:ok, claims :: map()} | {:error, term()}
  @callback logout_url(post_logout_redirect_uri :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Fresh random values for one sign-in attempt."
  @spec new_flow() :: flow()
  def new_flow do
    %{state: random(), nonce: random(), pkce_verifier: random(48)}
  end

  def authorize_url(redirect_uri, flow), do: adapter().authorize_url(redirect_uri, flow)
  def exchange(code, redirect_uri, flow), do: adapter().exchange(code, redirect_uri, flow)
  def logout_url(redirect_uri), do: adapter().logout_url(redirect_uri)

  @doc """
  True when an identity provider is configured. It is optional once
  `ARC_ADMIN_PASSWORD` is set; without it the dashboard offers the password form only.
  """
  def configured? do
    case Application.get_env(:arc, :oidc, [])[:issuer] do
      issuer when is_binary(issuer) and issuer != "" -> true
      _ -> false
    end
  end

  @doc "Child specs for the adapter's own processes, if it has any."
  def child_specs do
    if configured?() and function_exported?(adapter(), :child_specs, 0),
      do: adapter().child_specs(),
      else: []
  end

  defp adapter, do: Application.get_env(:arc, :oidc_adapter, Arc.Admin.OIDC.Oidcc)

  defp random(bytes \\ 32),
    do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
end
