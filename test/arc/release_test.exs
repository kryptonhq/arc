defmodule Arc.ReleaseTest do
  use Arc.DataCase, async: false

  import ExUnit.CaptureIO

  test "create_app returns credentials, with optional encryption and webhook" do
    creds = Arc.Release.create_app("From console")
    assert %{id: id, key: key, secret: secret, encryption_master_key: nil} = creds
    assert Arc.Apps.get_config(id).secret == secret
    assert Arc.Apps.get_config_by_key(key).id == id

    creds =
      Arc.Release.create_app(%{"name" => "Full"},
        encryption: true,
        webhook: %{"url" => "https://example.com/h", "events" => ["channel_occupied"]}
      )

    assert byte_size(Base.decode64!(creds.encryption_master_key)) == 32
    assert [%{url: "https://example.com/h"}] = Arc.Apps.get_config(creds.id).webhooks
  end

  test "mix arc.apps.create prints JSON credentials" do
    Mix.Task.reenable("arc.apps.create")

    output =
      capture_io(fn ->
        Mix.Tasks.Arc.Apps.Create.run(
          ~w(--name Task --client-events --max-connections 5 --webhook-url https://example.com/x)
        )
      end)

    creds = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
    config = Arc.Apps.get_config(creds["id"])
    assert config.client_events_enabled
    assert config.max_connections == 5
    assert [%{events: events}] = config.webhooks
    assert MapSet.size(events) == 6

    assert_raise Mix.Error, fn -> Mix.Tasks.Arc.Apps.Create.run([]) end
  end

  test "ensure_app is idempotent and writes credentials" do
    opts = [
      encryption: true,
      webhook: %{"url" => "http://demo:3000/api/webhooks", "events" => ["channel_occupied"]}
    ]

    first = Arc.Release.ensure_app(%{"name" => "Demo"}, opts)
    second = Arc.Release.ensure_app(%{"name" => "Demo"}, opts)

    assert first == second
    assert byte_size(Base.decode64!(first.encryption_master_key)) == 32
    assert length(Arc.Webhooks.list_endpoints(first.id)) == 1

    path =
      Path.join(System.tmp_dir!(), "arc-demo-#{System.unique_integer([:positive])}/creds.json")

    capture_io(fn -> Arc.Release.write_app_credentials(path, %{"name" => "Demo"}) end)
    assert Jason.decode!(File.read!(path))["key"] == first.key
  end

  test "mix arc.gen.keys prints usable keys" do
    output = capture_io(fn -> Mix.Tasks.Arc.Gen.Keys.run([]) end)
    [_, secret_key_base] = Regex.run(~r/SECRET_KEY_BASE=(\S+)/, output)
    [_, encryption_key] = Regex.run(~r/ARC_ENCRYPTION_KEY=(\S+)/, output)
    assert byte_size(secret_key_base) == 64
    assert byte_size(Base.decode64!(encryption_key)) == 32
  end
end
