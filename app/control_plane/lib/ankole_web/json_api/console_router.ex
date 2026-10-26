defmodule AnkoleWeb.JSONAPI.ConsoleRouter do
  @moduledoc "Serves the tenant Console JSON:API at `/api/v2`."

  use AnkoleWeb.JSONAPI.Router,
    scope: :console,
    prefix: "/api/v2",
    domains: [
      Ankole.AutomationJobs,
      Ankole.Files,
      Ankole.Sessions,
      Ankole.BackgroundActivities,
      Ankole.ConsoleReadiness,
      Ankole.AppConfigure,
      Ankole.Brain,
      Ankole.OIDC,
      Ankole.IdentityProviders,
      Ankole.Schedule,
      Ankole.Signals,
      Ankole.Principals,
      Ankole.AuthZ,
      Ankole.BackgroundAgentJobs,
      Ankole.AIAgent,
      Ankole.AgentWorkers,
      Ankole.AIGateway
    ]
end
