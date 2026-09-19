# Cluster tests start extra BEAM nodes and are run separately: mix test --only cluster
ExUnit.start(exclude: [:cluster])
Ecto.Adapters.SQL.Sandbox.mode(Arc.Repo, :manual)
