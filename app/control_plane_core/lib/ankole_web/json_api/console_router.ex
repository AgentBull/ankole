defmodule AnkoleWeb.JSONAPI.ConsoleRouter do
  @moduledoc "Serves the tenant Console JSON:API at `/api/v2`."

  use AnkoleWeb.JSONAPI.Router,
    scope: :console,
    prefix: "/api/v2",
    domains: [
      Ankole.AutomationJobs,
      Ankole.Brain,
      Ankole.OIDC,
      Ankole.Schedule,
      Ankole.Signals,
      Ankole.Principals,
      Ankole.AuthZ,
      Ankole.BackgroundAgentJobs,
      Ankole.AIAgent,
      Ankole.AIAgent.Library,
      Ankole.AgentWorkers,
      Ankole.AIGateway
    ]
end
