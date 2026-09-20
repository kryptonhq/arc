defmodule ArcWeb.PasswordAuthTest do
  use ArcWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @password "correct horse battery staple"

  defp enable(_ctx) do
    original = Application.get_env(:arc, :admin_password)
    Application.put_env(:arc, :admin_password, @password)
    on_exit(fn -> Application.put_env(:arc, :admin_password, original) end)
    Arc.RateLimiter.reset({:password, {127, 0, 0, 1}})
    :ok
  end

  defp without_oidc(_ctx) do
    original = Application.get_env(:arc, :oidc)
    Application.put_env(:arc, :oidc, Keyword.put(original, :issuer, nil))
    on_exit(fn -> Application.put_env(:arc, :oidc, original) end)
    :ok
  end

  describe "with the mode off" do
    setup do
      Arc.RateLimiter.reset({:password, {127, 0, 0, 1}})
      on_exit(fn -> Arc.RateLimiter.reset({:password, {127, 0, 0, 1}}) end)
    end

    test "the login page is the provider redirect and the form does nothing", %{conn: conn} do
      refute Arc.Admin.password_enabled?()
      assert redirected_to(get(conn, ~p"/auth/login")) =~ "https://idp.test/auth?"

      conn = post(conn, ~p"/auth/password", %{"password" => "anything at all here"})
      assert html_response(conn, 401) =~ "not right"
      assert Arc.Admin.list_admins() == []
      assert Arc.Admin.password_email() == nil
    end
  end

  describe "with the mode on" do
    setup :enable

    test "the login page offers both ways in", %{conn: conn} do
      html = html_response(get(conn, ~p"/auth/login"), 200)
      assert html =~ "identity provider"
      assert html =~ ~s(action="/auth/password")
      assert html =~ "_csrf_token"

      # The provider link still starts the OIDC flow.
      assert redirected_to(get(conn, ~p"/auth/oidc")) =~ "https://idp.test/auth?"
    end

    test "the right password signs in as the first allowlisted email and returns to the page",
         %{conn: conn} do
      conn = get(conn, ~p"/admin/audit") |> recycle()
      conn = post(conn, ~p"/auth/password", %{"password" => @password})
      assert redirected_to(conn) == "/admin/audit"

      assert [%{email: "admin@example.com", subject: "password"}] = Arc.Admin.list_admins()
      html = conn |> recycle() |> get(~p"/admin/audit") |> html_response(200)
      assert html =~ "Audit log"
      assert html =~ "Password sign-in is enabled"
    end

    test "a wrong password is 401, logged with the address and without the value", %{conn: conn} do
      log =
        capture_log(fn ->
          conn = post(conn, ~p"/auth/password", %{"password" => "nope nope nope nope"})
          assert html_response(conn, 401) =~ "not right"
          assert get_session(conn, :admin_email) == nil
        end)

      assert log =~ "password sign-in failed client_ip=127.0.0.1"
      refute log =~ "nope nope"
      assert Arc.Admin.list_admins() == []
    end

    test "a missing password field is a plain 401", %{conn: conn} do
      assert html_response(post(conn, ~p"/auth/password", %{}), 401) =~ "not right"
    end

    test "the sixth attempt in a minute is rate limited", %{conn: conn} do
      Arc.RateLimiter.reset({:password, {127, 0, 0, 1}})

      for _ <- 1..5 do
        assert post(build_conn(), ~p"/auth/password", %{"password" => "wrong wrong wrong"}).status ==
                 401
      end

      log =
        capture_log(fn ->
          conn = post(conn, ~p"/auth/password", %{"password" => @password})
          assert response(conn, 429) =~ "Too many sign-in attempts"
        end)

      assert log =~ "rate limited client_ip=127.0.0.1"
    end

    test "signing out of a password session lands on the home page", %{conn: conn} do
      conn = post(conn, ~p"/auth/password", %{"password" => @password})
      # OIDC is configured in tests, so sign-out still ends the provider session.
      assert redirected_to(get(recycle(conn), ~p"/auth/logout")) =~ "idp.test/logout"
    end
  end

  describe "with the mode on and no identity provider" do
    setup [:enable, :without_oidc]

    test "the login page shows only the form, sign-out stays local, no provider processes",
         %{conn: conn} do
      refute Arc.Admin.OIDC.configured?()
      assert Arc.Admin.OIDC.child_specs() == []

      html = html_response(get(conn, ~p"/auth/login"), 200)
      refute html =~ "identity provider</a>"
      assert html =~ ~s(action="/auth/password")

      assert redirected_to(get(conn, ~p"/auth/oidc")) == "/auth/login"

      conn = post(conn, ~p"/auth/password", %{"password" => @password})
      assert redirected_to(conn) == "/admin"
      assert redirected_to(get(recycle(conn), ~p"/auth/logout")) == "/"
    end

    test "with an empty allowlist the password admin is admin@localhost" do
      original = Application.get_env(:arc, :oidc)
      Application.put_env(:arc, :oidc, Keyword.put(original, :admin_emails, []))
      on_exit(fn -> Application.put_env(:arc, :oidc, original) end)

      assert Arc.Admin.password_email() == "admin@localhost"
      assert Arc.Admin.allowed?("admin@localhost")
      assert {:ok, %{email: "admin@localhost"}} = Arc.Admin.password_sign_in(@password)
      assert Arc.Admin.get_by_email("admin@localhost")
      assert {:error, :invalid} = Arc.Admin.password_sign_in(nil)
    end
  end
end
