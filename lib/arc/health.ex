defmodule Arc.Health do
  @moduledoc "Readiness: migrations applied and the app config cache warm."

  @ready_key {__MODULE__, :ready}

  @doc """
  True once the node can serve traffic. The migration check hits the database, so a
  positive answer is remembered; readiness does not flap back after it is reached.
  """
  def ready? do
    :persistent_term.get(@ready_key, false) or check()
  end

  defp check do
    ready = Arc.Apps.Cache.ready?() and migrations_applied?()
    if ready, do: :persistent_term.put(@ready_key, true)
    ready
  end

  defp migrations_applied? do
    Arc.Repo
    |> Ecto.Migrator.migrations()
    |> Enum.all?(fn {status, _version, _name} -> status == :up end)
  rescue
    _ -> false
  end
end
