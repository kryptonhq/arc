defmodule ArcWeb.AdminTest do
  use ArcWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arc.{Apps, Audit, Webhooks}
  alias Arc.Test.FakeOIDC

  defp sign_in(conn, email \\ "admin@example.com") do
    conn = get(conn, ~p"/auth/login")
    %{query: query} = URI.parse(redirected_to(conn, 302))
    %{"state" => state, "nonce" => nonce} = URI.decode_query(query)
    code = "code-#{System.unique_integer([:positive])}"

    FakeOIDC.put_claims(code, %{
      "sub" => "sub-1",
      "email" => email,
      "email_verified" => true,
      "nonce" => nonce
    })

    conn |> recycle() |> get(~p"/auth/callback?#{[code: code, state: state]}")
  end

  defp signed_in(%{conn: conn}) do
    conn = sign_in(conn)
    assert redirected_to(conn) == "/admin"
    %{conn: recycle(conn)}
  end

  describe "sign-in" do
    test "unauthenticated requests are sent to the identity provider", %{conn: conn} do
      for path <- [
            "/admin",
            "/admin/apps",
            "/admin/apps/new",
            "/admin/audit",
            "/admin/apps/1/webhooks"
          ] do
        assert redirected_to(get(build_conn(), path)) == "/auth/login"
      end

      conn = get(conn, ~p"/auth/login")
      assert redirected_to(conn) =~ "https://idp.test/auth?"
      assert redirected_to(conn) =~ "state="
    end

    test "an allowlisted, verified email signs in and returns to the requested page", %{
      conn: conn
    } do
      conn = get(conn, ~p"/admin/audit") |> recycle()
      conn = sign_in(conn)
      assert redirected_to(conn) == "/admin/audit"
      assert [%{email: "admin@example.com", subject: "sub-1"}] = Arc.Admin.list_admins()

      conn = conn |> recycle() |> get(~p"/admin/audit")
      assert html_response(conn, 200) =~ "Audit log"
    end

    test "email matching is case-insensitive", %{conn: conn} do
      conn = sign_in(conn, "Admin@Example.com")
      assert redirected_to(conn) == "/admin"
    end

    test "emails outside the allowlist get a 403", %{conn: conn} do
      conn = sign_in(conn, "intruder@example.com")
      assert html_response(conn, 403) =~ "not on this Arc installation"
      assert Arc.Admin.list_admins() == []
    end

    test "unverified emails get a 403", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")

      %{"state" => state, "nonce" => nonce} =
        URI.decode_query(URI.parse(redirected_to(conn)).query)

      FakeOIDC.put_claims("unverified", %{
        "sub" => "s",
        "email" => "admin@example.com",
        "email_verified" => false,
        "nonce" => nonce
      })

      conn = conn |> recycle() |> get(~p"/auth/callback?#{[code: "unverified", state: state]}")
      assert html_response(conn, 403) =~ "not been verified"

      conn = get(recycle(conn), ~p"/auth/login")

      %{"state" => state, "nonce" => nonce} =
        URI.decode_query(URI.parse(redirected_to(conn)).query)

      FakeOIDC.put_claims("no-email", %{"sub" => "s", "nonce" => nonce})
      conn = conn |> recycle() |> get(~p"/auth/callback?#{[code: "no-email", state: state]}")
      assert html_response(conn, 403) =~ "email"
    end

    test "a mismatched state, a bad code, or a replayed callback is rejected", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")
      %{"nonce" => nonce} = URI.decode_query(URI.parse(redirected_to(conn)).query)

      FakeOIDC.put_claims("good", %{
        "sub" => "s",
        "email" => "admin@example.com",
        "email_verified" => true,
        "nonce" => nonce
      })

      bad_state = conn |> recycle() |> get(~p"/auth/callback?#{[code: "good", state: "forged"]}")
      assert html_response(bad_state, 400) =~ "invalid or expired"

      # The flow was consumed by the failed attempt; replaying fails too.
      replay =
        bad_state |> recycle() |> get(~p"/auth/callback?#{[code: "good", state: "forged"]}")

      assert html_response(replay, 400)

      assert html_response(get(build_conn(), ~p"/auth/callback"), 400)
    end

    test "a nonce mismatch is rejected", %{conn: conn} do
      conn = get(conn, ~p"/auth/login")
      %{"state" => state} = URI.decode_query(URI.parse(redirected_to(conn)).query)

      FakeOIDC.put_claims("other-nonce", %{
        "sub" => "s",
        "email" => "admin@example.com",
        "email_verified" => true,
        "nonce" => "x"
      })

      assert html_response(
               conn
               |> recycle()
               |> get(~p"/auth/callback?#{[code: "other-nonce", state: state]}"),
               400
             )
    end

    test "sessions expire after 12 hours", %{conn: conn} do
      conn = sign_in(conn) |> recycle()
      expired = System.system_time(:second) - ArcWeb.AdminAuth.max_age() - 1

      conn =
        conn
        |> init_test_session(%{"admin_email" => "admin@example.com", "signed_in_at" => expired})
        |> get(~p"/admin/audit")

      assert redirected_to(conn) == "/auth/login"
    end

    test "removing an email from the allowlist revokes access at once", %{conn: conn} do
      conn = sign_in(conn) |> recycle()
      original = Application.fetch_env!(:arc, :oidc)
      Application.put_env(:arc, :oidc, Keyword.put(original, :admin_emails, ["someone@else.com"]))
      on_exit(fn -> Application.put_env(:arc, :oidc, original) end)

      assert redirected_to(get(conn, ~p"/admin/audit")) == "/auth/login"
    end

    test "sign-out clears the session and ends the provider session", %{conn: conn} do
      conn = sign_in(conn) |> recycle() |> get(~p"/auth/logout")
      assert redirected_to(conn) =~ "https://idp.test/logout"
      assert redirected_to(conn |> recycle() |> get(~p"/admin")) == "/auth/login"
    end

    test "/ redirects to the dashboard", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/")) == "/admin"
    end

    test "the LiveView on_mount hook rejects sockets without a valid session" do
      socket = %Phoenix.LiveView.Socket{}
      assert {:halt, _} = ArcWeb.AdminAuth.on_mount(:require_admin, %{}, %{}, socket)

      stale = %{"admin_email" => "admin@example.com", "signed_in_at" => 0}
      assert {:halt, _} = ArcWeb.AdminAuth.on_mount(:require_admin, %{}, stale, socket)
    end
  end

  describe "apps" do
    setup :signed_in

    test "create shows the secret once with snippets", %{conn: conn} do
      assert html_response(get(conn, ~p"/admin/apps/new"), 200) =~ "New app"

      conn =
        post(conn, ~p"/admin/apps", %{
          "app" => %{"name" => "Chat", "client_events_enabled" => "true"}
        })

      html = html_response(conn, 200)
      [app] = Apps.list_apps()

      assert html =~ app.secret
      assert html =~ "the only time it is shown"
      assert html =~ "&quot;app_id&quot;: &quot;#{app.id}&quot;"
      assert html =~ "&quot;secret&quot;: &quot;#{app.secret}&quot;"
      assert html =~ "pusher.Pusher(**settings.ARC)"
      assert html =~ "new Pusher(&quot;#{app.key}&quot;"
      refute html =~ ~s(data-to="/admin/apps/#{app.id}")

      show = conn |> recycle() |> get(~p"/admin/apps/#{app.id}") |> html_response(200)
      refute show =~ app.secret
      assert show =~ app.key

      assert [%{action: "app.created", admin_user: %{email: "admin@example.com"}}] =
               Audit.list(app_id: app.id)
    end

    test "invalid input re-renders the form", %{conn: conn} do
      assert html_response(post(conn, ~p"/admin/apps", %{"app" => %{"name" => ""}}), 422) =~
               "blank"
    end

    test "settings can be edited", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()
      assert html_response(get(conn, ~p"/admin/apps/#{app.id}/edit"), 200) =~ "Settings"

      conn =
        put(conn, ~p"/admin/apps/#{app.id}", %{
          "app" => %{"name" => "Renamed", "max_presence_members" => "5"}
        })

      assert redirected_to(conn) == "/admin/apps/#{app.id}"
      assert Apps.get_config(app.id).max_presence_members == 5

      assert html_response(
               put(recycle(conn), ~p"/admin/apps/#{app.id}", %{
                 "app" => %{"max_payload_bytes" => "1"}
               }),
               422
             )
    end

    test "rotation shows the new secret and invalidates the old one", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()
      html = conn |> post(~p"/admin/apps/#{app.id}/rotate") |> html_response(200)
      new_secret = Apps.get_app!(app.id).secret

      refute new_secret == app.secret
      assert html =~ new_secret
      assert Apps.get_config(app.id).secret == new_secret
      assert Enum.any?(Audit.list(app_id: app.id), &(&1.action == "app.secret_rotated"))
    end

    test "encryption keys can be generated and removed", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()

      html =
        conn
        |> post(~p"/admin/apps/#{app.id}/encryption_key?action=generate")
        |> html_response(200)

      key = Apps.get_app!(app.id).encryption_master_key
      assert html =~ Base.encode64(key)

      conn = conn |> recycle() |> post(~p"/admin/apps/#{app.id}/encryption_key?action=remove")
      assert redirected_to(conn) == "/admin/apps/#{app.id}"
      assert Apps.get_app!(app.id).encryption_master_key == nil
    end

    test "apps can be deleted", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()
      assert redirected_to(delete(conn, ~p"/admin/apps/#{app.id}")) == "/admin/apps"
      assert Apps.get_app(app.id) == nil
    end
  end

  describe "webhooks" do
    setup :signed_in

    test "endpoint CRUD and the delivery log", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()

      assert html_response(get(conn, ~p"/admin/apps/#{app.id}/webhooks"), 200) =~
               "No endpoints yet"

      bad =
        post(conn, ~p"/admin/apps/#{app.id}/webhooks", %{
          "endpoint" => %{"url" => "nope", "events" => [""]}
        })

      assert html_response(bad, 422) =~ "select at least one event type"

      conn =
        post(recycle(conn), ~p"/admin/apps/#{app.id}/webhooks", %{
          "endpoint" => %{
            "url" => "https://example.com/hook",
            "events" => ["", "channel_occupied"]
          }
        })

      assert redirected_to(conn) == "/admin/apps/#{app.id}/webhooks"
      [endpoint] = Webhooks.list_endpoints(app.id)
      assert endpoint.events == ["channel_occupied"]

      Arc.Repo.insert!(%Arc.Webhooks.Delivery{
        app_id: app.id,
        endpoint_id: endpoint.id,
        payload: %{"events" => [%{"name" => "channel_occupied"}]},
        status: "failed",
        attempts: 6,
        last_error: "HTTP 500"
      })

      html = conn |> recycle() |> get(~p"/admin/apps/#{app.id}/webhooks") |> html_response(200)
      assert html =~ "https://example.com/hook"
      assert html =~ "HTTP 500"

      assert html_response(
               get(recycle(conn), ~p"/admin/apps/#{app.id}/webhooks/#{endpoint.id}/edit"),
               200
             ) =~ "Edit webhook"

      conn =
        put(recycle(conn), ~p"/admin/apps/#{app.id}/webhooks/#{endpoint.id}", %{
          "endpoint" => %{
            "url" => "https://example.com/v2",
            "events" => ["", "member_added"],
            "active" => "false"
          }
        })

      assert redirected_to(conn) =~ "/webhooks"

      assert %{url: "https://example.com/v2", events: ["member_added"], active: false} =
               Webhooks.get_endpoint!(app.id, endpoint.id)

      assert html_response(
               put(recycle(conn), ~p"/admin/apps/#{app.id}/webhooks/#{endpoint.id}", %{
                 "endpoint" => %{"url" => "x", "events" => [""]}
               }),
               422
             )

      conn = delete(recycle(conn), ~p"/admin/apps/#{app.id}/webhooks/#{endpoint.id}")
      assert redirected_to(conn) =~ "/webhooks"
      assert Webhooks.list_endpoints(app.id) == []
    end
  end

  describe "audit and live pages" do
    setup :signed_in

    test "the audit log pages newest first", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()
      html = conn |> get(~p"/admin/audit") |> html_response(200)
      assert html =~ "app.created"
      assert html =~ to_string(app.id)
      assert html_response(get(recycle(conn), ~p"/admin/audit?page=abc"), 200)
      assert html_response(get(recycle(conn), ~p"/admin/audit?page=2"), 200) =~ "Newer"
    end

    test "overview and app list update from aggregator broadcasts", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()
      {:ok, overview, html} = live(conn, ~p"/admin")
      assert html =~ "Connections"

      {:ok, apps, html} = live(recycle(conn), ~p"/admin/apps")
      assert html =~ app.name

      stats = %{
        connections: 42,
        messages_per_second: 7,
        apps: %{app.id => %{connections: 5, channels: 1, subscriptions: 3}},
        nodes: [%{name: :a@b, connections: 42, memory: 1_048_576, run_queue: 0}]
      }

      Phoenix.PubSub.broadcast(Arc.PubSub, Arc.Metrics.Aggregator.topic(), {:arc_stats, stats})

      assert render(overview) =~ "42"
      assert element(overview, "#stat-mps") |> render() =~ "7"
      assert render(overview) =~ "1.0 MB"
      assert element(apps, "#app-#{app.id}-connections") |> render() =~ "5"
    end

    test "the app page shows channels on demand and never the secret", %{conn: conn} do
      app = Arc.Test.Fixtures.app_fixture()
      {:ok, view, html} = live(conn, ~p"/admin/apps/#{app.id}")
      refute html =~ app.secret
      assert html =~ "No occupied channels"

      :ets.insert(:arc_channel_subscriptions, {{app.id, "presence-lobby"}, 3})
      on_exit(fn -> :ets.delete(:arc_channel_subscriptions, {app.id, "presence-lobby"}) end)

      assert view |> element("button", "Refresh") |> render_click() =~ "presence-lobby"

      Phoenix.PubSub.broadcast(
        Arc.PubSub,
        Arc.Metrics.Aggregator.topic(),
        {:arc_stats,
         %{
           connections: 1,
           messages_per_second: 0,
           nodes: [],
           apps: %{app.id => %{connections: 9, channels: 1, subscriptions: 3}}
         }}
      )

      assert element(view, "#app-connections") |> render() =~ "9"
    end
  end
end
