defmodule WeComOpenAPI.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      WeComOpenAPI.TokenStore,
      {Registry, keys: :unique, name: WeComOpenAPI.TokenRegistry},
      {DynamicSupervisor, name: WeComOpenAPI.TokenManager.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: WeComOpenAPI.EventTaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
