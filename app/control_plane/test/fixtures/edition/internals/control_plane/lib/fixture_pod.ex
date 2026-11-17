defmodule Ankole.EditionFixture.PodModule do
  use Ankole.Ash.OperationResource,
    domain: Ankole.EditionFixture.PodDomain,
    extensions: [Ankole.AuthZ.Extension],
    authorizers: [Ankole.AuthZ.Authorizer]

  authz do
    scope(:tenant_console)
    allow(:settings, resource: "tenant_console:fixture_settings", action: "read")
  end

  json_api do
    type("fixture_settings")
  end

  actions do
    action :settings, :map do
      constraints(
        fields: [
          tenantID: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
          principalUID: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false]
        ]
      )

      run(fn _input, context ->
        {:ok,
         %{
           tenantID: Ankole.Repo.tenant_id!(),
           principalUID: Ankole.AuthZ.Actor.uid(context.actor)
         }}
      end)
    end
  end
end

defmodule Ankole.EditionFixture.PodDomain do
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(Ankole.EditionFixture.PodModule)
  end

  json_api do
    authorize?(true)
    show_raised_errors?(false)

    routes do
      base_route "/fixture-settings", Ankole.EditionFixture.PodModule do
        route(:get, "/", :settings, name: "fixturePodSettings")
      end
    end
  end
end

defmodule Ankole.EditionFixture.PodJSONAPIRouter do
  use AnkoleWeb.JSONAPI.Router,
    scope: :fixture_pod,
    title: "Fixture Pod API",
    domains: [Ankole.EditionFixture.PodDomain],
    prefix: "/api/v2/fixture-pod",
    before_dispatch: {AnkoleWeb.JSONAPI.Context, :before_dispatch, [:pod]}
end

defmodule Ankole.EditionFixture.JSONAPIRouter do
  use AnkoleWeb.JSONAPI.Router,
    scope: :fixture,
    title: "Fixture account API",
    domains: [],
    prefix: "/api/v2/fixture",
    before_dispatch: {AnkoleWeb.JSONAPI.Context, :before_dispatch, [:site]}
end

defmodule Ankole.EditionFixture.SiteJSONAPIRouter do
  use AnkoleWeb.JSONAPI.Router,
    scope: :fixture_site,
    title: "Fixture site API",
    context_scope: :site,
    domains: [],
    prefix: "/api/v2/fixture-site"
end
