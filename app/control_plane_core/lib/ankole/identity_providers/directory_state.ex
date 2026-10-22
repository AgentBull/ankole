defmodule Ankole.IdentityProviders.DirectoryState do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.IdentityProviders.Domain,
    extensions: [AshStateMachine]

  @states [:unverified, :syncing, :healthy, :review_required, :failed]
  @snapshot_fields [
    :scope_fingerprint,
    :snapshot_fingerprint,
    :member_uids,
    :missing_uids,
    :last_success_at,
    :last_error
  ]

  postgres do
    table("identity_directory_states")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(provider: "identity_directory_states_provider_id_index")

    check_constraints do
      check_constraint(:status, "identity_directory_states_status")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:provider_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:revision, :integer,
      public?: true,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:scope_fingerprint, :string, public?: true, constraints: [trim?: false])
    attribute(:snapshot_fingerprint, :string, public?: true, constraints: [trim?: false])
    attribute(:approved_scope_fingerprint, :string, public?: true, constraints: [trim?: false])

    attribute(:member_uids, {:array, Ankole.Ash.Types.PrincipalKey},
      public?: true,
      allow_nil?: false,
      default: []
    )

    attribute(:missing_uids, {:array, Ankole.Ash.Types.PrincipalKey},
      public?: true,
      allow_nil?: false,
      default: []
    )

    attribute(:last_started_at, :utc_datetime_usec, public?: true)
    attribute(:last_success_at, :utc_datetime_usec, public?: true)
    attribute(:last_error, :string, public?: true, constraints: [trim?: false])
    attribute(:reviewed_by, Ankole.Ash.Types.ActorRef, public?: true)
    attribute(:reviewed_at, :utc_datetime_usec, public?: true)
    attribute(:review_reason, :string, public?: true, constraints: [trim?: false])
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:provider, [:provider_id])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:unverified])
    default_initial_state(:unverified)

    transitions do
      transition(:configuration_changed_in_tx, from: @states, to: :review_required)
      transition(:begin_sync_in_tx, from: @states, to: :syncing)
      transition(:complete_sync_in_tx, from: [:syncing], to: :healthy)
      transition(:review_snapshot_in_tx, from: [:syncing], to: :review_required)
      transition(:fail_sync_in_tx, from: [:syncing], to: :failed)
      transition(:approve_snapshot_in_tx, from: [:review_required], to: :healthy)
    end
  end

  actions do
    defaults([:read])

    create_if_absent :ensure_in_tx, upsert_fields: [:provider_id] do
      accept([:provider_id])
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      upsert_identity(:provider)
    end

    atomic_in_tx_update :configuration_changed_in_tx do
      accept([])
      change(atomic_update(:revision, expr(revision + 1)))
      change(transition_state(:review_required))
      change(set_attribute(:approved_scope_fingerprint, nil))
      change(set_attribute(:snapshot_fingerprint, nil))

      change(
        set_attribute(
          :last_error,
          "Provider configuration changed; run and review a new directory sync"
        )
      )
    end

    in_tx_update :receive_event_in_tx do
      accept([:approved_scope_fingerprint])
      change(atomic_update(:revision, expr(revision + 1)))
    end

    in_tx_update :begin_sync_in_tx do
      accept([])
      change(atomic_update(:revision, expr(revision + 1)))
      change(set_attribute(:last_started_at, &DateTime.utc_now/0))
      change(set_attribute(:last_error, nil))
      change(transition_state(:syncing))
    end

    in_tx_update :complete_sync_in_tx do
      accept(@snapshot_fields)
      change(transition_state(:healthy))
    end

    in_tx_update :review_snapshot_in_tx do
      accept(@snapshot_fields)
      change(transition_state(:review_required))
    end

    atomic_in_tx_update :fail_sync_in_tx do
      accept([:last_error])
      change(transition_state(:failed))
    end

    in_tx_update :approve_snapshot_in_tx do
      accept([:approved_scope_fingerprint, :reviewed_by, :review_reason])
      validate(present(:review_reason))
      validate(match(:review_reason, ~r/\S/))
      change(set_attribute(:reviewed_at, &DateTime.utc_now/0))
      change(set_attribute(:missing_uids, []))
      change(set_attribute(:last_error, nil))
      change(transition_state(:healthy))
    end
  end

  @type t :: %__MODULE__{}
end
