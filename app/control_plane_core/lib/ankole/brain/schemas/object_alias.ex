defmodule Ankole.Brain.Schemas.ObjectAlias do
  @moduledoc "One normalized name candidate; different objects can share a name."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

  postgres do
    table("brain_object_aliases")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(candidate: "brain_object_aliases_dedup_key")
    foreign_key_names([{:object_slug, "brain_object_aliases_object_slug_fkey"}])

    check_constraints do
      check_constraint(:alias_norm, "brain_object_aliases_alias_present")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:alias_norm, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:object_slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:candidate, [:alias_norm, :object_slug])
  end

  actions do
    defaults([:read])

    create_if_absent :add do
      accept([:id, :alias_norm, :object_slug, :created_at])
      upsert_identity(:candidate)
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
