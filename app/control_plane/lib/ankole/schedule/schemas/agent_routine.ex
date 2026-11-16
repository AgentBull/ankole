defmodule Ankole.Schedule.Schemas.AgentRoutine do
  @moduledoc """
  Durable consumer definition for an AI colleague's standing Routine.

  `owner_session_id` records the management scope where the Routine was created.
  Every timer fire, external event batch, and checkback wakeup belonging to the
  Routine executes in the serialized session `routine:<id>`.
  """

  use Ankole.Ash.Resource,
    extensions: [AshStateMachine],
    tenancy: :tenant,
    domain: Ankole.Schedule

  use Ankole.Work.Provenance,
    owner_session?: true,
    agent_required?: true,
    kind: "routine",
    cleanup_key: "routine",
    review_states: [:active, :paused],
    reauthorizable_states: [:active, :paused],
    revoke_action: {Ankole.Schedule.Routines, :stop_human_work_in_tx}

  @type t :: %__MODULE__{}

  postgres do
    table("agent_routines")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "agent_routines_agent_uid_fkey"}
    ])

    check_constraints do
      check_constraint(:status, "agent_routines_status_check")
      check_constraint(:name, "agent_routines_name_present")
      check_constraint(:task, "agent_routines_task_present")
      check_constraint(:owner_session_id, "agent_routines_owner_session_present")
      check_constraint(:idempotency_key, "agent_routines_idempotency_key_present")
      check_constraint(:definition_version, "agent_routines_definition_version_positive")
      check_constraint(:delivery, "agent_routines_delivery_object")
      check_constraint(:created_by, "agent_routines_created_by_object")
      check_constraint(:authorization_kind, "agent_routines_work_authorization_check")
    end

    identity_index_names(idempotency: "agent_routines_idempotency_index")

    unique_index_names([
      {[:agent_uid, :owner_session_id, :name], "agent_routines_agent_name_index"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0,
      public?: true
    )

    ash_attributes()
    attribute(:binding_name, :string, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:task, :string, allow_nil?: false, public?: true)
    attribute(:delivery, Ankole.Ash.Types.JSONMap, default: %{}, allow_nil?: false, public?: true)
    attribute(:definition_version, :integer, default: 1, allow_nil?: false, public?: true)
    attribute(:idempotency_key, :string, allow_nil?: false, public?: true)

    attribute(:created_by, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true
    )

    timestamps(type: :utc_datetime_usec, public?: true)
  end

  identities do
    identity(:idempotency, [:agent_uid, :owner_session_id, :idempotency_key])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:active, :paused])
    default_initial_state(:active)

    transitions do
      transition(:pause, from: :active, to: :paused)
      transition(:resume, from: :paused, to: :active)
      transition(:reactivate, from: :completed, to: :active)
      transition(:delete, from: [:active, :paused, :completed], to: :deleted)
      transition(:complete, from: [:active, :paused], to: :completed)
      transition(:stop_human_work, from: :active, to: :paused)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      upsert?(true)
      upsert_identity(:idempotency)
      upsert_fields([:idempotency_key])

      accept([
        :id,
        :authorization_kind,
        :human_uid,
        :human_access_version,
        :status,
        :agent_uid,
        :owner_session_id,
        :binding_name,
        :name,
        :task,
        :delivery,
        :definition_version,
        :idempotency_key,
        :created_by
      ])
    end

    destroy :remove do
      primary?(true)
    end

    update :update_definition do
      accept([
        :binding_name,
        :name,
        :task,
        :delivery
      ])

      change(fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :task) or
             Ash.Changeset.changing_attribute?(changeset, :delivery) do
          current = changeset.data.definition_version || 1
          Ash.Changeset.force_change_attribute(changeset, :definition_version, current + 1)
        else
          changeset
        end
      end)
    end

    update :pause do
      accept([])
      change(transition_state(:paused))
    end

    update :resume do
      accept([])
      change(transition_state(:active))
    end

    update :reactivate do
      accept([])
      change(transition_state(:active))
    end

    update :delete do
      accept([])
      change(transition_state(:deleted))
    end

    update :complete do
      accept([])
      change(transition_state(:completed))
    end

    update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])

      change(fn changeset, _context ->
        current = changeset.data.definition_version || 1
        Ash.Changeset.force_change_attribute(changeset, :definition_version, current + 1)
      end)
    end

    update :stop_human_work do
      require_atomic?(true)
      accept([])
      change(transition_state(:paused))
    end
  end
end
