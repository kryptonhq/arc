defmodule Arc.Events do
  @moduledoc """
  Validation and execution of backend publishes and channel queries, independent of
  HTTP. Errors are `{:error, status, message}` with an HTTP-like status and a message
  written for the developer who will read it.
  """

  alias Arc.Apps.Config
  alias Arc.Channels.Channel
  alias Arc.Crypto.SecretBox
  alias Arc.Realtime
  alias Arc.Realtime.{Protocol, SocketId}

  @max_channels 100
  @max_batch 10
  @max_name_length 200

  @type event :: %{
          name: String.t(),
          data: String.t(),
          channels: [Channel.t()],
          socket_id: String.t() | nil,
          info: [String.t()]
        }

  @doc "Validates the body of a single-event publish."
  @spec validate(Config.t(), map()) :: {:ok, event()} | {:error, pos_integer(), String.t()}
  def validate(%Config{} = app, params) when is_map(params) do
    with {:ok, name} <- validate_name(params["name"]),
         {:ok, data} <- validate_data(app, params["data"]),
         {:ok, channels} <- validate_channels(params),
         :ok <- validate_encrypted(app, channels, data),
         {:ok, socket_id} <- validate_socket_id(params["socket_id"]),
         {:ok, info} <- parse_info(params["info"]) do
      {:ok, %{name: name, data: data, channels: channels, socket_id: socket_id, info: info}}
    end
  end

  @doc "Validates the body of a batch publish."
  @spec validate_batch(Config.t(), map()) ::
          {:ok, [event()]} | {:error, pos_integer(), String.t()}
  def validate_batch(app, %{"batch" => batch}) when is_list(batch) do
    cond do
      batch == [] ->
        {:error, 400, "batch must contain at least one event."}

      length(batch) > @max_batch ->
        {:error, 400, "batch may contain at most #{@max_batch} events; got #{length(batch)}."}

      true ->
        batch
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn
          {event, index}, {:ok, acc} when is_map(event) ->
            case validate(app, Map.delete(event, "channels")) do
              {:ok, event} ->
                {:cont, {:ok, [event | acc]}}

              {:error, status, message} ->
                {:halt, {:error, status, "batch[#{index}]: " <> message}}
            end

          {_, index}, _ ->
            {:halt, {:error, 400, "batch[#{index}] must be an object."}}
        end)
        |> case do
          {:ok, events} -> {:ok, Enum.reverse(events)}
          error -> error
        end
    end
  end

  def validate_batch(_app, _params), do: {:error, 400, "Request body must contain a batch array."}

  @doc """
  Publishes a validated event. Returns the per-channel info requested with `info`, or
  an empty map when none was requested.
  """
  def publish(%Config{} = app, event) do
    :ok = Realtime.publish(app, event.channels, event.name, event.data, event.socket_id)
    publish_info(app, event)
  end

  defp publish_info(_app, %{info: []}), do: %{}

  defp publish_info(app, %{info: info, channels: channels}) do
    Map.new(channels, fn channel ->
      attrs =
        %{}
        |> maybe_put("user_count" in info and Channel.presence?(channel), :user_count, fn ->
          Realtime.user_count(app.id, channel.name)
        end)
        |> maybe_put(
          "subscription_count" in info and app.subscription_count_enabled,
          :subscription_count,
          fn -> Realtime.subscription_count(app.id, channel.name) end
        )

      {channel.name, attrs}
    end)
  end

  ## Channel queries

  @doc "Occupied channels, for `GET /channels`."
  def list_channels(%Config{} = app, params) do
    prefix = params["filter_by_prefix"]

    with {:ok, info} <- parse_info(params["info"]),
         :ok <- check_info_attributes(info),
         :ok <- check_user_count_prefix(info, prefix),
         :ok <- check_subscription_count(app, info) do
      channels =
        app.id
        |> Realtime.occupied_channels(prefix)
        |> Map.new(fn {name, subscriptions} ->
          attrs =
            %{}
            |> maybe_put("user_count" in info, :user_count, fn ->
              Realtime.user_count(app.id, name)
            end)
            |> maybe_put("subscription_count" in info, :subscription_count, fn ->
              subscriptions
            end)

          {name, attrs}
        end)

      {:ok, %{channels: channels}}
    end
  end

  @doc "One channel's state, for `GET /channels/:name`."
  def channel(%Config{} = app, name, params) do
    with {:ok, channel} <- parse_channel(name),
         {:ok, info} <- parse_info(params["info"]),
         :ok <- check_info_attributes(info),
         :ok <- check_user_count_channel(info, channel),
         :ok <- check_subscription_count(app, info) do
      subscriptions = Realtime.subscription_count(app.id, channel.name)

      result =
        %{occupied: subscriptions > 0}
        |> maybe_put("user_count" in info, :user_count, fn ->
          Realtime.user_count(app.id, channel.name)
        end)
        |> maybe_put("subscription_count" in info, :subscription_count, fn -> subscriptions end)

      {:ok, result}
    end
  end

  @doc "Presence members of a channel, for `GET /channels/:name/users`."
  def users(%Config{} = app, name) do
    with {:ok, channel} <- parse_channel(name) do
      if Channel.presence?(channel) do
        ids = Realtime.user_ids(app.id, channel.name)
        {:ok, %{users: Enum.map(ids, &%{id: &1})}}
      else
        {:error, 400, "Users can only be listed for presence channels; #{name} is not one."}
      end
    end
  end

  @doc "Terminates every connection signed in as `user_id`."
  def terminate_user_connections(%Config{} = app, user_id) do
    if is_binary(user_id) and user_id != "" and byte_size(user_id) <= 200 do
      Realtime.terminate_user_connections(app.id, user_id)
      {:ok, %{}}
    else
      {:error, 400, "user_id must be a non-empty string of at most 200 bytes."}
    end
  end

  ## Validation helpers

  defp validate_name(name) when is_binary(name) and name != "" do
    cond do
      byte_size(name) > @max_name_length ->
        {:error, 400, "Event name is longer than #{@max_name_length} characters."}

      Protocol.reserved_event?(name) ->
        {:error, 400, "Event name #{inspect(name)} uses a reserved prefix."}

      true ->
        {:ok, name}
    end
  end

  defp validate_name(_),
    do: {:error, 400, "Event name is required and must be a non-empty string."}

  defp validate_data(app, data) do
    data =
      cond do
        is_binary(data) -> data
        is_nil(data) -> nil
        # Some clients send an object; encode it once so subscribers receive a string.
        true -> Jason.encode!(data)
      end

    cond do
      is_nil(data) ->
        {:error, 400, "Event data is required."}

      byte_size(data) > app.max_payload_bytes ->
        {:error, 413,
         "Event data is #{byte_size(data)} bytes; the limit for this app is #{app.max_payload_bytes}."}

      true ->
        {:ok, data}
    end
  end

  defp validate_channels(%{"channels" => channels}) when is_list(channels) do
    cond do
      channels == [] ->
        {:error, 400, "channels must contain at least one channel."}

      length(channels) > @max_channels ->
        {:error, 400,
         "An event may be published to at most #{@max_channels} channels; got #{length(channels)}."}

      true ->
        channels
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          case parse_channel(name) do
            {:ok, channel} -> {:cont, {:ok, [channel | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
          error -> error
        end
    end
  end

  defp validate_channels(%{"channel" => channel}) do
    with {:ok, parsed} <- parse_channel(channel), do: {:ok, [parsed]}
  end

  defp validate_channels(_), do: {:error, 400, "Either channel or channels is required."}

  defp validate_encrypted(app, channels, data) do
    encrypted = Enum.filter(channels, &Channel.encrypted?/1)

    cond do
      encrypted == [] ->
        :ok

      length(channels) > 1 ->
        {:error, 400, "Events for encrypted channels must be published to exactly one channel."}

      is_nil(app.encryption_master_key) ->
        {:error, 403,
         "This app has no encryption master key configured; set one in the dashboard before publishing to encrypted channels."}

      not SecretBox.envelope?(data) ->
        {:error, 400,
         "Data for encrypted channels must be a JSON object with base64 nonce and ciphertext; encrypt with your server SDK before publishing."}

      true ->
        :ok
    end
  end

  defp validate_socket_id(nil), do: {:ok, nil}

  defp validate_socket_id(socket_id) do
    if SocketId.valid?(socket_id),
      do: {:ok, socket_id},
      else: {:error, 400, "socket_id #{inspect(socket_id)} is not a valid socket id."}
  end

  defp parse_channel(name) do
    case Channel.parse(name) do
      {:ok, channel} -> {:ok, channel}
      {:error, message} -> {:error, 400, "Invalid channel name #{inspect(name)}: #{message}."}
    end
  end

  defp parse_info(nil), do: {:ok, []}
  defp parse_info(""), do: {:ok, []}

  defp parse_info(info) when is_binary(info),
    do: {:ok, info |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}

  defp parse_info(_), do: {:error, 400, "info must be a comma-separated string."}

  defp check_info_attributes(info) do
    case Enum.reject(info, &(&1 in ["user_count", "subscription_count"])) do
      [] -> :ok
      unknown -> {:error, 400, "Unknown info attributes: #{Enum.join(unknown, ", ")}."}
    end
  end

  defp check_user_count_prefix(info, prefix) do
    if "user_count" in info and
         not (is_binary(prefix) and String.starts_with?(prefix, "presence-")),
       do:
         {:error, 400,
          "user_count is only available for presence channels; add filter_by_prefix=presence-."},
       else: :ok
  end

  defp check_user_count_channel(info, channel) do
    if "user_count" in info and not Channel.presence?(channel),
      do:
        {:error, 400,
         "user_count is only available for presence channels; #{channel.name} is not one."},
      else: :ok
  end

  defp check_subscription_count(app, info) do
    if "subscription_count" in info and not app.subscription_count_enabled,
      do:
        {:error, 403,
         "subscription_count is not enabled for this app; enable it in the app settings."},
      else: :ok
  end

  defp maybe_put(map, true, key, fun), do: Map.put(map, key, fun.())
  defp maybe_put(map, _false, _key, _fun), do: map
end
