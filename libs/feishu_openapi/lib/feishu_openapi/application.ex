defmodule FeishuOpenAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Order matters: the ETS token store and the Registry must be up before the
    # DynamicSupervisor that starts per-app TokenManagers (they register in the
    # Registry and read/write the store). The shared EventTaskSupervisor backs
    # async token fetches, refreshes, and app_ticket resends.
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
