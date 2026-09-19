defmodule Arc.Test.WebhookReceiver do
  @moduledoc """
  A throwaway HTTP server that forwards every request it receives to a test process
  as `{:webhook, %{headers, body}}` and answers with a status chosen by the test.
  """
  @behaviour Plug

  def start(owner, status \\ 200) do
    Agent.start(fn -> status end, name: agent_name(owner))

    {:ok, pid} =
      Bandit.start_link(plug: {__MODULE__, owner}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, "http://127.0.0.1:#{port}/hook"}
  end

  def set_status(owner, status), do: Agent.update(agent_name(owner), fn _ -> status end)

  defp agent_name(owner), do: {:global, {__MODULE__, owner}}

  @impl true
  def init(owner), do: owner

  @impl true
  def call(conn, owner) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send(owner, {:webhook, %{headers: Map.new(conn.req_headers), body: body}})

    case Agent.get(agent_name(owner), & &1) do
      :timeout ->
        Process.sleep(2_000)
        Plug.Conn.send_resp(conn, 200, "late")

      status ->
        Plug.Conn.send_resp(conn, status, "ok")
    end
  end
end
