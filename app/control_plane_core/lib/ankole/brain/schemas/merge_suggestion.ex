defmodule Ankole.Brain.Schemas.MergeSuggestion do
  @moduledoc "Immutable proposal facts and their one-time review decision."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Brain.Domain,
    extensions: [AshStateMachine]

  postgres do
    table("brain_merge_suggestions")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(proposal: "brain_merge_suggestions_pair_key")

    check_constraints do
      check_constraint(:status, "brain_merge_suggestions_status_values")
      check_constraint(:a_slug, "brain_merge_suggestions_pair_order")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:a_slug, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:b_slug, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:reason, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:decided_by, Ankole.Ash.Types.ActorRef)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    attribute(:decided_at, :utc_datetime_usec)
  end

  identities do
    identity(:proposal, [:a_slug, :b_slug])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:approve, from: :pending, to: :approved)
      transition(:reject, from: :pending, to: :rejected)
    end
  end

  actions do
    defaults([:read])

    create_if_absent :suggest do
      accept([:id, :a_slug, :b_slug, :reason, :created_at])
      upsert_identity(:proposal)
    end

    atomic_in_tx_update :approve do
      accept([])
      argument(:decided_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
      change(set_attribute(:decided_by, arg(:decided_by)))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:approved))
    end

    atomic_in_tx_update :reject do
      accept([])
      argument(:decided_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
      change(set_attribute(:decided_by, arg(:decided_by)))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
      change(transition_state(:rejected))
    end
  end

  @type t :: %__MODULE__{}
end
