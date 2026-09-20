defmodule Arc.VaultTest do
  use Arc.DataCase, async: false

  alias Arc.Vault.Cipher

  @tag_ "AES.GCM.V1"

  defp opts(key, retired \\ []), do: [tag: @tag_, key: key, retired_keys: retired, iv_length: 12]

  test "decrypts with the current key, then each retired key in turn" do
    old = :crypto.strong_rand_bytes(32)
    older = :crypto.strong_rand_bytes(32)
    new = :crypto.strong_rand_bytes(32)

    {:ok, with_old} = Cipher.encrypt("s3cret", opts(old))
    {:ok, with_older} = Cipher.encrypt("older", opts(older))
    {:ok, with_new} = Cipher.encrypt("fresh", opts(new))

    rotated = opts(new, [old, older])
    assert {:ok, "s3cret"} = Cipher.decrypt(with_old, rotated)
    assert {:ok, "older"} = Cipher.decrypt(with_older, rotated)
    assert {:ok, "fresh"} = Cipher.decrypt(with_new, rotated)

    # Without the retired key the old row is unreadable, and says so.
    assert :error = Cipher.decrypt(with_old, opts(new))

    # The header tag is what Cloak routes on; every key shares it.
    assert Cipher.can_decrypt?(with_old, opts(new))
    refute Cipher.can_decrypt?("garbage", opts(new))

    assert Cipher.current?(with_new, opts(new))
    refute Cipher.current?(with_old, opts(new))
  end

  test "rewrap re-encrypts every stored secret and keeps it readable" do
    creds =
      Arc.Release.create_app(%{"name" => "Rotate"},
        encryption: true,
        webhook: %{"url" => "https://example.com/h", "events" => ["channel_occupied"]}
      )

    before = Arc.Apps.get_config(creds.id)
    [endpoint] = before.webhooks

    result = Arc.Release.rewrap()
    assert {"apps", apps} = List.keyfind(result, "apps", 0)
    assert {"webhook_endpoints", endpoints} = List.keyfind(result, "webhook_endpoints", 0)
    assert apps >= 1 and endpoints >= 1

    after_ = Arc.Apps.get_config(creds.id)
    assert after_.secret == creds.secret
    assert after_.encryption_master_key == before.encryption_master_key
    assert [%{secret: secret}] = after_.webhooks
    assert secret == endpoint.secret
  end

  test "mix arc.rewrap prints a count per table" do
    Mix.Task.reenable("arc.rewrap")
    output = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Arc.Rewrap.run([]) end)
    assert output =~ "apps:"
    assert output =~ "webhook_endpoints:"
  end
end
