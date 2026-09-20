defmodule Arc.RateLimiter do
  @moduledoc """
  Node-local token buckets in ETS.

  Used for the per-app HTTP API limit, per-address connection attempts, and the
  per-connection subscribe and auth-failure limits. Buckets are not coordinated across nodes, so a
  cluster-wide limit is approximate (up to N times the rate on N nodes). That is a
  deliberate trade: an exact global limiter would add a network hop to every publish.
  Concurrent callers on one node may also over-admit by a handful of requests; the
  limit is a safety valve, not a billing meter.
  """
  use GenServer

  @table :arc_rate_limits

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Takes one token from bucket `key`, which refills at `rate` tokens per second up to
  `burst`. Returns `:ok` or `{:error, retry_after_ms}`.
  """
  @spec take(term(), number(), number()) :: :ok | {:error, non_neg_integer()}
  def take(key, rate, burst) do
    now = System.monotonic_time(:millisecond)

    {tokens, at} =
      case :ets.lookup(@table, key) do
        [{_, tokens, at}] -> {tokens, at}
        [] -> {burst * 1.0, now}
      end

    tokens = min(burst * 1.0, tokens + (now - at) * rate / 1000)

    if tokens >= 1 do
      :ets.insert(@table, {key, tokens - 1, now})
      :ok
    else
      :ets.insert(@table, {key, tokens, now})
      {:error, ceil((1 - tokens) * 1000 / rate)}
    end
  end

  @doc "Forgets a bucket."
  def reset(key), do: :ets.delete(@table, key)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    {:ok, nil}
  end
end
