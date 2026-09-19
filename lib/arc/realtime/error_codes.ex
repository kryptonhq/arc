defmodule Arc.Realtime.ErrorCodes do
  @moduledoc """
  Error codes sent in `pusher:error` frames and used as WebSocket close codes.

  Client SDKs decide what to do from the band, not the individual number:

  | Band      | Client behaviour             |
  | --------- | ---------------------------- |
  | 4000–4099 | Do not reconnect             |
  | 4100–4199 | Reconnect after backoff      |
  | 4200–4299 | Reconnect immediately        |
  | 4300–4399 | Close, do not retry          |

  4000 is deliberately unused: SDKs treat it as "TLS only" and switch transports.

  Codes marked non-closing are sent in an error frame while the connection stays open.
  """

  @codes %{
    # Do not reconnect.
    app_not_found: {4001, "Could not find app by key"},
    app_disabled: {4003, "App is disabled"},
    over_connection_quota: {4004, "App is over its connection limit"},
    path_not_found: {4005, "Path not found"},
    invalid_version: {4006, "Invalid version string format"},
    unsupported_protocol: {4007, "Unsupported protocol version"},
    no_protocol_version: {4008, "No protocol version supplied"},
    unauthorized: {4009, "Connection is unauthorized"},
    # Reconnect after backoff.
    over_capacity: {4100, "Over capacity"},
    shutting_down: {4101, "Node is shutting down"},
    slow_consumer: {4102, "Client is not consuming messages fast enough"},
    # Reconnect immediately.
    generic_reconnect: {4200, "Generic reconnect"},
    pong_timeout: {4201, "Pong reply not received"},
    inactivity: {4202, "Closed after inactivity"},
    # Close, do not retry.
    terminated: {4300, "Connection terminated by the application"},
    # Non-closing. Errors without a code are reported with `code: null`, which SDKs
    # surface to the application without changing connection state.
    client_event_rate_limited: {4301, "Client event rejected due to rate limit"},
    invalid_frame: {nil, "Invalid frame"},
    client_event_rejected: {nil, "Client event rejected"},
    invalid_channel: {nil, "Invalid channel name"},
    signin_failed: {nil, "Sign-in failed"}
  }

  @doc "Returns `{code, default_message}` for a reason atom."
  def fetch!(reason), do: Map.fetch!(@codes, reason)

  def code(reason), do: reason |> fetch!() |> elem(0)
  def message(reason), do: reason |> fetch!() |> elem(1)

  @doc "All reasons, for documentation and conformance tests."
  def all, do: @codes
end
