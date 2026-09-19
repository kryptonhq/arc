defmodule Arc.OIDCAdapterTest do
  @moduledoc "The production OIDC adapter against a local provider with real signed tokens."
  use ArcWeb.ConnCase, async: false

  alias Arc.Admin.OIDC
  alias Arc.Admin.OIDC.Oidcc, as: Adapter
  alias Arc.Test.FakeIdP

  @redirect "http://localhost:4002/auth/callback"

  setup do
    idp = FakeIdP.start()
    original = Application.fetch_env!(:arc, :oidc)

    Application.put_env(
      :arc,
      :oidc,
      Keyword.merge(original, issuer: idp.issuer, client_id: "arc-dashboard", client_secret: "s")
    )

    on_exit(fn -> Application.put_env(:arc, :oidc, original) end)

    [spec] = Adapter.child_specs()
    start_supervised!(spec)
    wait_for_provider()
    %{idp: idp}
  end

  defp wait_for_provider(attempts \\ 50) do
    case Adapter.authorize_url(@redirect, OIDC.new_flow()) do
      {:ok, _} -> :ok
      _ when attempts > 0 -> Process.sleep(50) && wait_for_provider(attempts - 1)
    end
  end

  test "authorize_url carries state, nonce, and a PKCE challenge" do
    flow = OIDC.new_flow()
    {:ok, url} = Adapter.authorize_url(@redirect, flow)
    query = URI.decode_query(URI.parse(url).query)

    assert query["state"] == flow.state
    assert query["nonce"] == flow.nonce
    assert query["code_challenge_method"] == "S256"
    assert query["code_challenge"] != nil
    assert query["redirect_uri"] == @redirect
  end

  test "a valid ID token yields its claims", %{idp: idp} do
    flow = OIDC.new_flow()

    FakeIdP.set(idp, %{
      "sub" => "u1",
      "email" => "admin@example.com",
      "email_verified" => true,
      "nonce" => flow.nonce
    })

    assert {:ok, %{"email" => "admin@example.com", "sub" => "u1"}} =
             Adapter.exchange("code", @redirect, flow)
  end

  test "a wrong nonce, audience, expiry, or signature is rejected", %{idp: idp} do
    flow = OIDC.new_flow()

    base = %{
      "sub" => "u1",
      "email" => "admin@example.com",
      "email_verified" => true,
      "nonce" => flow.nonce
    }

    FakeIdP.set(idp, %{base | "nonce" => "other"})
    assert {:error, _} = Adapter.exchange("code", @redirect, flow)

    FakeIdP.set(idp, Map.put(base, "aud", "someone-else"))
    assert {:error, _} = Adapter.exchange("code", @redirect, flow)

    FakeIdP.set(idp, Map.put(base, "exp", System.system_time(:second) - 600))
    assert {:error, _} = Adapter.exchange("code", @redirect, flow)

    forger = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.merge(%{"kid" => "test-key"})
    FakeIdP.set(idp, base, sign_with: forger)
    assert {:error, _} = Adapter.exchange("code", @redirect, flow)
  end

  test "logout goes to the end-session endpoint" do
    assert {:ok, url} = Adapter.logout_url("http://localhost:4002/")
    assert url =~ "/realms/test/logout"
    assert url =~ "post_logout_redirect_uri"
  end

  test "sign-in through the controller with the real adapter", %{conn: conn, idp: idp} do
    Application.put_env(:arc, :oidc_adapter, Adapter)
    on_exit(fn -> Application.put_env(:arc, :oidc_adapter, Arc.Test.FakeOIDC) end)

    conn = get(conn, ~p"/auth/login")
    %{"state" => state, "nonce" => nonce} = URI.decode_query(URI.parse(redirected_to(conn)).query)

    FakeIdP.set(idp, %{
      "sub" => "kc-1",
      "email" => "admin@example.com",
      "email_verified" => true,
      "nonce" => nonce
    })

    conn = conn |> recycle() |> get(~p"/auth/callback?#{[code: "c", state: state]}")
    assert redirected_to(conn) == "/admin"
    assert html_response(conn |> recycle() |> get(~p"/admin/audit"), 200)
  end
end

defmodule Arc.OIDCUnavailableTest do
  @moduledoc "An unreachable identity provider affects sign-in only."
  use ArcWeb.ConnCase, async: false

  alias Arc.Admin.OIDC.Oidcc, as: Adapter

  test "sign-in answers 503 and the keeper keeps retrying without crashing", %{conn: conn} do
    original = Application.fetch_env!(:arc, :oidc)

    Application.put_env(
      :arc,
      :oidc,
      Keyword.put(original, :issuer, "http://127.0.0.1:1/realms/none")
    )

    Application.put_env(:arc, :oidc_adapter, Adapter)

    on_exit(fn ->
      Application.put_env(:arc, :oidc, original)
      Application.put_env(:arc, :oidc_adapter, Arc.Test.FakeOIDC)
    end)

    [spec] = Adapter.child_specs()
    keeper = start_supervised!(spec)
    Process.sleep(200)
    assert Process.alive?(keeper)

    assert html_response(get(conn, ~p"/auth/login"), 503) =~ "not reachable"
    assert {:error, _} = Adapter.exchange("c", "http://x", Arc.Admin.OIDC.new_flow())
    assert {:error, _} = Adapter.logout_url("http://x")
    assert redirected_to(get(build_conn(), ~p"/auth/logout")) == "/"

    send(keeper, :start)
    send(keeper, {:EXIT, self(), :unrelated})
    Process.sleep(50)
    assert Process.alive?(keeper)
  end
end
