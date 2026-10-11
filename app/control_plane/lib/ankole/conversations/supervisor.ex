defmodule Ankole.Conversations.Supervisor do
  @moduledoc "Supervises temporary drivers and their independent tasks. PostgreSQL owns recovery."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Task.Supervisor, name: Ankole.Conversations.Tasks},
        {DynamicSupervisor, name: Ankole.Conversations.Drivers, strategy: :one_for_one}
      ],
      strategy: :one_for_one
    )
  end
end
