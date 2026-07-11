defmodule SlackOpenAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Task.Supervisor, name: SlackOpenAPI.EventTaskSupervisor}],
      strategy: :one_for_one,
      name: SlackOpenAPI.Supervisor
    )
  end
end
