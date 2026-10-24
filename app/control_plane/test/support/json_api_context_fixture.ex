defmodule JSONAPIContextFixture.Note do
  @moduledoc false
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: JSONAPIContextFixture.Domain,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:read, resource: "site_console:json_api_probe:notes", action: "read")
    allow(:create, resource: "site_console:json_api_probe:notes", action: "create")
    allow(:publish, resource: "site_console:json_api_probe:notes", action: "publish")
  end

  postgres do
    table("json_api_policy_notes")
    schema("pg_temp")
    repo(Ankole.Repo)
    migrate?(false)
  end

  json_api do
    type("json_api_policy_note")
    derive_filter?(false)
    derive_sort?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:body, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:body])
    end

    update :publish do
      accept([:body])
    end
  end
end

defmodule JSONAPIContextFixture.Domain do
  @moduledoc false
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(JSONAPIContextFixture.Note)
  end

  json_api do
    authorize?(true)

    routes do
      base_route "/notes", JSONAPIContextFixture.Note do
        index(:read, name: "list_notes")
        get(:read, name: "get_note")
        post(:create, name: "create_note")
        patch(:publish, name: "publish_note")
      end
    end
  end
end

defmodule JSONAPIContextFixture.Router do
  @moduledoc false
  use AnkoleWeb.JSONAPI.Router,
    scope: :console,
    prefix: "/probe",
    domains: [JSONAPIContextFixture.Domain]
end
