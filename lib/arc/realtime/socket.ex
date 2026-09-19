defmodule Arc.Realtime.Socket do
  @moduledoc """
  One process per client connection, implementing the Channels protocol v7.

  The socket owns its WebSocket and is the only process that writes to it. It holds
  the connection's socket id, app, subscriptions, and signed-in user. Everything it
  registers — registry entries, occupancy counts, presence membership — is released
  by the owning service when this process exits, whether cleanly or by crashing.

  App configuration is read from `Arc.Apps.Cache` at the moment it is needed rather
  than captured at connect time, so a rotated secret or a disabled feature takes
  effect on existing connections immediately.
  """
  @behaviour WebSock

  require Logger

  alias Arc.Apps.Cache
  alias Arc.Channels.{Auth, Channel}

  alias Arc.Realtime.{
    ChannelCache,
    Dispatcher,
    ErrorCodes,
    Occupancy,
    Protocol,
    Registries,
    SocketId
  }

  alias Arc.{Presence, Webhooks}

  @max_channel_data_bytes 10_240

  defstruct [
    :app_id,
    :app_key,
    :socket_id,
    :user_id,
    :last_seen,
    :ping_sent_at,
    :bucket,
    channels: %{}
  ]

  ## Handshake

  @impl true
  def init(%{key: key, params: params}) do
    with :ok <- check_protocol(params),
         :ok <- check_ready(),
         {:ok, app} <- fetch_app(key),
         :ok <- check_node_capacity(),
         :ok <- check_app_capacity(app) do
      socket_id = SocketId.generate()
      {:ok, _} = Registry.register(Registries.Apps, app.id, socket_id)
      Occupancy.connect(app.id)
      Logger.metadata(app_id: app.id)
      Logger.debug("connection opened socket_id=#{socket_id}")
      schedule_idle_check()

      state = %__MODULE__{
        app_id: app.id,
        app_key: app.key,
        socket_id: socket_id,
        last_seen: now(),
        bucket: {config(:client_event_rate), now()}
      }

      {:push, {:text, Protocol.connection_established(socket_id, config(:activity_timeout))},
       state}
    else
      {:error, reason} -> close(reason, %__MODULE__{})
      {:error, reason, message} -> close(reason, message, %__MODULE__{})
    end
  end

  defp check_protocol(params) do
    case Map.get(params, "protocol") do
      nil ->
        {:error, :no_protocol_version}

      "" ->
        {:error, :no_protocol_version}

      "7" ->
        :ok

      _ ->
        {:error, :unsupported_protocol,
         "Unsupported protocol version: only protocol 7 is supported"}
    end
  end

  defp check_ready do
    if Cache.ready?(),
      do: :ok,
      else: {:error, :over_capacity, "Node is starting up, try again shortly"}
  end

  defp fetch_app(key) do
    case Cache.get_by_key(key) do
      nil -> {:error, :app_not_found, "Could not find app by key #{inspect(key)}"}
      %{enabled: false} -> {:error, :app_disabled}
      app -> {:ok, app}
    end
  end

  defp check_node_capacity do
    case config(:max_connections_per_node) do
      nil -> :ok
      max -> if Occupancy.total_connections() >= max, do: {:error, :over_capacity}, else: :ok
    end
  end

  defp check_app_capacity(%{max_connections: nil}), do: :ok

  defp check_app_capacity(%{id: id, max_connections: max}) do
    if Occupancy.connection_count(id) >= max, do: {:error, :over_connection_quota}, else: :ok
  end

  ## Inbound frames

  @impl true
  def handle_in({frame, opcode: :text}, state) do
    state = touch(state)
    :telemetry.execute([:arc, :message, :received], %{count: 1}, %{app_id: state.app_id})

    case Protocol.decode(frame) do
      {:ok, message} -> handle_event(message, state)
      {:error, reason} -> push_error(:invalid_frame, "Invalid frame: #{reason}", state)
    end
  end

  def handle_in({_frame, opcode: :binary}, state) do
    push_error(:invalid_frame, "Binary frames are not supported", touch(state))
  end

  @impl true
  def handle_control({_payload, opcode: _}, state), do: {:ok, touch(state)}

  defp handle_event(%{event: "pusher:ping"}, state), do: {:push, {:text, Protocol.pong()}, state}
  defp handle_event(%{event: "pusher:pong"}, state), do: {:ok, state}

  defp handle_event(%{event: "pusher:subscribe", data: data}, state),
    do: with_data(data, state, &subscribe/2)

  defp handle_event(%{event: "pusher:unsubscribe", data: data}, state),
    do: with_data(data, state, &unsubscribe/2)

  defp handle_event(%{event: "pusher:signin", data: data}, state),
    do: with_data(data, state, &signin/2)

  defp handle_event(%{event: event} = message, state) do
    if Protocol.client_event?(event) do
      client_event(message, state)
    else
      push_error(:invalid_frame, "Unsupported event #{inspect(event)}", state)
    end
  end

  # Most SDKs send `data` as an object; a few send it as a JSON string. Accept both.
  defp with_data(data, state, fun) when is_map(data), do: fun.(data, state)

  defp with_data(data, state, fun) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, map} when is_map(map) -> fun.(map, state)
      _ -> push_error(:invalid_frame, "Invalid frame: data must be an object", state)
    end
  end

  defp with_data(_data, state, _fun),
    do: push_error(:invalid_frame, "Invalid frame: data must be an object", state)

  ## Subscribe

  defp subscribe(%{"channel" => name} = data, state) do
    with {:ok, channel} <- parse_channel(name),
         :ok <- not_subscribed(channel, state),
         app when not is_nil(app) <- Cache.get(state.app_id),
         {:ok, member} <- authorize(channel, data, app, state),
         :ok <- check_presence_limit(channel, member, app, state) do
      join(channel, member, state)
    else
      {:already_subscribed, channel} ->
        {:push, {:text, subscription_succeeded_frame(channel, state)}, state}

      {:subscription_error, type, message, status} ->
        :telemetry.execute([:arc, :auth, :failure], %{count: 1}, %{
          app_id: state.app_id,
          reason: type
        })

        Logger.info(
          "subscription rejected app_id=#{state.app_id} reason=#{type} status=#{status}"
        )

        frame = Protocol.subscription_error(name, type, message, status)
        {:push, {:text, frame}, state}

      {:invalid_channel, message} ->
        frame = Protocol.subscription_error(name, "InvalidChannel", message, 400)
        {:push, {:text, frame}, state}

      nil ->
        close(:app_not_found, state)
    end
  end

  defp subscribe(_data, state),
    do: push_error(:invalid_channel, "Subscribe requires a channel", state)

  defp parse_channel(name) do
    case Channel.parse(name) do
      {:ok, channel} -> {:ok, channel}
      {:error, message} -> {:invalid_channel, message}
    end
  end

  defp not_subscribed(channel, state) do
    if Map.has_key?(state.channels, channel.name), do: {:already_subscribed, channel}, else: :ok
  end

  defp authorize(%Channel{type: :user, name: name}, _data, _app, state) do
    if state.user_id && name == Channel.user_channel(state.user_id),
      do: {:ok, nil},
      else:
        {:subscription_error, "AuthError", "User channels require signing in as that user", 403}
  end

  defp authorize(channel, data, app, state) do
    cond do
      not Channel.authenticated?(channel) ->
        {:ok, nil}

      Channel.presence?(channel) ->
        channel_data = Map.get(data, "channel_data")

        with :ok <- verify_auth(app, state, channel, data["auth"], channel_data),
             {:ok, member} <- parse_channel_data(channel_data) do
          {:ok, member}
        end

      true ->
        with :ok <- verify_auth(app, state, channel, data["auth"], nil), do: {:ok, nil}
    end
  end

  defp verify_auth(app, state, channel, auth, channel_data) do
    case Auth.verify_channel(app, state.socket_id, channel.name, auth, channel_data) do
      :ok ->
        :ok

      {:error, :invalid_key} ->
        {:subscription_error, "AuthError", "Auth key does not match this app", 401}

      {:error, :malformed_auth} ->
        {:subscription_error, "AuthError", "Missing or malformed auth value", 401}

      {:error, :invalid_signature} ->
        {:subscription_error, "AuthError",
         "Invalid signature: expected HMAC SHA256 hex digest of " <>
           inspect(Auth.channel_string_to_sign(state.socket_id, channel.name, channel_data)), 401}
    end
  end

  defp parse_channel_data(channel_data) when is_binary(channel_data) do
    with true <- byte_size(channel_data) <= @max_channel_data_bytes,
         {:ok, %{"user_id" => user_id} = decoded} <- Jason.decode(channel_data),
         {:ok, user_id} <- normalize_user_id(user_id) do
      {:ok, {user_id, Map.get(decoded, "user_info")}}
    else
      false ->
        {:subscription_error, "InvalidChannelData",
         "channel_data must not exceed #{@max_channel_data_bytes} bytes", 400}

      _ ->
        {:subscription_error, "InvalidChannelData",
         "channel_data must be a JSON object with a user_id", 400}
    end
  end

  defp parse_channel_data(_),
    do: {:subscription_error, "InvalidChannelData", "Presence channels require channel_data", 400}

  defp normalize_user_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp normalize_user_id(id) when is_integer(id), do: {:ok, Integer.to_string(id)}
  defp normalize_user_id(_), do: :error

  defp check_presence_limit(channel, {user_id, _info}, app, state) do
    if Channel.presence?(channel) and app.enable_presence_limits and
         not Presence.member?(state.app_id, channel.name, user_id) and
         Presence.user_count(state.app_id, channel.name) >= app.max_presence_members do
      {:subscription_error, "LimitReached",
       "Presence channel is full (#{app.max_presence_members} members)", 403}
    else
      :ok
    end
  end

  defp check_presence_limit(_channel, _member, _app, _state), do: :ok

  defp join(channel, member, state) do
    {:ok, _} =
      Registry.register(Registries.Channels, {state.app_id, channel.name}, state.socket_id)

    Occupancy.subscribe(state.app_id, channel.name, channel.type)

    member_user_id =
      case member do
        {user_id, info} ->
          {:ok, _ref} = Presence.track(state.app_id, channel.name, state.socket_id, user_id, info)
          user_id

        nil ->
          nil
      end

    state = %{state | channels: Map.put(state.channels, channel.name, {channel, member_user_id})}

    frames = [
      {:text, subscription_succeeded_frame(channel, state)} | cache_frames(channel, state)
    ]

    {:push, frames, state}
  end

  defp subscription_succeeded_frame(channel, state) do
    if Channel.presence?(channel) do
      Protocol.subscription_succeeded(
        channel.name,
        Presence.subscription_payload(state.app_id, channel.name)
      )
    else
      Protocol.subscription_succeeded(channel.name)
    end
  end

  defp cache_frames(channel, state) do
    if Channel.cache?(channel) do
      case ChannelCache.get(state.app_id, channel.name) do
        {:ok, frame} ->
          [{:text, frame}]

        :miss ->
          Webhooks.Events.cache_miss(state.app_id, channel.name)
          [{:text, Protocol.cache_miss(channel.name)}]
      end
    else
      []
    end
  end

  ## Unsubscribe

  defp unsubscribe(%{"channel" => name}, state) when is_binary(name) do
    case Map.pop(state.channels, name) do
      {nil, _} ->
        {:ok, state}

      {{channel, member_user_id}, channels} ->
        Registry.unregister(Registries.Channels, {state.app_id, name})
        Occupancy.unsubscribe(state.app_id, name)
        if member_user_id, do: Presence.untrack(state.app_id, channel.name, member_user_id)
        {:ok, %{state | channels: channels}}
    end
  end

  defp unsubscribe(_data, state),
    do: push_error(:invalid_channel, "Unsubscribe requires a channel", state)

  ## User sign-in

  defp signin(%{"auth" => auth, "user_data" => user_data}, state) when is_binary(user_data) do
    app = Cache.get(state.app_id)

    with %{} <- app,
         :ok <- Auth.verify_user(app, state.socket_id, auth, user_data),
         {:ok, %{"id" => user_id}} when is_binary(user_id) and user_id != "" <-
           Jason.decode(user_data) do
      if state.user_id, do: Registry.unregister(Registries.Users, {state.app_id, state.user_id})
      {:ok, _} = Registry.register(Registries.Users, {state.app_id, user_id}, state.socket_id)

      {:push, {:text, Protocol.signin_success(user_data)}, %{state | user_id: user_id}}
    else
      nil ->
        close(:app_not_found, state)

      _ ->
        :telemetry.execute([:arc, :auth, :failure], %{count: 1}, %{
          app_id: state.app_id,
          reason: "SigninFailed"
        })

        Logger.info("sign-in rejected app_id=#{state.app_id}")
        close(:unauthorized, "Sign-in failed: invalid signature or user_data", state)
    end
  end

  defp signin(_data, state) do
    close(:unauthorized, "Sign-in requires auth and a user_data JSON string", state)
  end

  ## Client events

  defp client_event(%{event: event, channel: name, data: data}, state) do
    app = Cache.get(state.app_id)

    with %{} <- app,
         :ok <- check(app.client_events_enabled, "Client events are not enabled for this app"),
         {:ok, {channel, member_user_id}} <- fetch_subscription(name, state),
         :ok <-
           check(
             Channel.client_events_allowed?(channel),
             "Client events are only allowed on private and presence channels"
           ),
         {:ok, encoded} <- encode_client_data(data),
         {:ok, state} <- take_token(state) do
      frame = Protocol.encode(event, channel.name, data, user_id: member_user_id)

      Dispatcher.broadcast(state.app_id, channel.name, frame, state.socket_id,
        cache: Channel.cache?(channel)
      )

      :telemetry.execute([:arc, :message, :sent], %{count: 1}, %{
        app_id: state.app_id,
        source: "client"
      })

      Webhooks.Events.client_event(state.app_id, %{
        channel: channel.name,
        event: event,
        data: encoded,
        socket_id: state.socket_id,
        user_id: member_user_id
      })

      {:ok, state}
    else
      nil ->
        close(:app_not_found, state)

      {:rate_limited, state} ->
        :telemetry.execute([:arc, :rate_limit, :hit], %{count: 1}, %{
          app_id: state.app_id,
          kind: "client_event"
        })

        push_error(:client_event_rate_limited, state)

      {:error, message} ->
        push_error(:client_event_rejected, message, state)
    end
  end

  defp check(true, _message), do: :ok
  defp check(_, message), do: {:error, message}

  defp fetch_subscription(nil, _state), do: {:error, "Client events require a channel"}

  defp fetch_subscription(name, state) do
    case Map.fetch(state.channels, name) do
      {:ok, subscription} -> {:ok, subscription}
      :error -> {:error, "Client events can only be sent on channels the connection has joined"}
    end
  end

  defp encode_client_data(data) do
    encoded = if is_binary(data), do: data, else: Jason.encode!(data)
    max = config(:client_event_max_bytes)

    if byte_size(encoded) > max,
      do: {:error, "Client event payload exceeds #{max} bytes"},
      else: {:ok, encoded}
  end

  # Token bucket: capacity and refill rate are both `client_event_rate` per second.
  defp take_token(%{bucket: {tokens, at}} = state) do
    rate = config(:client_event_rate)
    current = now()
    refilled = min(rate * 1.0, tokens + (current - at) * rate / 1000)

    if refilled >= 1,
      do: {:ok, %{state | bucket: {refilled - 1, current}}},
      else: {:rate_limited, %{state | bucket: {refilled, current}}}
  end

  ## Messages from the rest of the system

  @impl true
  def handle_info({:arc_frame, frame}, state) do
    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

    if queued > config(:max_queue_len) do
      Logger.warning("closing slow consumer app_id=#{state.app_id} queued=#{queued}")
      close(:slow_consumer, state)
    else
      {:push, {:text, frame}, state}
    end
  end

  def handle_info({:arc_close, reason}, state), do: close(reason, state)
  def handle_info({:arc_close, reason, message}, state), do: close(reason, message, state)

  def handle_info(:idle_check, state) do
    current = now()
    idle_ms = current - state.last_seen

    cond do
      state.ping_sent_at && current - state.ping_sent_at >= config(:pong_timeout) ->
        close(:pong_timeout, state)

      is_nil(state.ping_sent_at) and idle_ms >= config(:activity_timeout) * 1000 ->
        schedule_idle_check()
        {:push, {:text, Protocol.ping()}, %{state | ping_sent_at: current}}

      true ->
        schedule_idle_check()
        {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    if state.socket_id do
      Logger.debug("connection closed socket_id=#{state.socket_id} reason=#{inspect(reason)}")
    end

    :ok
  end

  ## Helpers

  defp touch(state), do: %{state | last_seen: now(), ping_sent_at: nil}

  defp push_error(reason, state), do: push_error(reason, ErrorCodes.message(reason), state)

  defp push_error(reason, message, state) do
    {:push, {:text, Protocol.error(ErrorCodes.code(reason), message)}, state}
  end

  defp close(reason, state), do: close(reason, ErrorCodes.message(reason), state)

  defp close(reason, message, state) do
    code = ErrorCodes.code(reason)
    # A close frame's reason is limited to 123 bytes; the error frame carries the full text.
    reason_text = if byte_size(message) > 123, do: binary_part(message, 0, 123), else: message
    {:stop, :normal, {code, reason_text}, [{:text, Protocol.error(code, message)}], state}
  end

  defp schedule_idle_check,
    do: Process.send_after(self(), :idle_check, config(:idle_check_interval))

  defp now, do: System.monotonic_time(:millisecond)

  defp config(key), do: Application.fetch_env!(:arc, Arc.Realtime) |> Keyword.fetch!(key)
end
