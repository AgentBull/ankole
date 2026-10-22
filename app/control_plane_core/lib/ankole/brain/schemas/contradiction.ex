defmodule Ankole.Brain.Schemas.Contradiction do
  @moduledoc "Immutable proposal facts and their one-time review decision."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Brain.Domain,
    extensions: [AshStateMachine]

  postgres do
    table("brain_contradictions")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(proposal: "brain_contradictions_pair_key")

    foreign_key_names([
      {:a_claim_id, "brain_contradictions_a_claim_id_fkey"},
      {:b_claim_id, "brain_contradictions_b_claim_id_fkey"}
    ])

    check_constraints do
      check_constraint(:severity, "brain_contradictions_severity_values")
      check_constraint(:status, "brain_contradictions_status_values")
      check_constraint(:confidence, "brain_contradictions_confidence_range")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:a_claim_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:b_claim_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:verdict, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:axis, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:severity, :atom,
      allow_nil?: false,
      constraints: [one_of: [:info, :low, :medium, :high]]
    )

    attribute(:confidence, :float, allow_nil?: false, constraints: [min: 0.0, max: 1.0])

    attribute(:resolution_note, :string,
      allow_nil?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    attribute(:decided_at, :utc_datetime_usec)
  end

  identities do
    identity(:proposal, [:a_claim_id, :b_claim_id])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:open, :dismissed])

    transitions do
      transition(:resolve, from: :open, to: :resolved)
      transition(:dismiss, from: :open, to: :dismissed)
    end
  end

  actions do
    defaults([:read])

    create_if_absent :record_verdict do
      accept([
        :id,
        :a_claim_id,
        :b_claim_id,
        :verdict,
        :axis,
        :severity,
        :confidence,
        :created_at
      ])

      upsert_identity(:proposal)
      change(Ankole.Brain.Changes.ClassifyContradiction)
    end

    atomic_in_tx_update :resolve do
      accept([:resolution_note])
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:resolved))
    end

    atomic_in_tx_update :dismiss do
      accept([:resolution_note])
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:dismissed))
    end
  end

  @type t :: %__MODULE__{}
end
