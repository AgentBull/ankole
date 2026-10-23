defmodule AnkoleWeb.JSONAPI.ConsoleRouter do
  @moduledoc "Serves the tenant Console JSON:API at `/api/v2`."

  use AnkoleWeb.JSONAPI.Router,
    scope: :console,
    prefix: "/api/v2",
    domains: [
      Ankole.BackgroundAgentJobs,
      Ankole.AIAgent,
      Ankole.Principals,
      Ankole.AgentWorkers,
      Ankole.AIGateway
    ]
end
