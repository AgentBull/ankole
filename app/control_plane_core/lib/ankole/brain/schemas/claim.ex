defmodule Ankole.Brain.Schemas.Claim do
  @moduledoc """
  One assertion with either Fact time and consolidation fields or Take
  calibration and resolution fields. Native checks keep the field families
  disjoint; actions own each change to the assertion and its history.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

  postgres do
    table("brain_claims")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:object_slug, "brain_claims_object_slug_fkey"},
      {:conversation_id, "brain_claims_conversation_id_fkey"},
      {:consolidated_into, "brain_claims_consolidated_into_fkey"},
      {:superseded_by, "brain_claims_superseded_by_fkey"}
    ])

    check_constraints do
      check_constraint(:claim_type, "brain_claims_type_values")
      check_constraint(:claim_type, "brain_claims_type_shape")
      check_constraint(:object_slug, "brain_claims_parent_xor")
      check_constraint(:claim, "brain_claims_required_text_present")
      check_constraint(:audience_scope, "brain_claims_audience_scope_shape")
      check_constraint(:graded_quality, "brain_claims_grade_shape")
      check_constraint(:graded_input_hash, "brain_claims_graded_input_shape")
      check_constraint(:resolved_quality, "brain_claims_resolution_quality_values")
      check_constraint(:resolved_outcome, "brain_claims_resolution_consistency")
      check_constraint(:embedding, "brain_claims_embedding_state")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:author, Ankole.Ash.Types.ActorRef)

    attribute(:claim_type, Ankole.Ash.Types.State,
      allow_nil?: false,
      constraints: [one_of: [:fact, :take]]
    )

    attribute(:object_slug, :string, constraints: [trim?: false])
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7)
    attribute(:claim, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:kind, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:holder, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:audience_scope, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:notability, :string, constraints: [trim?: false])
    attribute(:context, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:valid_from, :utc_datetime_usec)
    attribute(:valid_until, :utc_datetime_usec)
    attribute(:expired_at, :utc_datetime_usec)
    attribute(:consolidated_at, :utc_datetime_usec)
    attribute(:consolidated_into, Ankole.Ash.Types.UUIDv7)
    attribute(:confidence, :float)
    attribute(:provenance_session, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:weight, :float)
    attribute(:since_date, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:until_date, :date)
    attribute(:active, :boolean)
    attribute(:graded_quality, :string, constraints: [trim?: false])
    attribute(:graded_confidence, :float)
    attribute(:graded_at, :utc_datetime_usec)
    attribute(:graded_input_hash, :string, constraints: [trim?: false])
    attribute(:resolved_at, :utc_datetime_usec)
    attribute(:resolved_outcome, :boolean)
    attribute(:resolved_quality, :string, constraints: [trim?: false])
    attribute(:resolved_value, :float)
    attribute(:resolved_unit, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:resolution_provenance, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:resolved_by, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:superseded_by, Ankole.Ash.Types.UUIDv7)
    attribute(:provenance, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:embedding, Ankole.Ash.Types.Vector)
    attribute(:embedding_signature, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:embedding_error, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:embedded_at, :utc_datetime_usec)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    create :record_fact do
      transaction?(false)

      accept([
        :id,
        :author,
        :object_slug,
        :conversation_id,
        :claim,
        :kind,
        :holder,
        :audience_scope,
        :notability,
        :context,
        :valid_from,
        :valid_until,
        :confidence,
        :provenance_session,
        :provenance,
        :embedding,
        :embedding_signature,
        :embedded_at
      ])

      require_attributes([:notability, :valid_from, :confidence])
      change(set_attribute(:claim_type, :fact))
    end

    create :record_take do
      transaction?(false)

      accept([
        :id,
        :author,
        :object_slug,
        :conversation_id,
        :claim,
        :kind,
        :holder,
        :audience_scope,
        :weight,
        :since_date,
        :until_date,
        :provenance_session,
        :provenance,
        :embedding,
        :embedding_signature,
        :embedded_at
      ])

      require_attributes([:weight])
      change(set_attribute(:claim_type, :take))
      change(set_attribute(:active, true))
    end

    atomic_in_tx_update :expire_fact do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(claim_type == :fact)))
      change(set_attribute(:expired_at, arg(:at)))
      change(set_attribute(:updated_at, arg(:at)))
    end

    atomic_in_tx_update :deactivate_take do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
      change(filter(expr(claim_type == :take)))
      change(set_attribute(:active, false))
      change(set_attribute(:updated_at, arg(:at)))
    end

    atomic_in_tx_update :resolve_take do
      accept([
        :resolved_quality,
        :resolved_outcome,
        :resolved_value,
        :resolved_unit,
        :resolution_provenance,
        :resolved_by
      ])

      require_attributes([:resolved_quality])
      change(filter(expr(claim_type == :take and is_nil(resolved_at))))
      change(set_attribute(:resolved_at, &DateTime.utc_now/0))
      change(set_attribute(:active, false))
    end

    atomic_in_tx_update :supersede do
      accept([:superseded_by])
      require_attributes([:superseded_by])
      change(filter(expr(is_nil(superseded_by))))

      change(
        atomic_update(:expired_at, expr(if claim_type == :fact, do: now(), else: expired_at))
      )

      change(atomic_update(:active, expr(if claim_type == :take, do: false, else: active)))
    end

    atomic_in_tx_update :deduplicate do
      accept([:superseded_by])
      require_attributes([:superseded_by])
      change(filter(expr(claim_type == :fact and is_nil(superseded_by))))
      change(set_attribute(:expired_at, &DateTime.utc_now/0))
      change(set_attribute(:embedding, nil))
      change(set_attribute(:embedding_signature, nil))
      change(set_attribute(:embedding_error, nil))
      change(set_attribute(:embedded_at, nil))
    end

    atomic_in_tx_update :record_grade do
      accept([:graded_quality, :graded_confidence, :graded_at, :graded_input_hash])
      require_attributes([:graded_quality, :graded_confidence, :graded_at])
      change(filter(expr(claim_type == :take and active == true and is_nil(resolved_at))))
    end

    atomic_in_tx_update :consolidate do
      accept([:consolidated_at, :consolidated_into])
      require_attributes([:consolidated_at, :consolidated_into])
      change(filter(expr(claim_type == :fact)))
    end

    update :record_embedding do
      require_atomic?(true)
      accept([:embedding, :embedding_signature, :embedding_error, :embedded_at])
      argument(:input_embedded_at, :utc_datetime_usec)
      argument(:input_signature, :string, constraints: [trim?: false, allow_empty?: true])

      change(
        filter(
          expr(
            fragment("? IS NOT DISTINCT FROM ?", embedded_at, ^arg(:input_embedded_at)) and
              fragment("? IS NOT DISTINCT FROM ?", embedding_signature, ^arg(:input_signature))
          )
        )
      )
    end

    atomic_in_tx_update :append_forgetting_reason do
      accept([])
      argument(:reason, :string, allow_nil?: false, constraints: [trim?: false])
      change(atomic_update(:provenance, expr(provenance <> ^arg(:reason))))
    end

    atomic_in_tx_update :reparent do
      accept([:object_slug])
      require_attributes([:object_slug])
    end

    atomic_in_tx_update :reassign_holder do
      accept([:holder])
    end
  end

  @type t :: %__MODULE__{}
end
