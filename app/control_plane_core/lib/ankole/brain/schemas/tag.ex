defmodule Ankole.Brain.Schemas.Tag do
  @moduledoc "One immutable tag membership on an object."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

  postgres do
    table("brain_tags")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(object_tag: "brain_tags_object_tag_key")
    foreign_key_names([{:object_slug, "brain_tags_object_slug_fkey"}])

    check_constraints do
      check_constraint(:tag, "brain_tags_tag_present")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:object_slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:tag, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:object_tag, [:object_slug, :tag])
  end

  actions do
    defaults([:read])

    create_if_absent :add do
      transaction?(false)
      accept([:id, :object_slug, :tag, :created_at])
      upsert_identity(:object_tag)
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
