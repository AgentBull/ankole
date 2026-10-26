defmodule AnkoleWeb.JSONAPI.SiteRouter do
  @moduledoc "Serves the site administration JSON:API at `/api/v2/site`."

  use AnkoleWeb.JSONAPI.Router,
    scope: :site,
    prefix: "/api/v2/site",
    domains: [
      Ankole.Tenants,
      Ankole.AppConfigure.Site,
      Ankole.ControlPlanePlugins,
      Ankole.AgentWorkers.Providers,
      Ankole.AIGateway.ProviderConfigs
    ]
end
