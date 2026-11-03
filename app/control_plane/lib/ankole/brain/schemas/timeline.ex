defmodule Ankole.Brain.Schemas.Timeline do
  @moduledoc "One immutable event with an optional subject and a required permission source."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_timelines")
    repo(Ankole.Repo)
    migrate?(false)

    identity_index_names(
      event: "brain_timelines_dedup_key",
      event_object: "brain_timelines_event_dedup_key"
    )

    identity_wheres_to_sql(event_object: "event_page_id IS NOT NULL")

    foreign_key_names([
      {:subject_page_id, "brain_timelines_subject_page_id_fkey"},
      {:event_page_id, "brain_timelines_event_page_id_fkey"}
    ])

    check_constraints do
      check_constraint(:summary, "brain_timelines_summary_present")
      check_constraint(:provenance, "brain_timelines_provenance_present")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:subject_page_id, Ankole.Ash.Types.UUIDv7)
    attribute(:author, Ankole.Ash.Types.ActorRef)
    attribute(:date, :date, allow_nil?: false)
    attribute(:provenance, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:summary, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:detail, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true],
      default: ""
    )

    attribute(:event_page_id, Ankole.Ash.Types.UUIDv7)
    attribute(:source_node_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:event, [:subject_page_id, :source_node_id, :date, :summary, :provenance],
      nils_distinct?: false
    )

    identity(:event_object, [:event_page_id, :source_node_id, :date],
      where: expr(not is_nil(event_page_id))
    )
  end

  actions do
    defaults([:read])

    destroy :remove do
      transaction?(false)
    end

    create_if_absent :record do
      accept([
        :id,
        :subject_page_id,
        :author,
        :date,
        :provenance,
        :summary,
        :detail,
        :event_page_id,
        :source_node_id,
        :created_at
      ])

      upsert_identity(:event)
    end
  end

  relationships do
    belongs_to :source_node, Ankole.Pod.Page do
      source_attribute(:source_node_id)
      define_attribute?(false)
      attribute_type(Ankole.Ash.Types.UUIDv7)
    end

    belongs_to :object, Ankole.Brain.Schemas.Page do
      source_attribute(:subject_page_id)
      destination_attribute(:id)
      define_attribute?(false)
      attribute_type(Ankole.Ash.Types.UUIDv7)
    end
  end

  @type t :: %__MODULE__{}
end
