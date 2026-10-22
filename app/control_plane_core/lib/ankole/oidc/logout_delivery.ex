defmodule Ankole.OIDC.LogoutDelivery do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.OIDC.Domain,
    extensions: [AshStateMachine]

  @undelivered_states [:pending, :delivering, :failed]
  postgres do
    table("oidc_logout_deliveries")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(session: "oidc_logout_deliveries_session_id_index")
    foreign_key_names(session_id: "oidc_logout_deliveries_session_id_fkey")

    check_constraints do
      check_constraint(:status, "oidc_logout_deliveries_status")
      check_constraint(:attempt_count, "oidc_logout_deliveries_attempt_count_nonnegative")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:session_id, Ankole.Ash.Types.UUIDv7, public?: true, allow_nil?: false)
    attribute(:endpoint, :string, public?: true, allow_nil?: false, constraints: [trim?: false])

    attribute(:attempt_count, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:last_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:next_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:delivered_at, :utc_datetime_usec, public?: true)
    attribute(:deadline, :utc_datetime_usec, public?: true, allow_nil?: false)
    attribute(:last_error, :string, public?: true, constraints: [trim?: false])
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:session, [:session_id], all_tenants?: true)
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:restart_in_tx, from: @undelivered_states, to: :pending)
      transition(:claim_in_tx, from: [:pending, :delivering], to: :delivering)
      transition(:exhaust_in_tx, from: [:pending, :delivering], to: :failed)
      transition(:acknowledge_in_tx, from: @undelivered_states, to: :delivered)
      transition(:reschedule_in_tx, from: @undelivered_states, to: :pending)
    end
  end

  actions do
    defaults([:read])

    create :enqueue_in_tx do
      accept([:session_id, :endpoint, :deadline, :next_attempt_at])
      transaction?(false)
    end

    atomic_in_tx_update :restart_in_tx do
      accept([:deadline, :next_attempt_at])
      change(transition_state(:pending))
    end

    atomic_in_tx_update :claim_in_tx do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(transition_state(:delivering))
      change(atomic_update(:attempt_count, expr(attempt_count + 1)))
      change(set_attribute(:last_attempt_at, arg(:at)))
    end

    atomic_in_tx_update :exhaust_in_tx do
      accept([])
      change(transition_state(:failed))
      change(set_attribute(:next_attempt_at, nil))
    end

    atomic_in_tx_update :acknowledge_in_tx do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(status != :delivered)))
      change(transition_state(:delivered))
      change(set_attribute(:delivered_at, arg(:at)))
      change(set_attribute(:next_attempt_at, nil))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:updated_at, arg(:at)))
    end

    atomic_in_tx_update :reschedule_in_tx do
      accept([:next_attempt_at, :last_error])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(status != :delivered)))
      change(transition_state(:pending))
      change(set_attribute(:updated_at, arg(:at)))
    end
  end

  @type t :: %__MODULE__{}
end
