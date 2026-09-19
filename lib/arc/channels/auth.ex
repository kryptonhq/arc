defmodule Arc.Channels.Auth do
  @moduledoc """
  Signatures presented by clients when subscribing to authenticated channels and when
  signing in as a user. Clients obtain them from the application backend, which signs
  with the app secret; Arc verifies with the same secret.

  * Private channel: `HMAC(secret, "<socket_id>:<channel>")`
  * Presence channel: `HMAC(secret, "<socket_id>:<channel>:<channel_data>")`
  * User sign-in: `HMAC(secret, "<socket_id>::user::<user_data>")`

  The `auth` value on the wire is `"<app key>:<hex signature>"`.
  """

  alias Arc.Crypto
  alias Arc.Apps.Config

  @doc "String to sign for a channel subscription."
  def channel_string_to_sign(socket_id, channel, nil), do: "#{socket_id}:#{channel}"
  def channel_string_to_sign(socket_id, channel, ""), do: "#{socket_id}:#{channel}"

  def channel_string_to_sign(socket_id, channel, channel_data),
    do: "#{socket_id}:#{channel}:#{channel_data}"

  @doc "String to sign for user sign-in."
  def user_string_to_sign(socket_id, user_data), do: "#{socket_id}::user::#{user_data}"

  @doc "Produces an `auth` value. Used by tests and the dashboard's snippets."
  def sign(%Config{key: key, secret: secret}, string_to_sign),
    do: key <> ":" <> Crypto.hmac_sha256_hex(secret, string_to_sign)

  def sign_channel(app, socket_id, channel, channel_data \\ nil),
    do: sign(app, channel_string_to_sign(socket_id, channel, channel_data))

  def sign_user(app, socket_id, user_data),
    do: sign(app, user_string_to_sign(socket_id, user_data))

  @doc "Verifies a channel subscription `auth` value."
  @spec verify_channel(Config.t(), String.t(), String.t(), term(), String.t() | nil) ::
          :ok | {:error, atom()}
  def verify_channel(app, socket_id, channel, auth, channel_data \\ nil) do
    verify(app, channel_string_to_sign(socket_id, channel, channel_data), auth)
  end

  @doc "Verifies a user sign-in `auth` value."
  @spec verify_user(Config.t(), String.t(), term(), String.t()) :: :ok | {:error, atom()}
  def verify_user(app, socket_id, auth, user_data) do
    verify(app, user_string_to_sign(socket_id, user_data), auth)
  end

  defp verify(%Config{key: key, secret: secret}, string_to_sign, auth) when is_binary(auth) do
    case String.split(auth, ":", parts: 2) do
      [^key, signature] ->
        if Crypto.valid_hmac?(secret, string_to_sign, signature),
          do: :ok,
          else: {:error, :invalid_signature}

      [_other_key, _signature] ->
        {:error, :invalid_key}

      _ ->
        {:error, :malformed_auth}
    end
  end

  defp verify(_app, _string_to_sign, _auth), do: {:error, :malformed_auth}
end
