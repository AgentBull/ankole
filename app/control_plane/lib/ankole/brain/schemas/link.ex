defmodule Ankole.Brain.Schemas.Link do
  @moduledoc "One immutable directed edge with native null-equal retry identity."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_links")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(edge: "brain_links_dedup_key")

    foreign_key_names([
      {:from_page_id, "brain_links_from_page_id_fkey"},
      {:to_page_id, "brain_links_to_page_id_fkey"},
      {:origin_page_id, "brain_links_origin_page_id_fkey"}
    ])

    check_constraints do
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

    attribute(:from_page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:to_page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

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
    attribute(:origin_page_id, Ankole.Ash.Types.UUIDv7)
    attribute(:origin_field, :string, constraints: [trim?: false])
    attribute(:resolution_type, :string, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(
      :edge,
      [:from_page_id, :to_page_id, :link_type, :link_source, :origin_page_id],
      nils_distinct?: false
    )
  end

  actions do
    defaults([:read])

    create_if_absent :add do
      accept([
        :id,
        :from_page_id,
        :to_page_id,
        :link_type,
        :context,
        :link_source,
        :link_kind,
        :origin_page_id,
        :origin_field,
        :resolution_type,
        :created_at
      ])

      upsert_identity(:edge)
    end

    destroy :remove do
      require_atomic?(true)
    end
  end

  relationships do
    belongs_to :from_page, Ankole.Files.Schemas.Node do
      source_attribute(:from_page_id)
      define_attribute?(false)
      attribute_type(Ankole.Ash.Types.UUIDv7)
    end

    belongs_to :to_page, Ankole.Files.Schemas.Node do
      source_attribute(:to_page_id)
      define_attribute?(false)
      attribute_type(Ankole.Ash.Types.UUIDv7)
    end
  end

  @type t :: %__MODULE__{}
end
