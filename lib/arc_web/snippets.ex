defmodule ArcWeb.Snippets do
  @moduledoc """
  Copyable configuration for the dashboard's credentials panel: a browser client and a
  Django `settings.py` block, filled in with this installation's public host and port.
  """

  @doc "Public connection details, from the endpoint's `url` configuration."
  def public_endpoint do
    url = ArcWeb.Endpoint.config(:url) || []
    scheme = Keyword.get(url, :scheme, "http")
    port = Keyword.get(url, :port) || if(scheme == "https", do: 443, else: 80)
    %{host: Keyword.get(url, :host, "localhost"), port: port, tls: scheme == "https"}
  end

  def javascript(app) do
    %{host: host, port: port, tls: tls} = public_endpoint()

    """
    // npm install pusher-js
    import Pusher from "pusher-js";

    const arc = new Pusher("#{app.key}", {
      wsHost: "#{host}",
      wsPort: #{port},
      wssPort: #{port},
      forceTLS: #{tls},
      enabledTransports: ["ws", "wss"],
      cluster: "arc", // required by the SDK, ignored by Arc
      channelAuthorization: { endpoint: "/realtime/auth/", transport: "ajax" },
    });

    arc.subscribe("my-channel").bind("my-event", (data) => console.log(data));
    """
  end

  def django(app, secret) do
    %{host: host, port: port, tls: tls} = public_endpoint()

    """
    # settings.py  (pip install pusher)
    ARC = {
        "app_id": "#{app.id}",
        "key": "#{app.key}",
        "secret": "#{secret || "<your app secret>"}",
        "host": "#{host}",
        "port": #{port},
        "ssl": #{if tls, do: "True", else: "False"},
    }

    # anywhere in your project
    import pusher
    from django.conf import settings

    arc = pusher.Pusher(**settings.ARC)
    arc.trigger("my-channel", "my-event", {"message": "hello"})
    """
  end
end
