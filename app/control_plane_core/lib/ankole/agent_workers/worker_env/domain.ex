defmodule Ankole.AgentWorkers.WorkerEnv.Domain do
  @moduledoc "Durable site and tenant shell variables."
  use Ash.Domain

  resources do
    resource(Ankole.AgentWorkers.WorkerEnv.EnvVar)
    resource(Ankole.AgentWorkers.WorkerEnv.SiteEnvVar)
  end
end
