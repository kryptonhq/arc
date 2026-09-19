defmodule Arc.Channels.Channel do
  @moduledoc """
  A parsed channel name.

  The type is decided by prefix, longest match first:

  | Prefix                | Type                  |
  | --------------------- | --------------------- |
  | `private-encrypted-`  | `:private_encrypted`  |
  | `private-cache-`      | `:private_cache`      |
  | `presence-cache-`     | `:presence_cache`     |
  | `private-`            | `:private`            |
  | `presence-`           | `:presence`           |
  | `cache-`              | `:cache`              |
  | `#server-to-user-`    | `:user`               |
  | anything else         | `:public`             |

  `:user` channels are the per-user delivery channel a signed-in connection
  subscribes to; they are only accepted for the connection's own user id.
  """

  @enforce_keys [:name, :type]
  defstruct [:name, :type]

  @type type ::
          :public
          | :private
          | :private_encrypted
          | :presence
          | :cache
          | :private_cache
          | :presence_cache
          | :user

  @type t :: %__MODULE__{name: String.t(), type: type()}

  @max_length 164
  @user_prefix "#server-to-user-"

  @prefixes [
    {"private-encrypted-", :private_encrypted},
    {"private-cache-", :private_cache},
    {"presence-cache-", :presence_cache},
    {"private-", :private},
    {"presence-", :presence},
    {"cache-", :cache}
  ]

  @doc "Maximum channel name length in bytes."
  def max_length, do: @max_length

  @doc """
  Parses and validates a channel name. Names are never normalised: anything outside
  `[A-Za-z0-9_\\-=@,.;]` or longer than #{@max_length} characters is rejected.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, String.t()}
  def parse(name) when is_binary(name) do
    cond do
      name == "" ->
        {:error, "Channel name must not be empty"}

      byte_size(name) > @max_length ->
        {:error, "Channel name is longer than #{@max_length} characters"}

      String.starts_with?(name, @user_prefix) ->
        parse_user(name)

      not valid_chars?(name) ->
        {:error, "Channel name contains characters outside [A-Za-z0-9_-=@,.;]"}

      true ->
        {:ok, %__MODULE__{name: name, type: type_of(name)}}
    end
  end

  def parse(_), do: {:error, "Channel name must be a string"}

  @doc "The channel's wire name."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{name: name}), do: name

  @doc "Name of the per-user delivery channel for `user_id`."
  def user_channel(user_id), do: @user_prefix <> user_id

  @doc "True for channels that require a signed `auth` on subscribe."
  def authenticated?(%__MODULE__{type: type}),
    do: type in [:private, :private_encrypted, :presence, :private_cache, :presence_cache]

  @doc "True for presence channels (with or without cache)."
  def presence?(%__MODULE__{type: type}), do: type in [:presence, :presence_cache]

  @doc "True for channels that retain their last event."
  def cache?(%__MODULE__{type: type}), do: type in [:cache, :private_cache, :presence_cache]

  @doc "True for end-to-end encrypted channels."
  def encrypted?(%__MODULE__{type: type}), do: type == :private_encrypted

  @doc "True for channels on which clients may publish `client-` events."
  def client_events_allowed?(%__MODULE__{type: type}),
    do: type in [:private, :presence, :private_cache, :presence_cache]

  @doc "Coarse type label for metrics; bounded cardinality."
  def metric_type(%__MODULE__{type: type}), do: Atom.to_string(type)

  defp parse_user(@user_prefix <> user_id = name) do
    if user_id != "" and valid_chars?(user_id) do
      {:ok, %__MODULE__{name: name, type: :user}}
    else
      {:error, "Invalid user channel name"}
    end
  end

  defp type_of(name) do
    Enum.find_value(@prefixes, :public, fn {prefix, type} ->
      if String.starts_with?(name, prefix), do: type
    end)
  end

  defp valid_chars?(name) do
    name
    |> :binary.bin_to_list()
    |> Enum.all?(fn c ->
      c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?-, ?=, ?@, ?,, ?., ?;]
    end)
  end
end
