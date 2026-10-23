defmodule AnkoleWeb.JSONAPI.Mount do
  @moduledoc """
  Mounts the JSON:API router of a scope in `AnkoleWeb.Router`.

  A JSON:API router compiles its routes from its domains. A `forward` to the
  router module makes `AnkoleWeb.Router` depend on each domain at compile time,
  and the domains use `AnkoleWeb.Router` (for example through verified routes):
  a compile cycle. This plug gets the scope atom and names the router module
  only in a function, so the dependency is a run-time dependency.
  """
  @behaviour Plug

  alias AnkoleWeb.JSONAPI.{ConsoleRouter, SiteRouter}

  @impl true
  def init(scope) when scope in [:site, :console], do: scope

  @impl true
  def call(conn, scope) do
    router = router(scope)
    router.call(conn, router.init([]))
  end

  defp router(:site), do: SiteRouter
  defp router(:console), do: ConsoleRouter
end
