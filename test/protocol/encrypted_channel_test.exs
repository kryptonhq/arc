defmodule Arc.Protocol.EncryptedChannelTest do
  use Arc.RealtimeCase

  alias Arc.Apps
  alias Arc.Channels.Channel
  alias Arc.Crypto.SecretBox

  setup do
    app = app_fixture()
    {:ok, app} = Apps.put_encryption_master_key(app, Apps.generate_encryption_master_key())
    %{app: app, config: Apps.get_config(app.id)}
  end

  test "requires auth like a private channel", %{config: config} do
    {client, _} = connect!(config)
    subscribe!(client, "private-encrypted-x")
    assert %{"status" => 401} = decode_data(next_frame!(client))
  end

  test "ciphertext passes through untouched and decrypts with the channel key", %{config: config} do
    {client, socket_id} = connect!(config)
    subscribe_auth!(client, config, socket_id, "private-encrypted-x")
    await_event!(client, "pusher_internal:subscription_succeeded")

    envelope =
      SecretBox.encrypt(
        ~s({"secret":"plans"}),
        config.encryption_master_key,
        "private-encrypted-x"
      )

    data = Jason.encode!(envelope)

    {:ok, event} =
      Arc.Events.validate(config, %{
        "name" => "e",
        "channel" => "private-encrypted-x",
        "data" => data
      })

    Arc.Events.publish(config, event)

    frame = next_frame!(client)
    assert frame["data"] == data

    assert {:ok, ~s({"secret":"plans"})} =
             SecretBox.decrypt(
               Jason.decode!(frame["data"]),
               config.encryption_master_key,
               "private-encrypted-x"
             )
  end

  test "plaintext publishes are refused", %{config: config} do
    assert {:error, 400, message} =
             Arc.Events.validate(config, %{
               "name" => "e",
               "channel" => "private-encrypted-x",
               "data" => ~s({"a":1})
             })

    assert message =~ "encrypt"
  end

  test "publishing is refused when the app has no master key", %{app: app} do
    {:ok, app} = Apps.put_encryption_master_key(app, nil)
    config = Apps.get_config(app.id)

    envelope =
      SecretBox.encrypt("x", :crypto.strong_rand_bytes(32), "private-encrypted-x")
      |> Jason.encode!()

    assert {:error, 403, _} =
             Arc.Events.validate(config, %{
               "name" => "e",
               "channel" => "private-encrypted-x",
               "data" => envelope
             })
  end

  test "encrypted events cannot be multi-channel", %{config: config} do
    envelope =
      SecretBox.encrypt("x", config.encryption_master_key, "private-encrypted-x")
      |> Jason.encode!()

    assert {:error, 400, _} =
             Arc.Events.validate(config, %{
               "name" => "e",
               "channels" => ["private-encrypted-x", "other"],
               "data" => envelope
             })
  end

  test "channel type detection", _ do
    assert {:ok, %Channel{type: :private_encrypted}} = Channel.parse("private-encrypted-x")
  end
end
