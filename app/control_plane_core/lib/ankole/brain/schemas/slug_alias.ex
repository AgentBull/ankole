defmodule Ankole.Brain.Schemas.SlugAlias do
  @moduledoc "One immutable redirect identity with an explicit merge target update."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

  postgres do
    table("brain_slug_aliases")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(alias: "brain_slug_aliases_alias_key")
    foreign_key_names([{:canonical_slug, "brain_slug_aliases_canonical_slug_fkey"}])

    check_constraints do
      check_constraint(:canonical_slug, "brain_slug_aliases_no_self")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:alias_slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:canonical_slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:notes, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:alias, [:alias_slug])
  end

  actions do
    defaults([:read])

    create :add do
      transaction?(false)
      accept([:id, :alias_slug, :canonical_slug, :notes, :created_at])
    end

    atomic_in_tx_update :repoint do
      accept([:canonical_slug])
    end
  end

  @type t :: %__MODULE__{}
end
