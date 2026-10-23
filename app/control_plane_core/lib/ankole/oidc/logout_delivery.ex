defmodule Ankole.OIDC.LogoutDelivery do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.OIDC,
    extensions: [AshStateMachine, AshJsonApi.Resource]

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

  relationships do
    belongs_to :session, Ankole.OIDC.Session do
      source_attribute(:session_id)
      define_attribute?(false)
      attribute_type(Ankole.Ash.Types.UUIDv7)
    end
  end

  calculations do
    calculate(:principal_uid, :string, expr(session.principal_uid), public?: true)
  end

  # The endpoint stays private: the Console shows the client configuration.
  json_api do
    type("oidc_logout_delivery")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :id,
      :session_id,
      :principal_uid,
      :status,
      :attempt_count,
      :last_attempt_at,
      :next_attempt_at,
      :delivered_at,
      :deadline,
      :last_error
    ])
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

    read :lookup_across_tenants do
      multitenancy(:allow_global)
    end

    # The Console list of the deliveries of one client, the newest first.
    read :console_list do
      argument(:client_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      filter(expr(session.client_id == ^arg(:client_id)))
      prepare(build(sort: [inserted_at: :desc]))
    end

    # The Console retries a delivery of one client. A delivery of another
    # client reads as not found.
    action :console_retry, :struct do
      constraints(instance_of: __MODULE__)
      argument(:client_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      run(__MODULE__.Actions)
    end

    create :enqueue_in_tx do
      accept([:session_id, :endpoint, :deadline, :next_attempt_at])
    end

    update :restart_in_tx do
      require_atomic?(true)
      accept([:deadline, :next_attempt_at])
      change(transition_state(:pending))
    end

    update :claim_in_tx do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(transition_state(:delivering))
      change(atomic_update(:attempt_count, expr(attempt_count + 1)))
      change(set_attribute(:last_attempt_at, arg(:at)))
    end

    update :exhaust_in_tx do
      require_atomic?(true)
      accept([])
      change(transition_state(:failed))
      change(set_attribute(:next_attempt_at, nil))
    end

    update :acknowledge_in_tx do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(status != :delivered)))
      change(transition_state(:delivered))
      change(set_attribute(:delivered_at, arg(:at)))
      change(set_attribute(:next_attempt_at, nil))
      change(set_attribute(:last_error, nil))
      change(set_attribute(:updated_at, arg(:at)))
    end

    update :reschedule_in_tx do
      require_atomic?(true)
      accept([:next_attempt_at, :last_error])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(status != :delivered)))
      change(transition_state(:pending))
      change(set_attribute(:updated_at, arg(:at)))
    end

    action :retry, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, :term)

      run(__MODULE__.Actions)
    end

    action :claim, :term do
      argument(:id, :term)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
