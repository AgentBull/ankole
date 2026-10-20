defmodule FeishuOpenAPI.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      FeishuOpenAPI.TokenStore,
      {Registry, keys: :unique, name: FeishuOpenAPI.TokenRegistry},
      {DynamicSupervisor, name: FeishuOpenAPI.TokenManager.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: FeishuOpenAPI.EventTaskSupervisor},
      FeishuOpenAPI.UserTokenManager
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
