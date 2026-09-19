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

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
