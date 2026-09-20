defmodule Arc.Vault.Cipher do
  @moduledoc """
  AES-256-GCM with one current key and any number of retired keys.

  Everything is encrypted with the current key. Decryption tries the current key
  first, then each retired key in order, so `ARC_ENCRYPTION_KEY` can be rotated:
  set the new key as current, the old one in `ARC_ENCRYPTION_KEY_RETIRED`, restart,
  run `mix arc.rewrap` (or `Arc.Release.rewrap/0`) to re-encrypt every stored secret
  under the new key, then drop the retired key.

  Ciphertext keeps the same header tag whichever key produced it, so rotation needs no
  data migration to *read* old rows and `rewrap` is the only step that writes.
  """
  @behaviour Cloak.Cipher

  alias Cloak.Ciphers.AES.GCM

  @impl true
  def encrypt(plaintext, opts),
    do: GCM.encrypt(plaintext, gcm_opts(opts, Keyword.fetch!(opts, :key)))

  @impl true
  def decrypt(ciphertext, opts) do
    [Keyword.fetch!(opts, :key) | Keyword.get(opts, :retired_keys, [])]
    |> Enum.find_value(:error, fn key ->
      case try_decrypt(ciphertext, gcm_opts(opts, key)) do
        {:ok, plaintext} -> {:ok, plaintext}
        :error -> nil
      end
    end)
  end

  @impl true
  def can_decrypt?(ciphertext, opts),
    do: GCM.can_decrypt?(ciphertext, gcm_opts(opts, Keyword.fetch!(opts, :key)))

  @doc "True if `ciphertext` decrypts with the current key alone, i.e. needs no rewrap."
  def current?(ciphertext, opts),
    do: match?({:ok, _}, try_decrypt(ciphertext, gcm_opts(opts, Keyword.fetch!(opts, :key))))

  # A wrong key fails the GCM authentication tag, which :crypto reports as an `:error`
  # atom in place of the plaintext.
  defp try_decrypt(ciphertext, opts) do
    case GCM.decrypt(ciphertext, opts) do
      {:ok, plaintext} when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  end

  defp gcm_opts(opts, key),
    do: [key: key, tag: Keyword.fetch!(opts, :tag), iv_length: Keyword.get(opts, :iv_length, 12)]
end
