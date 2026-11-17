defmodule Ankole.SiteConsole do
  @moduledoc """
  Cross-tenant read-only aggregation views for the site administration Console (`/api/v2/site`).

  Replaces client-side N-tenant fan-out polling in "All tenants" mode with single
  cursor-paginated queries joined against active (non-deleting) tenants.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(Ankole.SiteConsole.Aggregates)
  end

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      route(Ankole.SiteConsole.Aggregates, :get, "/overview", :overview,
        name: "get_site_overview"
      )

      route(Ankole.SiteConsole.Aggregates, :get, "/agents", :agents, name: "list_site_agents")

      route(Ankole.SiteConsole.Aggregates, :get, "/workers", :workers, name: "list_site_workers")

      route(Ankole.SiteConsole.Aggregates, :get, "/principals", :principals,
        name: "list_site_principals"
      )

      route(Ankole.SiteConsole.Aggregates, :get, "/signal-bindings", :signal_bindings,
        name: "list_site_signal_bindings"
      )

      route(Ankole.SiteConsole.Aggregates, :get, "/schedules", :schedules,
        name: "list_site_schedules"
      )

      route(
        Ankole.SiteConsole.Aggregates,
        :get,
        "/background-agent-jobs",
        :background_agent_jobs,
        name: "list_site_background_agent_jobs"
      )

      route(Ankole.SiteConsole.Aggregates, :get, "/ai-usage", :ai_usage,
        name: "get_site_ai_usage"
      )
    end
  end
end
