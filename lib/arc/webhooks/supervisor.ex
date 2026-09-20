defmodule Arc.Webhooks.Supervisor do
  @moduledoc "Supervises event debouncing, batching, and delivery."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor,
       name: Arc.Webhooks.TaskSupervisor,
       max_children:
         Application.fetch_env!(:arc, Arc.Webhooks) |> Keyword.fetch!(:max_concurrency)},
      Arc.Webhooks.Batcher,
      Arc.Webhooks.Events,
      Arc.Webhooks.Scheduler
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
