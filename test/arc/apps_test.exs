defmodule Arc.AppsTest do
  use Arc.DataCase, async: false

  alias Arc.{Apps, Audit}
  alias Arc.Apps.{App, Cache}

  describe "create_app/2" do
    test "generates hex credentials and returns the secret once" do
      assert {:ok, %App{} = app, secret} = Apps.create_app(%{"name" => "Chat"})
      assert app.key =~ ~r/\A[0-9a-f]{20}\z/
      assert secret =~ ~r/\A[0-9a-f]{20}\z/
      assert app.secret == secret
      assert app.enabled
      refute app.client_events_enabled
      assert app.max_presence_members == 100
    end

    test "stores the secret encrypted at rest" do
      {:ok, app, secret} = Apps.create_app(%{"name" => "Encrypted"})

      %{rows: [[raw]]} = Repo.query!("SELECT secret FROM apps WHERE id = $1", [app.id])
      refute raw == secret
      refute String.contains?(raw, secret)

      assert Apps.get_app!(app.id).secret == secret
    end

    test "publishes the config to the cache" do
      {:ok, app, secret} =
        Apps.create_app(%{"name" => "Cached", "client_events_enabled" => "true"})

      assert %{secret: ^secret, client_events_enabled: true} = Cache.get(app.id)
      assert Cache.get_by_key(app.key).id == app.id
      assert Cache.get(Integer.to_string(app.id)).id == app.id
    end

    test "validates settings" do
      assert {:error, changeset} = Apps.create_app(%{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name

      assert {:error, changeset} = Apps.create_app(%{"name" => "x", "max_connections" => "0"})
      assert errors_on(changeset).max_connections != []
    end

    test "writes an audit row" do
      {:ok, app, _} = Apps.create_app(%{"name" => "Audited"})
      assert [%{action: "app.created", app_id: id}] = Audit.list(app_id: app.id)
      assert id == app.id
    end
  end

  describe "rotate_secret/2" do
    test "replaces the secret everywhere and audits it" do
      {:ok, app, old} = Apps.create_app(%{"name" => "Rotate"})
      {:ok, app, new} = Apps.rotate_secret(app)

      refute old == new
      assert Apps.get_app!(app.id).secret == new
      assert Cache.get(app.id).secret == new
      assert Enum.any?(Audit.list(app_id: app.id), &(&1.action == "app.secret_rotated"))
    end
  end

  describe "update_app/3" do
    test "updates settings and the cache" do
      app = Arc.Test.Fixtures.app_fixture()

      {:ok, app} =
        Apps.update_app(app, %{"client_events_enabled" => true, "max_connections" => 5})

      assert %{client_events_enabled: true, max_connections: 5} = Cache.get(app.id)
    end

    test "rejects invalid settings" do
      app = Arc.Test.Fixtures.app_fixture()
      assert {:error, _} = Apps.update_app(app, %{"max_payload_bytes" => 10})
    end
  end

  describe "put_encryption_master_key/3" do
    test "accepts 32 bytes of base64 and can be cleared" do
      app = Arc.Test.Fixtures.app_fixture()
      key = Apps.generate_encryption_master_key()

      {:ok, app} = Apps.put_encryption_master_key(app, key)
      assert Cache.get(app.id).encryption_master_key == Base.decode64!(key)

      {:ok, app} = Apps.put_encryption_master_key(app, nil)
      assert Cache.get(app.id).encryption_master_key == nil
    end

    test "rejects keys of the wrong length or encoding" do
      app = Arc.Test.Fixtures.app_fixture()
      assert {:error, :invalid_base64} = Apps.put_encryption_master_key(app, "not base64!")

      assert {:error, %Ecto.Changeset{}} =
               Apps.put_encryption_master_key(app, Base.encode64("short"))
    end
  end

  describe "delete_app/2" do
    test "removes the app from the cache" do
      app = Arc.Test.Fixtures.app_fixture()
      {:ok, _} = Apps.delete_app(app)
      assert Cache.get(app.id) == nil
      assert Cache.get_by_key(app.key) == nil
      assert Apps.get_app(app.id) == nil
    end
  end

  describe "cache" do
    test "ignores stale versions" do
      app = Arc.Test.Fixtures.app_fixture()
      current = Cache.get(app.id)
      assert :stale = Cache.put(%{current | name: "old", version: current.version - 1})
      assert Cache.get(app.id).name == current.name
    end

    test "warm/0 loads apps from the database and drops deleted ones" do
      app = Arc.Test.Fixtures.app_fixture()
      Cache.put(%Arc.Apps.Config{id: -1, key: "ghost", secret: "x"})

      {:ok, _count} = Cache.warm()
      assert Cache.get(app.id)
      assert Cache.get(-1) == nil
      assert Cache.ready?()
    end

    test "replicated updates are applied by the cache process" do
      app = Arc.Test.Fixtures.app_fixture()
      config = %{Cache.get(app.id) | name: "remote", version: Cache.get(app.id).version + 1}
      send(Cache, {:app_updated, config})
      _ = :sys.get_state(Cache)
      assert Cache.get(app.id).name == "remote"

      send(Cache, {:app_deleted, app.id})
      _ = :sys.get_state(Cache)
      assert Cache.get(app.id) == nil
    end

    test "config inspect never shows the secret" do
      app = Arc.Test.Fixtures.app_fixture()
      refute inspect(Cache.get(app.id)) =~ app.secret
    end
  end
end
