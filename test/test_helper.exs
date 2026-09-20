# Cluster tests start extra BEAM nodes and are run separately: mix test --only cluster
# Compose tests need docker-compose.cluster.yml running: mix test --only compose
ExUnit.start(exclude: [:cluster, :compose])
Ecto.Adapters.SQL.Sandbox.mode(Arc.Repo, :manual)
