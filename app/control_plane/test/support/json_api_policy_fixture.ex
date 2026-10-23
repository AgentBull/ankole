defmodule JSONAPIPolicyFixture.Note do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: JSONAPIPolicyFixture.Domain,
    extensions: [AshJsonApi.Resource]

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

defmodule JSONAPIPolicyFixture.Domain do
  @moduledoc false
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(JSONAPIPolicyFixture.Note)
  end

  json_api do
    authorize?(false)

    routes do
      base_route "/notes", JSONAPIPolicyFixture.Note do
        index(:read, name: "list_notes")
        get(:read, name: "get_note")
        post(:create, name: "create_note")
        patch(:publish, name: "publish_note")
      end
    end
  end
end

defmodule JSONAPIPolicyFixture.Router do
  @moduledoc false
  use AnkoleWeb.JSONAPI.Router,
    scope: :console,
    prefix: "/probe",
    domains: [JSONAPIPolicyFixture.Domain],
    rules: %{
      {JSONAPIPolicyFixture.Note, :index, :read} => {"json_api_probe:notes", "read"},
      {JSONAPIPolicyFixture.Note, :get, :read} => {"json_api_probe:note:{id}", "read"},
      # A root administrator has no grant for this action.
      {JSONAPIPolicyFixture.Note, :patch, :publish} => {"json_api_probe:note:{id}", "publish"}
    }
end
