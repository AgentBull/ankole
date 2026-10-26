defmodule Ankole.Conversations.Delivery.Supervisor do
  @moduledoc "Supervises rebuildable provider preview tasks and renderers."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Task.Supervisor, name: Ankole.Conversations.Delivery.PreviewTasks},
        {DynamicSupervisor, name: Ankole.Conversations.Delivery.Previews, strategy: :one_for_one}
      ],
      strategy: :one_for_all
    )
  end
end
