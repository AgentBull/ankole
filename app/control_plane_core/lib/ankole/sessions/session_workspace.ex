defmodule Ankole.Sessions.SessionWorkspace do
  @moduledoc """
  Owns the typed Session identity and its stable Agent Home workspace.

  PostgreSQL derives the transport key from the typed owner. The numeric ID
  remains the directory name under the Agent's `sessions` tree.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Sessions,
    fragments: [Ankole.Sessions.Operations]

  @type t :: %__MODULE__{}

  postgres do
    table("sessions")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "sessions_agent_uid_fkey"},
      {:conversation_id, "sessions_conversation_id_fkey"},
      {:background_job_id, "sessions_background_job_owner_fkey"},
      {:workflow_agent_call_id, "sessions_workflow_call_owner_fkey"},
      {:cron_schedule_id, "sessions_cron_schedule_owner_fkey"}
    ])

    unique_index_names([{[:agent_uid, :session_id], "sessions_session_index"}])

    check_constraints do
      check_constraint(:id, "sessions_id_range")
      check_constraint(:kind, "sessions_owner_check")
      check_constraint(:session_id, "sessions_session_id_present")
      check_constraint(:epoch, "sessions_epoch_non_negative")
    end
  end

  attributes do
    attribute(:id, :integer, primary_key?: true, generated?: true, allow_nil?: false)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:session_id, :string, generated?: true, writable?: false, allow_nil?: false)

    attribute(:kind, :atom,
      constraints: [one_of: [:named, :conversation, :background_job, :workflow_task, :cron]],
      allow_nil?: false
    )

    attribute(:name, :string, constraints: [trim?: false])
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7)
    attribute(:background_job_id, :integer)
    attribute(:workflow_agent_call_id, :integer)
    attribute(:cron_schedule_id, Ankole.Ash.Types.UUIDv7)
    attribute(:epoch, :integer, allow_nil?: false, default: 0, writable?: false)
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    # The public conversation that a conversation Session serves.
    has_one :conversation, Ankole.Conversations.Conversation do
      source_attribute(:conversation_id)
      destination_attribute(:id)
      public?(false)
    end
  end

  actions do
    defaults([:read])

    create :allocate do
      primary?(true)

      accept([
        :agent_uid,
        :kind,
        :name,
        :conversation_id,
        :background_job_id,
        :workflow_agent_call_id,
        :cron_schedule_id
      ])
    end

    update :advance_epoch do
      require_atomic?(true)
      accept([])
      change(atomic_update(:epoch, expr(epoch + 1)))
    end
  end
end
