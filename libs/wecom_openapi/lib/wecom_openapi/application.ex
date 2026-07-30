defmodule WeComOpenAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Order matters: the ETS token store and the Registry must be up before the
    # DynamicSupervisor that starts per-credential TokenManagers (they register
    # in the Registry and read/write the store). The shared EventTaskSupervisor
    # backs async token fetches, proactive refreshes, and bot frame dispatch.
    children = [
      WeComOpenAPI.TokenStore,
      {Registry, keys: :unique, name: WeComOpenAPI.TokenRegistry},
      {DynamicSupervisor, name: WeComOpenAPI.TokenManager.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: WeComOpenAPI.EventTaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: WeComOpenAPI.Supervisor)
  end
end
