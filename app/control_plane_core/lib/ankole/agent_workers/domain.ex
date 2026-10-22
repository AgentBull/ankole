defmodule Ankole.AgentWorkers.Domain do
  @moduledoc "Worker configuration and the durable lifecycle of each Agent's Worker."
  use Ash.Domain

  resources do
    resource(Ankole.AgentWorkers.Providers.Provider)
    resource(Ankole.AgentWorkers.AgentWorker)
  end
end
