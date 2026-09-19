defmodule Arc.Test.WsClient do
  @moduledoc """
  A minimal WebSocket client for protocol tests. Each received text frame is decoded
  and sent to the owning test process as `{:frame, client, map}`; a close frame is
  sent as `{:closed, client, code, reason}`.
  """
  use GenServer

  @port 4002

  def connect(path, owner \\ self(), port \\ @port) do
    GenServer.start(__MODULE__, {path, owner, port})
  end

  def send_json(client, map), do: GenServer.call(client, {:send, {:text, Jason.encode!(map)}})
  def send_raw(client, frame), do: GenServer.call(client, {:send, frame})
  def close(client), do: GenServer.stop(client, :normal)

  @impl true
  def init({path, owner, port}) do
    with {:ok, conn} <- Mint.HTTP.connect(:http, "localhost", port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, websocket, early} <- await_upgrade(conn, ref) do
      state = %{conn: conn, ref: ref, websocket: websocket, owner: owner}

      # Frames that arrived in the same packet as the upgrade response are delivered
      # before anything else, so ordering is preserved.
      case handle_info({:early_data, early}, state) do
        {:noreply, state} -> {:ok, state}
        {:stop, _reason, state} -> {:ok, state, {:continue, :stop}}
      end
    else
      {:error, reason} -> {:stop, reason}
      {:error, _conn, reason} -> {:stop, reason}
      {:error, _conn, reason, _responses} -> {:stop, reason}
    end
  end

  defp await_upgrade(conn, ref, acc \\ %{}) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            acc =
              Enum.reduce(responses, acc, fn
                {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
                {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
                {:done, ^ref}, acc -> Map.put(acc, :done, true)
                {:data, ^ref, data}, acc -> Map.update(acc, :data, [data], &(&1 ++ [data]))
                _, acc -> acc
              end)

            if acc[:done] do
              case Mint.WebSocket.new(conn, ref, acc.status, acc.headers) do
                {:ok, conn, websocket} -> {:ok, conn, websocket, Map.get(acc, :data, [])}
                {:error, conn, reason} -> {:error, conn, {reason, acc.status}}
              end
            else
              await_upgrade(conn, ref, acc)
            end

          {:error, conn, reason, _} ->
            {:error, conn, reason}
        end
    after
      5_000 -> {:error, :upgrade_timeout}
    end
  end

  @impl true
  def handle_continue(:stop, state), do: {:stop, :normal, state}

  @impl true
  def handle_call({:send, frame}, _from, state) do
    {:ok, websocket, data} = Mint.WebSocket.encode(state.websocket, frame)

    case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:ok, conn} ->
        {:reply, :ok, %{state | conn: conn, websocket: websocket}}

      {:error, conn, reason} ->
        {:reply, {:error, reason}, %{state | conn: conn, websocket: websocket}}
    end
  end

  @impl true
  def handle_info({:early_data, chunks}, state) do
    Enum.reduce_while(chunks, {:noreply, state}, fn data, {:noreply, state} ->
      {:ok, websocket, frames} = Mint.WebSocket.decode(state.websocket, data)

      case handle_frames(frames, %{state | websocket: websocket}) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        stop -> {:halt, stop}
      end
    end)
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} when responses != [] ->
        frames =
          for {:data, ref, data} <- responses, ref == state.ref, do: data

        handle_info({:early_data, frames}, %{state | conn: conn})

      {:ok, conn, _} ->
        {:noreply, %{state | conn: conn}}

      {:error, conn, _reason, responses} ->
        # The server may close TCP right after its final frames; deliver them first.
        frames = for {:data, ref, data} <- responses, ref == state.ref, do: data

        case handle_info({:early_data, frames}, %{state | conn: conn}) do
          {:noreply, state} ->
            send(state.owner, {:closed, self(), nil, "transport closed"})
            {:stop, :normal, state}

          stop ->
            stop
        end

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_frames([], state), do: {:noreply, state}

  defp handle_frames([{:text, text} | rest], state) do
    send(state.owner, {:frame, self(), Jason.decode!(text)})
    handle_frames(rest, state)
  end

  defp handle_frames([{:close, code, reason} | _], state) do
    send(state.owner, {:closed, self(), code, reason})
    {:stop, :normal, state}
  end

  defp handle_frames([{:ping, data} | rest], state) do
    {:ok, websocket, encoded} = Mint.WebSocket.encode(state.websocket, {:pong, data})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, encoded)
    handle_frames(rest, %{state | conn: conn, websocket: websocket})
  end

  defp handle_frames([_ | rest], state), do: handle_frames(rest, state)
end
