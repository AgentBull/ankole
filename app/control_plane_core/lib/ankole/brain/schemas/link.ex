defmodule Ankole.Brain.Schemas.Link do
  @moduledoc "One immutable directed edge with native null-equal retry identity."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

  postgres do
    table("brain_links")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(edge: "brain_links_dedup_key")

    foreign_key_names([
      {:from_object_slug, "brain_links_from_object_slug_fkey"},
      {:to_object_slug, "brain_links_to_object_slug_fkey"},
      {:origin_object_slug, "brain_links_origin_object_slug_fkey"}
    ])

    check_constraints do
      check_constraint(:link_source, "brain_links_source_shape")
      check_constraint(:link_kind, "brain_links_kind_values")
      check_constraint(:resolution_type, "brain_links_resolution_values")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:from_object_slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:to_object_slug, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:link_type, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true],
      default: ""
    )

    attribute(:context, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true],
      default: ""
    )

    attribute(:link_source, :string, constraints: [trim?: false])
    attribute(:link_kind, :string, constraints: [trim?: false])
    attribute(:origin_object_slug, :string, constraints: [trim?: false])
    attribute(:origin_field, :string, constraints: [trim?: false])
    attribute(:resolution_type, :string, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(
      :edge,
      [:from_object_slug, :to_object_slug, :link_type, :link_source, :origin_object_slug],
      nils_distinct?: false
    )
  end

  actions do
    defaults([:read])

    create_if_absent :add do
      transaction?(false)

      accept([
        :id,
        :from_object_slug,
        :to_object_slug,
        :link_type,
        :context,
        :link_source,
        :link_kind,
        :origin_object_slug,
        :origin_field,
        :resolution_type,
        :created_at
      ])

      upsert_identity(:edge)
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
