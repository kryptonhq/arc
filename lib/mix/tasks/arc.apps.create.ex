defmodule Mix.Tasks.Arc.Apps.Create do
  @shortdoc "Creates an app and prints its credentials as JSON"
  @moduledoc """
  Creates an app from the command line and prints its credentials as JSON. The secret
  is printed once and cannot be retrieved again; rotate it from the dashboard if lost.

      mix arc.apps.create --name "Chat" [--client-events] [--encryption] [--max-connections N] \\
        [--webhook-url URL --webhook-events channel_occupied,channel_vacated]

  Pass `--unlimited-presence` to turn off the presence member ceiling (load tests).

  Against a running release, use `rpc` so the new app reaches the live node's cache:

      bin/arc rpc 'IO.puts(Jason.encode!(Arc.Release.create_app("Chat")))'
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          name: :string,
          client_events: :boolean,
          encryption: :boolean,
          max_connections: :integer,
          webhook_url: :string,
          unlimited_presence: :boolean,
          webhook_events: :string
        ]
      )

    name = Keyword.get(opts, :name) || Mix.raise("--name is required")

    attrs =
      %{
        "name" => name,
        "client_events_enabled" => Keyword.get(opts, :client_events, false),
        "enable_presence_limits" => not Keyword.get(opts, :unlimited_presence, false)
      }
      |> then(fn attrs ->
        case opts[:max_connections] do
          nil -> attrs
          max -> Map.put(attrs, "max_connections", max)
        end
      end)

    webhook =
      case opts[:webhook_url] do
        nil ->
          nil

        url ->
          events =
            (opts[:webhook_events] || Enum.join(Arc.Webhooks.event_types(), ","))
            |> String.split(",", trim: true)

          %{"url" => url, "events" => events}
      end

    Arc.Release.create_app(attrs,
      encryption: Keyword.get(opts, :encryption, false),
      webhook: webhook
    )
    |> Jason.encode!()
    |> Mix.shell().info()
  end
end
