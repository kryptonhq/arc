defmodule Arc.Crypto.SecretBox do
  @moduledoc """
  NaCl secretbox (XSalsa20-Poly1305) for end-to-end encrypted channels.

  Arc never decrypts channel traffic: backends encrypt before publishing and clients
  decrypt after receiving. This module exists so Arc can derive the same per-channel
  keys as the SDKs do, validate the envelope shape, and exercise the full path in tests.

  Per-channel key: `SHA-256(channel_name <> master_key)`. The order matters and matches
  what the server SDKs derive; a key derived the other way round cannot decrypt.
  Envelope: `{"nonce": base64(24 bytes), "ciphertext": base64(box)}`.
  """

  @nonce_bytes 24

  @doc "Derives the 32-byte key for one channel from the app's master key."
  @spec channel_key(binary(), String.t()) :: binary()
  def channel_key(master_key, channel_name) when byte_size(master_key) == 32 do
    :crypto.hash(:sha256, channel_name <> master_key)
  end

  @doc "Encrypts `plaintext` for `channel_name`, returning the envelope map."
  @spec encrypt(binary(), binary(), String.t()) :: %{String.t() => String.t()}
  def encrypt(plaintext, master_key, channel_name) do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    ciphertext = Kcl.secretbox(plaintext, nonce, channel_key(master_key, channel_name))
    %{"nonce" => Base.encode64(nonce), "ciphertext" => Base.encode64(ciphertext)}
  end

  @doc "Decrypts an envelope produced by `encrypt/3` or by a server SDK."
  @spec decrypt(map(), binary(), String.t()) :: {:ok, binary()} | :error
  def decrypt(%{"nonce" => nonce64, "ciphertext" => ciphertext64}, master_key, channel_name) do
    with {:ok, <<_::binary-size(@nonce_bytes)>> = nonce} <- Base.decode64(nonce64),
         {:ok, ciphertext} <- Base.decode64(ciphertext64),
         plaintext when is_binary(plaintext) <-
           Kcl.secretunbox(ciphertext, nonce, channel_key(master_key, channel_name)) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  end

  def decrypt(_envelope, _master_key, _channel_name), do: :error

  @doc """
  True when `data` (the event's string payload) is a well-formed encrypted envelope.
  Arc uses this to refuse plaintext publishes to encrypted channels.
  """
  @spec envelope?(term()) :: boolean()
  def envelope?(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"nonce" => nonce, "ciphertext" => ciphertext}}
      when is_binary(nonce) and is_binary(ciphertext) ->
        match?({:ok, <<_::binary-size(@nonce_bytes)>>}, Base.decode64(nonce)) and
          match?({:ok, <<_::binary-size(16), _::binary>>}, Base.decode64(ciphertext))

      _ ->
        false
    end
  end

  def envelope?(_), do: false
end
