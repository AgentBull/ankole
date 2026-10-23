defmodule Ankole.Brain.Schemas.Timeline do
  @moduledoc "One immutable scoped event, compiled into the object retrieval projection."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_timelines")
    repo(Ankole.Repo)
    migrate?(false)

    identity_index_names(
      event: "brain_timelines_dedup_key",
      event_object: "brain_timelines_event_dedup_key"
    )

    identity_wheres_to_sql(event_object: "event_object_slug IS NOT NULL")

    foreign_key_names([
      {:object_slug, "brain_timelines_object_slug_fkey"},
      {:event_object_slug, "brain_timelines_event_object_slug_fkey"}
    ])

    check_constraints do
      check_constraint(:summary, "brain_timelines_summary_present")
      check_constraint(:provenance, "brain_timelines_provenance_present")
      check_constraint(:audience_scope, "brain_timelines_audience_scope_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:object_slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:author, Ankole.Ash.Types.ActorRef)
    attribute(:date, :date, allow_nil?: false)
    attribute(:provenance, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:summary, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:detail, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true],
      default: ""
    )

    attribute(:event_object_slug, :string, constraints: [trim?: false])
    attribute(:audience_scope, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:event, [:object_slug, :date, :summary, :provenance])

    identity(:event_object, [:event_object_slug, :date],
      where: expr(not is_nil(event_object_slug))
    )
  end

  actions do
    defaults([:read])

    create_if_absent :record do
      accept([
        :id,
        :object_slug,
        :author,
        :date,
        :provenance,
        :summary,
        :detail,
        :event_object_slug,
        :audience_scope,
        :created_at
      ])

      upsert_identity(:event)
    end

    # The operation owns its transaction; Ankole.Brain.Timelines gives the steps.
    action :write_timeline, :struct do
      constraints(instance_of: __MODULE__)
      argument(:attrs, :map, allow_nil?: false)
      argument(:writer, :term, allow_nil?: false)
      argument(:options, :term, default: [])

      run(__MODULE__.Actions)
    end
  end

  relationships do
    belongs_to :object, Ankole.Brain.Schemas.Object do
      source_attribute(:object_slug)
      destination_attribute(:slug)
      define_attribute?(false)
      attribute_type(:string)
    end
  end

  @type t :: %__MODULE__{}
end
