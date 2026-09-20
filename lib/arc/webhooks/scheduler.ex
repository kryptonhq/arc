defmodule Arc.Webhooks.Scheduler do
  @moduledoc """
  Picks up deliveries that are due for a retry, or whose in-flight lease expired
  because the node sending them went away, and prunes old rows.

  Claiming uses `FOR UPDATE SKIP LOCKED`, so every node in a cluster can run a
  scheduler without two of them sending the same delivery.
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias Arc.Repo
  alias Arc.Webhooks.{Deliverer, Delivery}

  @batch 100
  @prune_every :timer.hours(1)
  @depth_every :timer.seconds(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one poll immediately. Returns the number of deliveries started."
  def poll_now, do: GenServer.call(__MODULE__, :poll)

  @impl true
  def init(_opts) do
    # Tests drive the scheduler explicitly with poll_now/0.
    if Keyword.get(Application.fetch_env!(:arc, Arc.Webhooks), :scheduler, true) do
      schedule(:poll, config(:poll_interval))
      schedule(:prune, @prune_every)
      schedule(:depth, @depth_every)
    end

    {:ok, nil}
  end

  @impl true
  def handle_call(:poll, _from, state), do: {:reply, poll(), state}

  @impl true
  def handle_info(:poll, state) do
    poll()
    schedule(:poll, config(:poll_interval))
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    safely("prune", fn ->
      cutoff = DateTime.add(DateTime.utc_now(), -config(:retention_days) * 86_400, :second)
      Repo.delete_all(from d in Delivery, where: d.inserted_at < ^cutoff)
    end)

    schedule(:prune, @prune_every)
    {:noreply, state}
  end

  def handle_info(:depth, state) do
    safely("queue depth", fn ->
      :telemetry.execute([:arc, :webhook, :queue], %{depth: Arc.Webhooks.queue_depth()}, %{})
    end)

    schedule(:depth, @depth_every)
    {:noreply, state}
  end

  defp poll do
    case Deliverer.free_slots() do
      0 -> 0
      slots -> claim(min(slots, @batch))
    end
  end

  defp claim(limit) do
    safely("poll", fn ->
      now = DateTime.utc_now()

      due =
        from(d in Delivery,
          where: d.status in ["pending", "in_flight"] and d.next_attempt_at <= ^now,
          order_by: [asc: d.next_attempt_at],
          limit: ^limit,
          lock: "FOR UPDATE SKIP LOCKED",
          select: d.id
        )

      {_, claimed} =
        Repo.update_all(
          from(d in Delivery, where: d.id in subquery(due), select: d),
          set: [status: "in_flight", next_attempt_at: Deliverer.lease_until()]
        )

      Enum.each(claimed, &Deliverer.start/1)
      length(claimed)
    end) || 0
  end

  defp safely(what, fun) do
    fun.()
  rescue
    error ->
      Logger.warning("webhook scheduler #{what} failed: #{Exception.message(error)}")
      nil
  end

  defp schedule(message, after_ms), do: Process.send_after(self(), message, after_ms)

  defp config(key), do: Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(key)
end
