defmodule DingTalkOpenAPI.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      DingTalkOpenAPI.TokenStore,
      {Registry, keys: :unique, name: DingTalkOpenAPI.TokenRegistry},
      {DynamicSupervisor, name: DingTalkOpenAPI.TokenManager.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: DingTalkOpenAPI.EventTaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
