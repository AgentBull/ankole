defmodule Ankole.Brain.Schemas.MetricRevision do
  @moduledoc """
  One immutable revision of a `metrics/` object's executable definition.

  A save of the metric object appends a revision when its definition changes;
  earlier revisions stay executable for callers that pin them. Drift
  detection is the only writer after insertion and moves a published
  revision to `needs_review`.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_metric_revisions")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(revision: "brain_metric_revisions_revision_key")

    foreign_key_names([
      {:metric_page_id, "brain_metric_revisions_metric_page_id_fkey"},
      {:dataset_binding_id, "brain_metric_revisions_dataset_binding_id_fkey"}
    ])

    check_constraints do
      check_constraint(:revision, "brain_metric_revisions_revision_positive")
      check_constraint(:source_kind, "brain_metric_revisions_source_kind_values")
      check_constraint(:status, "brain_metric_revisions_status_values")
      check_constraint(:grain, "brain_metric_revisions_text_present")
      check_constraint(:spec, "brain_metric_revisions_json_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:metric_page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:revision, :integer, allow_nil?: false)
    attribute(:dataset_binding_id, Ankole.Ash.Types.UUIDv7)
    attribute(:source_kind, :atom, allow_nil?: false, constraints: [one_of: [:base, :connector]])
    attribute(:source, Ankole.Ash.Types.JSONMap, allow_nil?: false)
    attribute(:spec, Ankole.Ash.Types.JSONMap, allow_nil?: false)
    attribute(:parameters, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])
    attribute(:field_types, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:source_columns, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])
    attribute(:grain, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:unit, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:addible_dimensions, Ankole.Ash.Types.JSONList, allow_nil?: false, default: [])
    attribute(:time_field, :string, constraints: [trim?: false])
    attribute(:numerator, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:denominator, :string, constraints: [trim?: false])

    attribute(:status, :atom,
      allow_nil?: false,
      constraints: [one_of: [:published, :needs_review, :retired]]
    )

    attribute(:review_reason, Ankole.Ash.Types.JSONMap)
    attribute(:page_revision, :integer, allow_nil?: false)
    attribute(:approved_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:revision, [:metric_page_id, :revision])
  end

  actions do
    defaults([:read])

    create :append do
      accept([
        :id,
        :metric_page_id,
        :revision,
        :dataset_binding_id,
        :source_kind,
        :source,
        :spec,
        :parameters,
        :field_types,
        :source_columns,
        :grain,
        :unit,
        :addible_dimensions,
        :time_field,
        :numerator,
        :denominator,
        :status,
        :page_revision,
        :approved_by,
        :created_at
      ])
    end

    update :mark_needs_review do
      require_atomic?(true)
      accept([:review_reason])
      change(filter(expr(status == :published)))
      change(set_attribute(:status, :needs_review))
    end
  end

  @type t :: %__MODULE__{}
end
