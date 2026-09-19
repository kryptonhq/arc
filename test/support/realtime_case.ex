defmodule Arc.RealtimeCase do
  @moduledoc """
  Protocol conformance tests: a real WebSocket client against the running endpoint.
  Tests are not async because the endpoint and the data plane are shared.
  """
  use ExUnit.CaseTemplate

  alias Arc.Test.WsClient
  alias Arc.Channels.Auth

  using do
    quote do
      import Arc.RealtimeCase
      import Arc.Test.Fixtures
      alias Arc.Test.WsClient
    end
  end

  setup tags do
    # Cluster tests run on several nodes that must see the same committed rows, so
    # they bypass the sandbox; they run on their own (mix test --only cluster).
    unless tags[:cluster] do
      Arc.DataCase.setup_sandbox(Map.put(tags, :async, false))
    end

    :ok
  end

  @doc "Connects to an app and returns `{client, socket_id}` after the handshake."
  def connect!(config, query \\ "protocol=7&client=test&version=1.0&flash=false", port \\ 4002) do
    {:ok, client} = WsClient.connect("/app/#{config.key}?#{query}", self(), port)
    %{"event" => "pusher:connection_established", "data" => data} = next_frame!(client)
    %{"socket_id" => socket_id} = Jason.decode!(data)
    {client, socket_id}
  end

  @doc "Waits for the next frame from `client`."
  def next_frame!(client, timeout \\ 2_000) do
    receive do
      {:frame, ^client, frame} -> frame
    after
      timeout -> raise "no frame received within #{timeout}ms"
    end
  end

  @doc "Waits for the next frame with the given event name, skipping others."
  def await_event!(client, event, timeout \\ 2_000) do
    receive do
      {:frame, ^client, %{"event" => ^event} = frame} -> frame
    after
      timeout -> raise "no #{event} received within #{timeout}ms"
    end
  end

  @doc "Asserts nothing arrives from `client` for `timeout` ms."
  def refute_frame(client, timeout \\ 200) do
    receive do
      {:frame, ^client, frame} -> raise "unexpected frame: #{inspect(frame)}"
    after
      timeout -> :ok
    end
  end

  def await_close!(client, timeout \\ 2_000) do
    receive do
      {:closed, ^client, code, reason} -> {code, reason}
    after
      timeout -> raise "connection not closed within #{timeout}ms"
    end
  end

  def subscribe!(client, channel, extra \\ %{}) do
    :ok =
      WsClient.send_json(client, %{
        event: "pusher:subscribe",
        data: Map.put(extra, :channel, channel)
      })
  end

  @doc "Subscribes to an authenticated channel with a valid signature."
  def subscribe_auth!(client, config, socket_id, channel, channel_data \\ nil) do
    auth = Auth.sign_channel(config, socket_id, channel, channel_data)
    extra = if channel_data, do: %{auth: auth, channel_data: channel_data}, else: %{auth: auth}
    subscribe!(client, channel, extra)
  end

  def decode_data(%{"data" => data}) when is_binary(data), do: Jason.decode!(data)
  def decode_data(%{"data" => data}), do: data

  @doc "Polls `fun` until it returns a truthy value or the timeout passes."
  def eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "condition not met in time"
        else
          Process.sleep(20)
          do_eventually(fun, deadline)
        end
    end
  end
end
