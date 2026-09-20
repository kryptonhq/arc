defmodule ArcWeb.Plugs.ClientIpTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ArcWeb.Plugs.ClientIp

  defp req(peer, forwarded) do
    conn = %{conn(:get, "/") | remote_ip: peer}
    Enum.reduce(forwarded, conn, &put_req_header(&2, "x-forwarded-for", &1))
  end

  describe "parse_cidrs/1" do
    test "accepts addresses and CIDRs in both families, ignoring spaces" do
      assert ClientIp.parse_cidrs(" 10.0.0.0/8, 192.168.1.5 ,fd00::/8,::1 ") == [
               {{10, 0, 0, 0}, 8},
               {{192, 168, 1, 5}, 32},
               {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8},
               {{0, 0, 0, 0, 0, 0, 0, 1}, 128}
             ]

      assert ClientIp.parse_cidrs("") == []
    end

    test "rejects junk and out-of-range prefixes by name" do
      assert_raise ArgumentError, ~r/not an IP address/, fn -> ClientIp.parse_cidrs("lb") end
      assert_raise ArgumentError, ~r/bad prefix/, fn -> ClientIp.parse_cidrs("10.0.0.0/33") end
    end
  end

  describe "client_ip/2" do
    test "ignores the header when nothing is trusted" do
      conn = req({10, 0, 0, 1}, ["203.0.113.9"])
      assert ClientIp.client_ip(conn, []) == {10, 0, 0, 1}
    end

    test "ignores the header when the peer is not a trusted proxy" do
      trusted = ClientIp.parse_cidrs("10.0.0.0/8")
      conn = req({192, 168, 0, 7}, ["203.0.113.9"])
      assert ClientIp.client_ip(conn, trusted) == {192, 168, 0, 7}
    end

    test "takes the rightmost address that is not itself a proxy" do
      trusted = ClientIp.parse_cidrs("10.0.0.0/8")
      # A client spoofed the leftmost entry; two proxies appended themselves.
      conn = req({10, 0, 0, 1}, ["1.1.1.1, 203.0.113.9, 10.0.0.2"])
      assert ClientIp.client_ip(conn, trusted) == {203, 0, 113, 9}
    end

    test "falls back to the peer when the header is empty or unparseable" do
      trusted = ClientIp.parse_cidrs("10.0.0.0/8")
      assert ClientIp.client_ip(req({10, 0, 0, 1}, []), trusted) == {10, 0, 0, 1}
      assert ClientIp.client_ip(req({10, 0, 0, 1}, ["nope"]), trusted) == {10, 0, 0, 1}
      # Every entry is a proxy: the peer stays.
      assert ClientIp.client_ip(req({10, 0, 0, 1}, ["10.0.0.3"]), trusted) == {10, 0, 0, 1}
    end

    test "handles IPv6 and never matches across families" do
      trusted = ClientIp.parse_cidrs("fd00::/8")
      v6_peer = {0xFD00, 0, 0, 0, 0, 0, 0, 1}

      assert ClientIp.client_ip(req(v6_peer, ["2001:db8::5"]), trusted) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 5}

      assert ClientIp.client_ip(req({10, 0, 0, 1}, ["2001:db8::5"]), trusted) == {10, 0, 0, 1}
    end
  end

  test "the plug rewrites remote_ip and tags the logger" do
    original = Application.get_env(:arc, :trusted_proxies)
    Application.put_env(:arc, :trusted_proxies, ClientIp.parse_cidrs("127.0.0.1"))
    on_exit(fn -> Application.put_env(:arc, :trusted_proxies, original) end)

    conn = req({127, 0, 0, 1}, ["203.0.113.9"]) |> ClientIp.call(ClientIp.init([]))
    assert conn.remote_ip == {203, 0, 113, 9}
    assert Logger.metadata()[:client_ip] == "203.0.113.9"
  end
end
