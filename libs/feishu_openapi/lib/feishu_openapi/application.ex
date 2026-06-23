defmodule FeishuOpenAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FeishuOpenAPI.TokenStore,
      {Registry, keys: :unique, name: FeishuOpenAPI.TokenRegistry},
      {DynamicSupervisor, name: FeishuOpenAPI.TokenManager.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: FeishuOpenAPI.EventTaskSupervisor},
      FeishuOpenAPI.UserTokenManager
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FeishuOpenAPI.Supervisor)
  end
end
