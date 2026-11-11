defmodule Ankole.Brain.Schemas.EntityIdentifier do
  @moduledoc """
  One business identifier of a Brain entity, such as an ERP supplier ID.
  Each namespace and value belongs to at most one entity.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_entity_identifiers")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(value: "brain_entity_identifiers_value_key")
    foreign_key_names([{:entity_page_id, "brain_entity_identifiers_entity_page_id_fkey"}])

    check_constraints do
      check_constraint(:namespace, "brain_entity_identifiers_present")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:entity_page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:namespace, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:value, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:value, [:namespace, :value])
  end

  actions do
    defaults([:read])

    create_if_absent :add do
      accept([:id, :entity_page_id, :namespace, :value, :created_at])
      upsert_identity(:value)
    end

    destroy :remove do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
