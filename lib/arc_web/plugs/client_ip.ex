defmodule ArcWeb.Plugs.ClientIp do
  @moduledoc """
  Replaces `conn.remote_ip` with the client's address from `X-Forwarded-For` when the
  request arrived from a trusted proxy, and records it as `client_ip` in log metadata.

  Trust is a list of CIDRs in `ARC_TRUSTED_PROXIES`. By default nothing is trusted and
  the header is ignored, so a client cannot choose its own address. When the peer is
  trusted, the rightmost address in the header that is *not* itself a trusted proxy is
  the client (proxies append; a spoofed leftmost entry is skipped).

  Runs before everything else in the endpoint so the WebSocket upgrade, the API, and
  the dashboard all see the same address.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    ip = client_ip(conn, Application.get_env(:arc, :trusted_proxies, []))
    Logger.metadata(client_ip: :inet.ntoa(ip) |> to_string())
    %{conn | remote_ip: ip}
  end

  @doc false
  def client_ip(conn, []), do: conn.remote_ip

  def client_ip(conn, trusted) do
    if trusted?(conn.remote_ip, trusted) do
      conn
      |> get_req_header("x-forwarded-for")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reverse()
      |> Enum.find_value(conn.remote_ip, fn candidate ->
        case :inet.parse_strict_address(String.to_charlist(candidate)) do
          {:ok, ip} -> if trusted?(ip, trusted), do: nil, else: ip
          _ -> nil
        end
      end)
    else
      conn.remote_ip
    end
  end

  @doc """
  Parses a comma-separated list of CIDRs (`10.0.0.0/8, 192.168.1.5, fd00::/8`) into
  `{address, prefix_length}` tuples. Raises on an entry that is not an address.
  """
  @spec parse_cidrs(String.t()) :: [{:inet.ip_address(), 0..128}]
  def parse_cidrs(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_cidr!/1)
  end

  defp parse_cidr!(entry) do
    {address, prefix} =
      case String.split(entry, "/", parts: 2) do
        [address] -> {address, nil}
        [address, prefix] -> {address, prefix}
      end

    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} ->
        max = if tuple_size(ip) == 4, do: 32, else: 128

        prefix =
          case prefix do
            nil -> max
            p -> String.to_integer(p)
          end

        if prefix < 0 or prefix > max, do: raise(ArgumentError, "bad prefix in #{entry}")
        {ip, prefix}

      _ ->
        raise ArgumentError, "#{inspect(entry)} is not an IP address or CIDR"
    end
  end

  defp trusted?(ip, cidrs), do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  defp in_cidr?(ip, {net, prefix}) when tuple_size(ip) == tuple_size(net) do
    <<a::bitstring-size(^prefix), _::bitstring>> = to_bits(ip)
    <<b::bitstring-size(^prefix), _::bitstring>> = to_bits(net)
    a == b
  end

  # An IPv4 client behind an IPv6-mapped proxy address (or the reverse) never matches.
  defp in_cidr?(_ip, _cidr), do: false

  defp to_bits({a, b, c, d}), do: <<a, b, c, d>>

  defp to_bits({a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
end
