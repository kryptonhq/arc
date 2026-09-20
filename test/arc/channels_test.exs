defmodule Arc.ChannelsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arc.Channels.{Auth, Channel}

  @charset Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_, ?-, ?=, ?@, ?,, ?., ?;]])

  describe "parse/1" do
    test "detects every channel type" do
      for {name, type} <- [
            {"chat", :public},
            {"private-chat", :private},
            {"private-encrypted-chat", :private_encrypted},
            {"presence-room", :presence},
            {"cache-state", :cache},
            {"private-cache-state", :private_cache},
            {"presence-cache-room", :presence_cache},
            {"#server-to-user-42", :user}
          ] do
        assert {:ok, %Channel{name: ^name, type: ^type}} = Channel.parse(name)
      end
    end

    test "rejects invalid names instead of normalising them" do
      assert {:error, _} = Channel.parse("")
      assert {:error, _} = Channel.parse("has space")
      assert {:error, _} = Channel.parse("emoji-🎉")
      assert {:error, _} = Channel.parse("slash/name")
      assert {:error, _} = Channel.parse(String.duplicate("a", 165))
      assert {:ok, _} = Channel.parse(String.duplicate("a", 164))
      assert {:error, _} = Channel.parse(nil)
      assert {:error, _} = Channel.parse(123)
      assert {:error, _} = Channel.parse("#server-to-user-")
      assert {:error, _} = Channel.parse("#server-to-user-a b")
      assert {:error, _} = Channel.parse("#other")
    end

    test "capability predicates" do
      {:ok, public} = Channel.parse("a")
      {:ok, private} = Channel.parse("private-a")
      {:ok, encrypted} = Channel.parse("private-encrypted-a")
      {:ok, presence} = Channel.parse("presence-cache-a")

      refute Channel.authenticated?(public)
      assert Channel.authenticated?(encrypted)
      refute Channel.client_events_allowed?(public)
      refute Channel.client_events_allowed?(encrypted)
      assert Channel.client_events_allowed?(private)
      assert Channel.presence?(presence) and Channel.cache?(presence)
      assert Channel.encrypted?(encrypted)
      assert Channel.metric_type(presence) == "presence_cache"
      assert Channel.max_length() == 164
      assert Channel.user_channel("7") == "#server-to-user-7"
    end

    property "valid names round-trip through parse and to_string" do
      check all(name <- string(@charset, min_length: 1, max_length: 164)) do
        assert {:ok, channel} = Channel.parse(name)
        assert Channel.to_string(channel) == name
      end
    end
  end

  describe "auth" do
    @config %Arc.Apps.Config{id: 1, key: "278d425bdf160c739803", secret: "7ad3773142a6692b25b8"}

    test "matches the documented channel signature" do
      # socket_id 1234.1234, channel private-foobar
      assert Auth.sign_channel(@config, "1234.1234", "private-foobar") ==
               "278d425bdf160c739803:58df8b0c36d6982b82c3ecf6b4662e34fe8c25bba48f5369f135bf843651c3a4"
    end

    test "verifies private, presence, and user signatures" do
      auth = Auth.sign_channel(@config, "1.2", "private-a")
      assert :ok = Auth.verify_channel(@config, "1.2", "private-a", auth)
      assert {:error, :invalid_signature} = Auth.verify_channel(@config, "1.3", "private-a", auth)

      data = ~s({"user_id":"u1"})
      auth = Auth.sign_channel(@config, "1.2", "presence-a", data)
      assert :ok = Auth.verify_channel(@config, "1.2", "presence-a", auth, data)

      assert {:error, :invalid_signature} =
               Auth.verify_channel(@config, "1.2", "presence-a", auth, ~s({"user_id":"u2"}))

      user = ~s({"id":"u1"})
      auth = Auth.sign_user(@config, "1.2", user)
      assert :ok = Auth.verify_user(@config, "1.2", auth, user)
      assert Auth.user_string_to_sign("1.2", user) == "1.2::user::" <> user
    end

    test "rejects wrong keys and malformed values" do
      assert {:error, :invalid_key} =
               Auth.verify_channel(@config, "1.2", "private-a", "other:abc")

      assert {:error, :malformed_auth} =
               Auth.verify_channel(@config, "1.2", "private-a", "nocolon")

      assert {:error, :malformed_auth} = Auth.verify_channel(@config, "1.2", "private-a", nil)
      assert Auth.channel_string_to_sign("1.2", "a", "") == "1.2:a"
    end

    property "signatures verify and fail under any single-byte mutation" do
      check all(
              socket_id <-
                map({positive_integer(), positive_integer()}, fn {a, b} -> "#{a}.#{b}" end),
              name <- string(@charset, min_length: 1, max_length: 64),
              position <- integer(0..63),
              byte <- integer(0..255)
            ) do
        channel = "private-" <> name

        "278d425bdf160c739803:" <> signature =
          auth = Auth.sign_channel(@config, socket_id, channel)

        assert :ok = Auth.verify_channel(@config, socket_id, channel, auth)

        <<prefix::binary-size(^position), original, rest::binary>> = signature

        # Signatures are hex compared without regard to case, so swapping a digit for
        # the same digit in the other case is not a mutation.
        if downcase_byte(byte) != downcase_byte(original) do
          mutated = "278d425bdf160c739803:" <> prefix <> <<byte>> <> rest
          assert {:error, _} = Auth.verify_channel(@config, socket_id, channel, mutated)
        end
      end
    end

    test "an uppercase signature verifies, because SDKs differ on case" do
      "278d425bdf160c739803:" <> signature = Auth.sign_channel(@config, "1.2", "private-a")
      upper = "278d425bdf160c739803:" <> String.upcase(signature)

      assert :ok = Auth.verify_channel(@config, "1.2", "private-a", upper)
    end
  end

  defp downcase_byte(byte) when byte in ?A..?Z, do: byte + 32
  defp downcase_byte(byte), do: byte
end
