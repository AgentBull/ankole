defmodule Ankole.Principals.Agent.WorkerProviderID do
  @moduledoc "Gives the Worker provider of each Agent."
  use Ash.Resource.Calculation

  @impl true
  def calculate(agents, _opts, _context) do
    providers = Ankole.AgentWorkers.Providers.provider_ids(Enum.map(agents, & &1.uid))
    Enum.map(agents, &Map.get(providers, &1.uid))
  end
end
