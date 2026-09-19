defmodule Arc.Admin.OIDC.ProviderKeeper do
  @moduledoc """
  Keeps the OIDC provider configuration worker running without letting it affect the
  rest of the node.

  The worker exits when the identity provider is unreachable or misconfigured. Under a
  normal supervisor, repeated exits would exhaust the restart budget and shut down
  the application, taking every client connection with it. This process traps the
  worker's exits and restarts it with backoff instead, so an identity-provider outage
  only affects dashboard sign-in.
  """
  use GenServer
  require Logger

  @max_backoff 30_000

  def start_link(worker_opts), do: GenServer.start_link(__MODULE__, worker_opts, name: __MODULE__)

  @impl true
  def init(worker_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{opts: worker_opts, pid: nil, attempt: 0}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start_worker(state)}

  @impl true
  def handle_info(:start, state), do: {:noreply, start_worker(state)}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    Logger.warning("OIDC provider configuration failed, sign-in unavailable: #{inspect(reason)}")
    {:noreply, schedule_restart(%{state | pid: nil})}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp start_worker(state) do
    case Oidcc.ProviderConfiguration.Worker.start_link(state.opts) do
      {:ok, pid} ->
        %{state | pid: pid, attempt: 0}

      {:error, reason} ->
        Logger.warning("OIDC provider configuration could not start: #{inspect(reason)}")
        schedule_restart(state)
    end
  end

  defp schedule_restart(state) do
    delay = min(@max_backoff, 1_000 * Integer.pow(2, state.attempt))
    Process.send_after(self(), :start, delay)
    %{state | attempt: state.attempt + 1}
  end
end
