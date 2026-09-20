defmodule Arc.Webhooks.Deliverer do
  @moduledoc """
  Sends one webhook request and records the outcome on its `webhook_deliveries` row.

  Each attempt runs in its own task under a `Task.Supervisor`. The request is signed
  over the exact bytes sent: the body is serialised once and the same binary is both
  signed and posted.

  * `2xx` — delivered.
  * `4xx` — failed without retry; the receiver rejected it and repeating will not help.
  * `5xx`, timeouts, and connection errors — retried on the configured schedule
    (1s, 5s, 30s, 2m, 10m by default), then failed.

  Rows are claimed with a lease (`next_attempt_at` in the future while in flight), so a
  node that dies mid-request leaves a row that `Arc.Webhooks.Scheduler` retries once
  the lease expires.

  At most `max_concurrency` attempts run at once per node. Beyond that, a new delivery
  is recorded as pending and picked up by the scheduler when a slot frees, so a retry
  storm cannot hold every Postgres connection or outbound socket.
  """
  require Logger

  alias Arc.Repo
  alias Arc.Apps.Cache
  alias Arc.Webhooks.Delivery

  @lease_seconds 60

  @doc """
  Records a new delivery and starts its first attempt. When every slot is busy the
  row is left pending for the scheduler. Returns the task pid, or `{:ok, :queued}`.
  """
  def enqueue(app_id, endpoint_id, payload) do
    case start_task(fn -> record_and_attempt(app_id, endpoint_id, payload) end) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :max_children} ->
        record(app_id, endpoint_id, payload, "pending", DateTime.utc_now())
        {:ok, :queued}
    end
  end

  @doc """
  Starts an attempt for a delivery already claimed by the scheduler. If no slot is
  free the claim is released so the next poll picks the row up again.
  """
  def start(%Delivery{} = delivery) do
    case start_task(fn -> attempt(delivery) end) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :max_children} ->
        release(delivery)
        {:ok, :queued}
    end
  end

  @doc "Attempts that can still be started on this node before `max_concurrency`."
  def free_slots do
    limit = Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(:max_concurrency)
    running = Arc.Webhooks.TaskSupervisor |> Task.Supervisor.children() |> length()
    max(0, limit - running)
  end

  defp start_task(fun), do: Task.Supervisor.start_child(Arc.Webhooks.TaskSupervisor, fun)

  defp record_and_attempt(app_id, endpoint_id, payload) do
    case record(app_id, endpoint_id, payload, "in_flight", lease_until()) do
      {:ok, delivery} -> attempt(delivery)
      :error -> :ok
    end
  end

  defp record(app_id, endpoint_id, payload, status, next_attempt_at) do
    {:ok,
     Repo.insert!(%Delivery{
       app_id: app_id,
       endpoint_id: endpoint_id,
       payload: payload,
       status: status,
       next_attempt_at: next_attempt_at
     })}
  rescue
    error ->
      Logger.warning(
        "webhook delivery could not be recorded app_id=#{app_id}: #{Exception.message(error)}"
      )

      :error
  end

  defp release(delivery) do
    delivery
    |> Ecto.Changeset.change(status: "pending", next_attempt_at: DateTime.utc_now())
    |> Repo.update()
  rescue
    _ -> :error
  end

  @doc "The lease end for a newly claimed delivery."
  def lease_until, do: DateTime.add(DateTime.utc_now(), @lease_seconds, :second)

  @doc false
  def attempt(%Delivery{} = delivery) do
    with %{} = app <- Cache.get(delivery.app_id),
         %{} = endpoint <- Enum.find(app.webhooks, &(&1.id == delivery.endpoint_id)) do
      body = Jason.encode!(delivery.payload)
      attempts = delivery.attempts + 1

      case post(endpoint.url, body, headers(app, endpoint, body)) do
        {:ok, status} when status in 200..299 ->
          finish(delivery, %{
            status: "delivered",
            attempts: attempts,
            delivered_at: DateTime.utc_now(),
            last_error: nil
          })

        {:ok, status} when status in 400..499 ->
          fail(delivery, attempts, "HTTP #{status}: receiver rejected the request, not retrying")

        {:ok, status} ->
          retry(delivery, attempts, "HTTP #{status}")

        {:error, reason} ->
          retry(delivery, attempts, reason)
      end
    else
      nil -> fail(delivery, delivery.attempts, "Endpoint no longer exists or is inactive")
    end
  end

  defp headers(app, endpoint, body) do
    base = [
      {"content-type", "application/json"},
      {"x-pusher-key", app.key},
      {"x-pusher-signature", Arc.Crypto.hmac_sha256_hex(app.secret, body)}
    ]

    # Endpoints may carry their own secret; its signature is sent alongside, so a
    # receiver can verify without holding the app secret.
    case endpoint.secret do
      secret when is_binary(secret) and secret != "" ->
        [{"x-arc-signature", Arc.Crypto.hmac_sha256_hex(secret, body)} | base]

      _ ->
        base
    end
  end

  defp post(url, body, headers) do
    timeout = Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(:request_timeout)

    case Req.post(url,
           body: body,
           headers: headers,
           retry: false,
           redirect: false,
           decode_body: false,
           connect_options: [timeout: timeout],
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, other} -> {:error, inspect(other)}
    end
  end

  defp retry(delivery, attempts, error) do
    schedule = Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(:retry_schedule)

    case Enum.at(schedule, attempts - 1) do
      nil ->
        fail(delivery, attempts, "#{error}; giving up after #{attempts} attempts")

      delay ->
        :telemetry.execute([:arc, :webhook, :delivery], %{count: 1}, %{status: "retry"})

        finish(delivery, %{
          status: "pending",
          attempts: attempts,
          last_error: error,
          next_attempt_at: DateTime.add(DateTime.utc_now(), delay, :second)
        })
    end
  end

  defp fail(delivery, attempts, error) do
    Logger.warning(
      "webhook delivery failed app_id=#{delivery.app_id} endpoint_id=#{delivery.endpoint_id}: #{error}"
    )

    finish(delivery, %{
      status: "failed",
      attempts: attempts,
      last_error: error,
      next_attempt_at: nil
    })
  end

  defp finish(delivery, changes) do
    if changes.status in ["delivered", "failed"] do
      :telemetry.execute([:arc, :webhook, :delivery], %{count: 1}, %{status: changes.status})
    end

    delivery |> Ecto.Changeset.change(changes) |> Repo.update!()
  end
end
