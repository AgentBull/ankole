defmodule AnkoleWeb.JSONAPI.ConsoleRouter do
  @moduledoc "Serves the tenant Console JSON:API at `/api/v2`."

  use AnkoleWeb.JSONAPI.Router,
    scope: :console,
    prefix: "/api/v2",
    domains: [
      # J2 identity
      Ankole.Principals,
      Ankole.AuthZ
    ]
end
