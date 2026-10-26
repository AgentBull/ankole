defmodule Ankole.Brain.Schemas.Claim do
  @moduledoc """
  One assertion with either Fact time and consolidation fields or Take
  calibration and resolution fields. Native checks keep the field families
  disjoint; actions own each change to the assertion and its history.
  """
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Brain,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_list, resource: "site_console:brain", action: "read")
    allow(:console_supersede, resource: "site_console:brain", action: "update")
    allow(:console_forget, resource: "site_console:brain", action: "update")
    allow(:console_resolve, resource: "site_console:brain", action: "update")
  end

  json_api do
    type("brain_claim")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :claim_type,
      :claim,
      :kind,
      :holder,
      :audience_scope,
      :author,
      :object_slug,
      :conversation_id,
      :notability,
      :confidence,
      :valid_from,
      :valid_until,
      :expired_at,
      :weight,
      :active,
      :since_date,
      :until_date,
      :graded_quality,
      :graded_confidence,
      :resolved_quality,
      :resolved_outcome,
      :resolved_at,
      :superseded_by,
      :provenance,
      :created_at
    ])
  end

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

    attribute(:author, Ankole.Ash.Types.ActorRef, public?: true)

    attribute(:claim_type, Ankole.Ash.Types.State,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:fact, :take]]
    )

    attribute(:object_slug, :string, public?: true, constraints: [trim?: false])
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:claim, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:kind, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:holder, :string, public?: true, allow_nil?: false, constraints: [trim?: false])

    attribute(:audience_scope, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:notability, :string, public?: true, constraints: [trim?: false])
    attribute(:context, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:valid_from, :utc_datetime_usec, public?: true)
    attribute(:valid_until, :utc_datetime_usec, public?: true)
    attribute(:expired_at, :utc_datetime_usec, public?: true)
    attribute(:consolidated_at, :utc_datetime_usec)
    attribute(:consolidated_into, Ankole.Ash.Types.UUIDv7)
    attribute(:confidence, :float, public?: true)
    attribute(:provenance_session, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:weight, :float, public?: true)

    attribute(:since_date, :string,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:until_date, :date, public?: true)
    attribute(:active, :boolean, public?: true)
    attribute(:graded_quality, :string, public?: true, constraints: [trim?: false])
    attribute(:graded_confidence, :float, public?: true)
    attribute(:graded_at, :utc_datetime_usec)
    attribute(:graded_input_hash, :string, constraints: [trim?: false])
    attribute(:resolved_at, :utc_datetime_usec, public?: true)
    attribute(:resolved_outcome, :boolean, public?: true)
    attribute(:resolved_quality, :string, public?: true, constraints: [trim?: false])
    attribute(:resolved_value, :float)
    attribute(:resolved_unit, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:resolution_provenance, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:resolved_by, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:superseded_by, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:provenance, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:embedding, :vector)
    attribute(:embedding_signature, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:embedding_error, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:embedded_at, :utc_datetime_usec)
    create_timestamp(:created_at, public?: true)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    # The Console list: Claims, newest first, of one Object,
    # one Claim type, the current state, and a text search.
    read :console_list do
      pagination(keyset?: true, default_limit: 100, max_page_size: 100, countable: false)

      argument(:object_slug, :string, constraints: [trim?: false])
      argument(:claim_type, :atom, constraints: [one_of: [:fact, :take]])
      argument(:status, :atom, constraints: [one_of: [:current]])
      argument(:search, :string)
      prepare(__MODULE__.Preparations)
    end

    create :record_fact do
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

    update :expire_fact do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(claim_type == :fact)))
      change(set_attribute(:expired_at, arg(:at)))
      change(set_attribute(:updated_at, arg(:at)))
    end

    update :deactivate_take do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
      change(filter(expr(claim_type == :take)))
      change(set_attribute(:active, false))
      change(set_attribute(:updated_at, arg(:at)))
    end

    update :resolve_take do
      require_atomic?(true)

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

    update :supersede do
      require_atomic?(true)
      accept([:superseded_by])
      require_attributes([:superseded_by])
      change(filter(expr(is_nil(superseded_by))))

      change(
        atomic_update(:expired_at, expr(if claim_type == :fact, do: now(), else: expired_at))
      )

      change(atomic_update(:active, expr(if claim_type == :take, do: false, else: active)))
    end

    update :deduplicate do
      require_atomic?(true)
      accept([:superseded_by])
      require_attributes([:superseded_by])
      change(filter(expr(claim_type == :fact and is_nil(superseded_by))))
      change(set_attribute(:expired_at, &DateTime.utc_now/0))
      change(set_attribute(:embedding, nil))
      change(set_attribute(:embedding_signature, nil))
      change(set_attribute(:embedding_error, nil))
      change(set_attribute(:embedded_at, nil))
    end

    update :record_grade do
      require_atomic?(true)
      accept([:graded_quality, :graded_confidence, :graded_at, :graded_input_hash])
      require_attributes([:graded_quality, :graded_confidence, :graded_at])
      change(filter(expr(claim_type == :take and active == true and is_nil(resolved_at))))
    end

    update :consolidate do
      require_atomic?(true)
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

    update :append_forgetting_reason do
      require_atomic?(true)
      accept([])
      argument(:reason, :string, allow_nil?: false, constraints: [trim?: false])
      change(atomic_update(:provenance, expr(provenance <> ^arg(:reason))))
    end

    update :reparent do
      require_atomic?(true)
      accept([:object_slug])
      require_attributes([:object_slug])
    end

    update :reassign_holder do
      require_atomic?(true)
      accept([:holder])
    end

    # The Console operations. The operator is the actor of the action
    # (Ankole.Brain.Console); a Console administrator can forget and resolve
    # each Claim.
    action :console_supersede, :struct do
      constraints(instance_of: __MODULE__)
      argument(:claim_id, :uuid, allow_nil?: false)
      argument(:claim, :string, allow_nil?: false)
      argument(:kind, :string)
      argument(:confidence, :float)
      argument(:weight, :float)
      argument(:notability, :string)
      argument(:audience_scope, :string)
      argument(:provenance, :string)
      argument(:embedding, :term, public?: false)

      prepare(__MODULE__.Preparations)

      run(__MODULE__.Actions)
    end

    action :console_forget, :struct do
      constraints(instance_of: __MODULE__)
      argument(:claim_id, :uuid, allow_nil?: false)
      argument(:reason, :string, constraints: [trim?: false, allow_empty?: true])

      run(__MODULE__.Actions)
    end

    action :console_resolve, :struct do
      constraints(instance_of: __MODULE__)
      argument(:claim_id, :uuid, allow_nil?: false)
      argument(:resolved_quality, :string)
      argument(:resolved_outcome, :boolean)
      argument(:resolved_value, :float)
      argument(:resolved_unit, :string)
      argument(:resolution_provenance, :string)

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

  calculations do
    calculate(
      :current?,
      :boolean,
      expr(
        (claim_type == :fact and is_nil(expired_at)) or (claim_type == :take and active == true)
      )
    )

    # A claim on a soft-deleted or missing Object is not available. A signal
    # channel claim has no Object slug and stays available.
    calculate(
      :live_parent?,
      :boolean,
      expr(is_nil(object_slug) or exists(object, is_nil(deleted_at)))
    )

    # Self-healing embeds never-tried rows before rows that failed before.
    calculate(:embedding_failed?, :boolean, expr(not is_nil(embedding_error)))

    calculate(
      :current_external_fact?,
      :boolean,
      expr(claim_type == :fact and is_nil(expired_at) and is_nil(superseded_by) and live_parent?)
    )
  end

  @type t :: %__MODULE__{}
end
