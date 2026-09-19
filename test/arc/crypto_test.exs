defmodule Arc.CryptoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arc.Crypto
  alias Arc.Crypto.SecretBox

  test "hmac_sha256_hex matches a known vector" do
    # RFC 4231 test case 2
    assert Crypto.hmac_sha256_hex("Jefe", "what do ya want for nothing?") ==
             "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
  end

  test "md5_hex and sha256_hex" do
    assert Crypto.md5_hex("") == "d41d8cd98f00b204e9800998ecf8427e"

    assert Crypto.sha256_hex("abc") ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end

  test "secure_compare" do
    assert Crypto.secure_compare("abc", "abc")
    refute Crypto.secure_compare("abc", "abd")
    refute Crypto.secure_compare("abc", "abcd")
    refute Crypto.secure_compare(nil, "abc")
    refute Crypto.secure_compare("abc", 1)
  end

  test "valid_hmac? accepts uppercase hex and rejects non-strings" do
    sig = Crypto.hmac_sha256_hex("k", "d")
    assert Crypto.valid_hmac?("k", "d", sig)
    assert Crypto.valid_hmac?("k", "d", String.upcase(sig))
    refute Crypto.valid_hmac?("k", "d", nil)
    refute Crypto.valid_hmac?("k", "x", sig)
  end

  describe "secretbox" do
    @master :crypto.strong_rand_bytes(32)

    test "channel key is SHA-256 of channel name then master key, as the SDKs derive it" do
      assert SecretBox.channel_key(@master, "private-encrypted-a") ==
               :crypto.hash(:sha256, "private-encrypted-a" <> @master)
    end

    test "decrypt fails with the wrong channel or a tampered envelope" do
      envelope = SecretBox.encrypt("hello", @master, "private-encrypted-a")
      assert {:ok, "hello"} = SecretBox.decrypt(envelope, @master, "private-encrypted-a")
      assert :error = SecretBox.decrypt(envelope, @master, "private-encrypted-b")

      assert :error =
               SecretBox.decrypt(%{envelope | "nonce" => "bad"}, @master, "private-encrypted-a")

      assert :error = SecretBox.decrypt(%{}, @master, "private-encrypted-a")
    end

    test "envelope? recognises well-formed envelopes only" do
      envelope = SecretBox.encrypt("hello", @master, "private-encrypted-a")
      assert SecretBox.envelope?(Jason.encode!(envelope))
      refute SecretBox.envelope?(~s({"hello":"world"}))
      refute SecretBox.envelope?(~s({"nonce":"AAAA","ciphertext":"AAAA"}))
      refute SecretBox.envelope?("not json")
      refute SecretBox.envelope?(nil)
    end

    property "encrypt then decrypt is the identity" do
      check all(
              plaintext <- binary(max_length: 4096),
              channel <- string(:alphanumeric, min_length: 1, max_length: 50)
            ) do
        name = "private-encrypted-" <> channel
        envelope = SecretBox.encrypt(plaintext, @master, name)
        assert {:ok, ^plaintext} = SecretBox.decrypt(envelope, @master, name)
      end
    end
  end
end
