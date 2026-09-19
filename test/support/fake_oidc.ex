defmodule Arc.Test.FakeOIDC do
  @moduledoc """
  Stands in for the identity provider in tests. The claims returned by `exchange/3`
  are whatever the test stored for the authorization code with `put_claims/2`; the
  nonce is checked just as the real adapter checks it in the ID token.
  """
  @behaviour Arc.Admin.OIDC

  def put_claims(code, claims), do: :persistent_term.put({__MODULE__, code}, claims)

  @impl true
  def authorize_url(redirect_uri, flow) do
    {:ok,
     "https://idp.test/auth?" <>
       URI.encode_query(%{
         redirect_uri: redirect_uri,
         state: flow.state,
         nonce: flow.nonce,
         code_challenge: "x"
       })}
  end

  @impl true
  def exchange(code, _redirect_uri, flow) do
    case :persistent_term.get({__MODULE__, code}, nil) do
      nil ->
        {:error, :invalid_grant}

      %{"nonce" => nonce} = claims ->
        if nonce == flow.nonce, do: {:ok, claims}, else: {:error, :nonce_mismatch}

      claims ->
        {:ok, claims}
    end
  end

  @impl true
  def logout_url(redirect_uri),
    do:
      {:ok,
       "https://idp.test/logout?post_logout_redirect_uri=" <> URI.encode_www_form(redirect_uri)}
end
