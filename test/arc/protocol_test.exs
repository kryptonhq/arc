defmodule Arc.ProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arc.Realtime.{ErrorCodes, Protocol, SocketId}

  test "event names are fixed by the protocol" do
    assert Protocol.version() == 7

    expected = %{
      connection_established: "pusher:connection_established",
      error: "pusher:error",
      ping: "pusher:ping",
      pong: "pusher:pong",
      subscribe: "pusher:subscribe",
      unsubscribe: "pusher:unsubscribe",
      signin: "pusher:signin",
      signin_success: "pusher:signin_success",
      subscription_error: "pusher:subscription_error",
      cache_miss: "pusher:cache_miss",
      subscription_succeeded: "pusher_internal:subscription_succeeded",
      subscription_count: "pusher_internal:subscription_count",
      member_added: "pusher_internal:member_added",
      member_removed: "pusher_internal:member_removed"
    }

    for {key, name} <- expected, do: assert(Protocol.event(key) == name)
  end

  test "client and reserved event detection" do
    assert Protocol.client_event?("client-x")
    refute Protocol.client_event?("x")
    refute Protocol.client_event?(nil)
    assert Protocol.reserved_event?("pusher:x")
    assert Protocol.reserved_event?("pusher_internal:x")
    refute Protocol.reserved_event?("my-event")
  end

  test "frame shapes" do
    established = Jason.decode!(Protocol.connection_established("1.2", 120))
    assert established["event"] == "pusher:connection_established"

    assert Jason.decode!(established["data"]) == %{
             "socket_id" => "1.2",
             "activity_timeout" => 120
           }

    assert Jason.decode!(Protocol.error(4001, "nope")) == %{
             "event" => "pusher:error",
             "data" => %{"code" => 4001, "message" => "nope"}
           }

    assert Jason.decode!(Protocol.subscription_count("c", 3))["data"] ==
             ~s({"subscription_count":3})

    assert Jason.decode!(Protocol.member_added("c", "u", nil))["data"] == ~s({"user_id":"u"})

    assert Jason.decode!(Protocol.member_added("c", "u", %{"a" => 1}))["data"] ==
             ~s({"user_id":"u","user_info":{"a":1}})

    assert Jason.decode!(Protocol.encode("e", "c", "d", user_id: nil)) == %{
             "event" => "e",
             "channel" => "c",
             "data" => "d"
           }

    assert Jason.decode!(Protocol.encode("e", "c", "d", user_id: "u"))["user_id"] == "u"
  end

  test "decode rejects malformed frames" do
    assert {:error, _} = Protocol.decode("nope")
    assert {:error, _} = Protocol.decode("[]")
    assert {:error, _} = Protocol.decode("{}")
    assert {:error, _} = Protocol.decode(~s({"event":"e","channel":1}))
    assert {:ok, %{event: "e", channel: nil, data: nil}} = Protocol.decode(~s({"event":"e"}))
  end

  test "error codes are banded" do
    for {reason, {code, message}} <- ErrorCodes.all() do
      assert is_binary(message)
      assert is_nil(code) or code in 4001..4399, "#{reason}"
      assert ErrorCodes.code(reason) == code
    end

    refute Enum.any?(ErrorCodes.all(), fn {_, {code, _}} -> code == 4000 end)
  end

  test "socket ids" do
    assert SocketId.valid?(SocketId.generate())
    refute SocketId.valid?("1.2.3")
    refute SocketId.valid?(nil)
  end

  defp json_value do
    leaf = one_of([string(:printable, max_length: 20), integer(), boolean(), constant(nil)])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 4),
        map_of(string(:alphanumeric, max_length: 8), child, max_length: 4)
      ])
    end)
  end

  property "frames round-trip through encode and decode" do
    check all(
            event <- string(:printable, min_length: 1, max_length: 40),
            channel <-
              one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 40)]),
            data <- one_of([string(:printable, max_length: 200), json_value()])
          ) do
      assert {:ok, %{event: ^event, channel: ^channel, data: ^data}} =
               event |> Protocol.encode(channel, data) |> Protocol.decode()
    end
  end
end
