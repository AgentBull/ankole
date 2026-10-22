defmodule Ankole.IdentityProviders.DirectoryEvent do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.IdentityProviders,
    extensions: [AshStateMachine]

  postgres do
    table("identity_directory_events")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(provider_event: "identity_directory_events_provider_id_event_id_index")

    check_constraints do
      check_constraint(:status, "identity_directory_events_status")
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

    attribute(:event_id, :string, public?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:event_type, :string, public?: true, allow_nil?: false, constraints: [trim?: false])

    attribute(:external_ids, {:array, :string},
      public?: true,
      allow_nil?: false,
      default: [],
      constraints: [items: [trim?: false]]
    )

    attribute(:reason, :string, public?: true, constraints: [trim?: false])
    attribute(:provider_time, :utc_datetime_usec, public?: true)
    attribute(:last_error, :string, public?: true, constraints: [trim?: false])
    attribute(:processed_at, :utc_datetime_usec, public?: true)
    attribute(:reviewed_by, Ankole.Ash.Types.ActorRef, public?: true)
    attribute(:review_reason, :string, public?: true, constraints: [trim?: false])
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:provider_event, [:provider_id, :event_id])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:pending])
    default_initial_state(:pending)

    transitions do
      transition(:process_in_tx, from: [:pending, :review_required], to: :processed)
      transition(:require_review_in_tx, from: [:pending, :review_required], to: :review_required)

      transition(:dismiss_in_tx,
        from: [:pending, :review_required, :processed, :dismissed],
        to: :dismissed
      )
    end
  end

  actions do
    defaults([:read])

    create :receive_in_tx do
      accept([:provider_id, :event_id, :event_type, :external_ids, :reason, :provider_time])
    end

    update :process_in_tx do
      accept([])
      change(transition_state(:processed))
      change(set_attribute(:processed_at, &DateTime.utc_now/0))
      change(set_attribute(:last_error, nil))
    end

    update :fail_in_tx do
      accept([:last_error])
      validate(attribute_in(:status, [:pending, :review_required]))
    end

    update :require_review_in_tx do
      accept([:last_error])
      change(transition_state(:review_required))
    end

    update :review_in_tx do
      accept([:reviewed_by, :review_reason])
      validate(present(:review_reason))
      validate(match(:review_reason, ~r/\S/))
    end

    update :dismiss_in_tx do
      accept([:reviewed_by, :review_reason])
      validate(present(:review_reason))
      validate(match(:review_reason, ~r/\S/))
      change(transition_state(:dismissed))
      change(set_attribute(:processed_at, &DateTime.utc_now/0))
    end

    action :receive, :struct do
      constraints(instance_of: __MODULE__)
      argument(:provider_id, :term, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.IdentityProviders.DirectoryAccess.receive_event_in_tx(
          Ankole.Repo,
          input.arguments.provider_id,
          input.arguments.attrs
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :apply_restriction, :struct do
      constraints(instance_of: __MODULE__)
      argument(:event, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])

      run(fn input, _context ->
        Ankole.IdentityProviders.DirectoryAccess.apply_restriction_in_tx(
          Ankole.Repo,
          input.arguments.event
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :update_open, :struct do
      constraints(instance_of: __MODULE__)
      argument(:event, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])
      argument(:action, :atom, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)
      argument(:only_open?, :boolean, allow_nil?: false)

      run(fn input, _context ->
        Ankole.IdentityProviders.DirectoryAccess.update_open_event_in_tx(
          input.arguments.event,
          input.arguments.action,
          input.arguments.attrs,
          input.arguments.only_open?
        )
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
end
