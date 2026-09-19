defmodule Arc.Release do
  @moduledoc """
  Release tasks, run by the container entrypoint before the node starts:

      bin/arc eval "Arc.Release.migrate()"
  """
  @app :arc

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates an app and returns its credentials, including the one-time secret. Used by
  `mix arc.apps.create` and from a release shell. Accepts a name or a map of settings.
  """
  def create_app(attrs, opts \\ [])
  def create_app(name, opts) when is_binary(name), do: create_app(%{"name" => name}, opts)

  def create_app(attrs, opts) when is_map(attrs) do
    Application.ensure_all_started(@app)
    {:ok, app, secret} = Arc.Apps.create_app(attrs)

    master_key =
      if Keyword.get(opts, :encryption, false) do
        key = Arc.Apps.generate_encryption_master_key()
        {:ok, _} = Arc.Apps.put_encryption_master_key(app, key)
        key
      end

    case Keyword.get(opts, :webhook) do
      nil -> :ok
      webhook -> {:ok, _} = Arc.Webhooks.create_endpoint(app, webhook)
    end

    %{id: app.id, key: app.key, secret: secret, encryption_master_key: master_key}
  end

  @doc """
  Finds an app by name or creates it, then makes sure it has an encryption master key
  and a webhook endpoint when asked for. Safe to run on every boot; used by the
  compose stack to provision the example app. Returns credentials like `create_app/2`.
  """
  def ensure_app(attrs, opts \\ []) when is_map(attrs) do
    Application.ensure_all_started(@app)
    name = Map.fetch!(attrs, "name")

    app =
      case Arc.Repo.get_by(Arc.Apps.App, name: name) do
        nil ->
          {:ok, app, _secret} = Arc.Apps.create_app(attrs)
          app

        app ->
          app
      end

    app =
      if Keyword.get(opts, :encryption, false) and is_nil(app.encryption_master_key) do
        {:ok, app} =
          Arc.Apps.put_encryption_master_key(app, Arc.Apps.generate_encryption_master_key())

        app
      else
        app
      end

    with %{"url" => url} = webhook <- Keyword.get(opts, :webhook),
         false <- Enum.any?(Arc.Webhooks.list_endpoints(app.id), &(&1.url == url)) do
      {:ok, _} = Arc.Webhooks.create_endpoint(app, webhook)
    end

    %{
      id: app.id,
      key: app.key,
      secret: app.secret,
      encryption_master_key: app.encryption_master_key && Base.encode64(app.encryption_master_key)
    }
  end

  @doc "Runs `ensure_app/2` and writes the credentials as JSON to `path`."
  def write_app_credentials(path, attrs, opts \\ []) do
    credentials = ensure_app(attrs, opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(credentials))
    IO.puts("wrote credentials for app #{credentials.id} to #{path}")
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
