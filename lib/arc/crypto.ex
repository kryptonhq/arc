defmodule Arc.Crypto do
  @moduledoc """
  The signing primitives shared by channel auth, user sign-in, the HTTP API, and
  webhooks. All comparisons of secret-derived values are constant time.
  """

  @doc "Lowercase hex HMAC-SHA256 of `data` keyed by `key`."
  @spec hmac_sha256_hex(iodata(), iodata()) :: String.t()
  def hmac_sha256_hex(key, data) do
    :crypto.mac(:hmac, :sha256, key, data) |> Base.encode16(case: :lower)
  end

  @doc "Lowercase hex MD5 of `data`, as used for `body_md5` on API requests."
  @spec md5_hex(iodata()) :: String.t()
  def md5_hex(data), do: :crypto.hash(:md5, data) |> Base.encode16(case: :lower)

  @doc "Lowercase hex SHA-256 of `data`."
  @spec sha256_hex(iodata()) :: String.t()
  def sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc """
  Compares two binaries in time independent of where they differ. Returns false for
  non-binaries and for binaries of different length.
  """
  @spec secure_compare(term(), term()) :: boolean()
  def secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  def secure_compare(_, _), do: false

  @doc "Verifies that `signature` is the hex HMAC-SHA256 of `data` under `key`."
  @spec valid_hmac?(iodata(), iodata(), term()) :: boolean()
  def valid_hmac?(key, data, signature) when is_binary(signature) do
    secure_compare(hmac_sha256_hex(key, data), String.downcase(signature))
  end

  def valid_hmac?(_key, _data, _signature), do: false
end
