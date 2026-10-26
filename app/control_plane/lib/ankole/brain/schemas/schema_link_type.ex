defmodule Ankole.Brain.Schemas.SchemaLinkType do
  @moduledoc "A registered relation predicate and its inverse."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_schema_link_types")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:pack_name, "brain_schema_link_types_pack_name_fkey"}])
    identity_index_names(name: "brain_schema_link_types_name_key")
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:inverse, :string, allow_nil?: true, constraints: [trim?: false])
    attribute(:pack_name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:name, [:name])
  end

  actions do
    defaults([:read])

    create :register do
      accept([:id, :name, :inverse, :pack_name, :created_at])
    end
  end

  @type t :: %__MODULE__{}
end
