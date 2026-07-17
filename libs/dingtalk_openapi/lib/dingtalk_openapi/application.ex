defmodule DingTalkOpenAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Order matters: the ETS token store and the Registry must be up before the
    # DynamicSupervisor that starts per-app TokenManagers (they register in the
    # Registry and read/write the store). The shared EventTaskSupervisor backs
    # async token fetches, proactive refreshes, and Stream frame dispatch.
    children = [
      DingTalkOpenAPI.TokenStore,
      {Registry, keys: :unique, name: DingTalkOpenAPI.TokenRegistry},
      {DynamicSupervisor, name: DingTalkOpenAPI.TokenManager.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: DingTalkOpenAPI.EventTaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DingTalkOpenAPI.Supervisor)
  end
end
