defmodule Arc.Apps do
  @moduledoc """
  Apps and their credentials.

  Every write updates Postgres, writes an audit row where the action is security
  relevant, and publishes the new config to `Arc.Apps.Cache` on every node, so a
  rotated secret stops verifying on the whole cluster as soon as the call returns.
  """
  import Ecto.Query

  alias Arc.Repo
  alias Arc.Audit
  alias Arc.Apps.{App, Cache, Config}

  @key_bytes 10
  @secret_bytes 10

  @doc "Lists every app, oldest first."
  def list_apps, do: Repo.all(from a in App, order_by: [asc: a.id], preload: :webhook_endpoints)

  def get_app!(id), do: App |> Repo.get!(id) |> Repo.preload(:webhook_endpoints)
  def get_app(id), do: App |> Repo.get(id) |> Repo.preload(:webhook_endpoints)

  @doc """
  Reloads an app from the database and publishes it to the cache on every node. Called
  after any change that affects the app's runtime config, such as a webhook edit.
  """
  def refresh(app_id) do
    case get_app(app_id) do
      nil -> Cache.publish_delete(app_id)
      app -> Cache.publish(Config.from_app(app))
    end

    :ok
  end

  @doc "Cached, decrypted config for the data plane."
  defdelegate get_config(id), to: Cache, as: :get
  defdelegate get_config_by_key(key), to: Cache, as: :get_by_key

  @doc "A blank changeset for the create form."
  def change_app(app \\ %App{}, attrs \\ %{}), do: App.settings_changeset(app, attrs)

  @doc """
  Creates an app with freshly generated credentials.

  Returns `{:ok, app, secret}`. The plaintext secret is also available on `app.secret`;
  it is returned separately to make the "shown once" contract explicit for callers.
  """
  def create_app(attrs, actor \\ nil) do
    secret = generate_secret()

    changeset =
      %App{}
      |> App.settings_changeset(attrs)
      |> App.credentials_changeset(%{key: generate_key(), secret: secret})

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:app, changeset)
    |> Ecto.Multi.run(:audit, fn _repo, %{app: app} ->
      Audit.log(actor, "app.created", app.id, %{name: app.name})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{app: app}} ->
        app = publish(app)
        {:ok, app, secret}

      {:error, :app, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc "Updates the settings of an app. Credentials cannot be changed here."
  def update_app(%App{} = app, attrs, actor \\ nil) do
    changeset = App.settings_changeset(app, attrs)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:app, changeset)
    |> Ecto.Multi.run(:audit, fn _repo, %{app: updated} ->
      changes = changeset.changes |> Map.keys() |> Enum.map(&to_string/1)
      Audit.log(actor, "app.updated", updated.id, %{fields: changes})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{app: updated}} ->
        updated = publish(updated)
        if app.enabled and not updated.enabled, do: Arc.Realtime.disconnect_app(updated.id)
        {:ok, updated}

      {:error, :app, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Replaces the app secret. The old secret stops verifying immediately on every node.
  Returns `{:ok, app, new_secret}`.
  """
  def rotate_secret(%App{} = app, actor \\ nil) do
    secret = generate_secret()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:app, Ecto.Changeset.change(app, secret: secret, updated_at: now()))
    |> Ecto.Multi.run(:audit, fn _repo, %{app: app} ->
      Audit.log(actor, "app.secret_rotated", app.id, %{})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{app: app}} ->
        {:ok, publish(app), secret}

      {:error, :app, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Sets the encryption master key used by encrypted channels, given as base64 of 32
  bytes. Pass `nil` to remove it, which disables publishing to encrypted channels.
  """
  def put_encryption_master_key(%App{} = app, key_base64, actor \\ nil) do
    decoded =
      case key_base64 do
        nil -> {:ok, nil}
        "" -> {:ok, nil}
        value -> Base.decode64(String.trim(value))
      end

    with {:ok, bytes} <- decoded,
         changeset =
           App.master_key_changeset(app, bytes) |> Ecto.Changeset.put_change(:updated_at, now()),
         {:ok, %{app: app}} <-
           Ecto.Multi.new()
           |> Ecto.Multi.update(:app, changeset)
           |> Ecto.Multi.run(:audit, fn _repo, %{app: app} ->
             Audit.log(actor, "app.encryption_master_key_changed", app.id, %{set: bytes != nil})
           end)
           |> Repo.transaction() do
      {:ok, publish(app)}
    else
      :error -> {:error, :invalid_base64}
      {:error, :app, changeset, _} -> {:error, changeset}
    end
  end

  @doc "Deletes an app, its webhook endpoints and deliveries. Live connections are closed."
  def delete_app(%App{} = app, actor \\ nil) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete(:app, app)
    |> Ecto.Multi.run(:audit, fn _repo, _ ->
      Audit.log(actor, "app.deleted", app.id, %{name: app.name})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{app: app}} ->
        Cache.publish_delete(app.id)
        Arc.Realtime.disconnect_app(app.id, :app_not_found)
        {:ok, app}

      {:error, :app, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc "Generates a new random encryption master key, base64 encoded."
  def generate_encryption_master_key, do: :crypto.strong_rand_bytes(32) |> Base.encode64()

  defp publish(app) do
    app = Repo.preload(app, :webhook_endpoints)
    Cache.publish(Config.from_app(app))
    app
  end

  defp generate_key, do: :crypto.strong_rand_bytes(@key_bytes) |> Base.encode16(case: :lower)

  defp generate_secret,
    do: :crypto.strong_rand_bytes(@secret_bytes) |> Base.encode16(case: :lower)

  defp now, do: DateTime.utc_now()
end
