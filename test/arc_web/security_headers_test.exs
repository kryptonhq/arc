defmodule ArcWeb.SecurityHeadersTest do
  use ArcWeb.ConnCase, async: false

  test "browser responses carry a Content-Security-Policy", %{conn: conn} do
    conn = get(conn, "/")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "script-src 'self'"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "fonts.googleapis.com"
  end

  test "the session cookie is Secure by default and not on explicit http", %{conn: conn} do
    original = Application.get_env(:arc, :secure_cookies)
    on_exit(fn -> Application.put_env(:arc, :secure_cookies, original) end)

    Application.put_env(:arc, :secure_cookies, true)
    assert ArcWeb.Plugs.Session.options()[:secure]
    assert ArcWeb.Plugs.Session.options()[:http_only]
    conn1 = get(conn, "/auth/login")
    assert conn1.resp_cookies["_arc_key"].secure

    Application.put_env(:arc, :secure_cookies, false)
    refute ArcWeb.Plugs.Session.options()[:secure]
    conn2 = get(build_conn(), "/auth/login")
    refute Map.get(conn2.resp_cookies["_arc_key"], :secure)
  end
end
