defmodule Arc.Realtime.Protocol do
  @moduledoc """
  Wire format of the Channels protocol, version 7.

  Every frame is a JSON object with `event`, an optional `channel`, and `data`. For
  application events `data` is a string that is passed through untouched; Arc never
  decodes and re-encodes it, because a second encoding is the most common way for a
  server to break client SDKs. Protocol events carry their payload JSON-encoded into a
  string as well, except `:error` frames whose `data` is an object.

  The event names below are fixed by the protocol and must match byte for byte.
  """

  @version 7

  # Connection events.
  @connection_established "pusher:connection_established"
  @error "pusher:error"
  @ping "pusher:ping"
  @pong "pusher:pong"
  @subscribe "pusher:subscribe"
  @unsubscribe "pusher:unsubscribe"
  @signin "pusher:signin"
  @signin_success "pusher:signin_success"
  # Channel events, delivered on the channel and surfaced to channel listeners.
  @subscription_error "pusher:subscription_error"
  @cache_miss "pusher:cache_miss"
  # Internal channel events, consumed by the SDK itself.
  @subscription_succeeded "pusher_internal:subscription_succeeded"
  @subscription_count "pusher_internal:subscription_count"
  @member_added "pusher_internal:member_added"
  @member_removed "pusher_internal:member_removed"

  @client_event_prefix "client-"
  @reserved_prefixes ["pusher:", "pusher_internal:"]

  def version, do: @version

  def event(:connection_established), do: @connection_established
  def event(:error), do: @error
  def event(:ping), do: @ping
  def event(:pong), do: @pong
  def event(:subscribe), do: @subscribe
  def event(:unsubscribe), do: @unsubscribe
  def event(:signin), do: @signin
  def event(:signin_success), do: @signin_success
  def event(:subscription_error), do: @subscription_error
  def event(:cache_miss), do: @cache_miss
  def event(:subscription_succeeded), do: @subscription_succeeded
  def event(:subscription_count), do: @subscription_count
  def event(:member_added), do: @member_added
  def event(:member_removed), do: @member_removed

  @doc "True for events a client may publish on a channel."
  def client_event?(name) when is_binary(name),
    do: String.starts_with?(name, @client_event_prefix)

  def client_event?(_), do: false

  @doc "True for names reserved for protocol use, which backends may not publish."
  def reserved_event?(name) when is_binary(name),
    do: Enum.any?(@reserved_prefixes, &String.starts_with?(name, &1))

  @doc """
  Decodes an inbound frame. Returns the event name, the optional channel, and `data`
  exactly as the client sent it (string, object, or absent).
  """
  @spec decode(binary()) ::
          {:ok, %{event: String.t(), channel: String.t() | nil, data: term()}}
          | {:error, String.t()}
  def decode(frame) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, %{"event" => event} = message} when is_binary(event) ->
        case Map.get(message, "channel") do
          channel when is_binary(channel) or is_nil(channel) ->
            {:ok, %{event: event, channel: channel, data: Map.get(message, "data")}}

          _ ->
            {:error, "channel must be a string"}
        end

      {:ok, %{}} ->
        {:error, "frame has no event name"}

      {:ok, _} ->
        {:error, "frame is not a JSON object"}

      {:error, _} ->
        {:error, "frame is not valid JSON"}
    end
  end

  @doc """
  Encodes an outbound frame. `data` must already be in wire form: a string for every
  event except `pusher:error`, which takes a map.
  """
  @spec encode(String.t(), String.t() | nil, term(), keyword()) :: binary()
  def encode(event, channel, data, extra \\ []) do
    [{"event", event}]
    |> put_if("channel", channel)
    |> Kernel.++([{"data", data}])
    |> put_extra(extra)
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  @doc "Encodes a protocol event whose payload is a map, JSON-encoding the payload into a string."
  def encode_internal(event, channel, payload),
    do: encode(event, channel, Jason.encode!(payload))

  @doc "The frame sent immediately after the WebSocket upgrade."
  def connection_established(socket_id, activity_timeout) do
    encode_internal(@connection_established, nil, %{
      socket_id: socket_id,
      activity_timeout: activity_timeout
    })
  end

  @doc "An error frame. `code` may be nil for errors that do not close the connection."
  def error(code, message), do: encode(@error, nil, %{code: code, message: message})

  def ping, do: encode(@ping, nil, "{}")
  def pong, do: encode(@pong, nil, "{}")

  def subscription_succeeded(channel, payload \\ %{}),
    do: encode_internal(@subscription_succeeded, channel, payload)

  def subscription_error(channel, type, message, status) do
    encode_internal(@subscription_error, channel, %{type: type, error: message, status: status})
  end

  def cache_miss(channel), do: encode(@cache_miss, channel, "{}")

  def subscription_count(channel, count),
    do: encode_internal(@subscription_count, channel, %{subscription_count: count})

  def member_added(channel, user_id, user_info) do
    payload =
      if is_nil(user_info),
        do: %{user_id: user_id},
        else: %{user_id: user_id, user_info: user_info}

    encode_internal(@member_added, channel, payload)
  end

  def member_removed(channel, user_id),
    do: encode_internal(@member_removed, channel, %{user_id: user_id})

  def signin_success(user_data),
    do: encode_internal(@signin_success, nil, %{user_data: user_data})

  defp put_if(fields, _key, nil), do: fields
  defp put_if(fields, key, value), do: fields ++ [{key, value}]

  defp put_extra(fields, extra) do
    Enum.reduce(extra, fields, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> acc ++ [{to_string(key), value}]
    end)
  end
end
