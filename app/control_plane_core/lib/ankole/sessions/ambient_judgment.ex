defmodule Ankole.Sessions.AmbientJudgment do
  @moduledoc """
  Stores the canonical ambient route and this Agent's conversation progress.

  A retry returns the same decision. Removal of an accepted message anchor
  degrades its attribution but preserves the decision and progress.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Sessions.Domain

  postgres do
    table("session_ambient_judgments")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:signal_id, "session_ambient_judgments_signal_id_fkey"},
      {:agent_uid, "session_ambient_judgments_agent_uid_fkey"}
    ])

    check_constraints do
      check_constraint(:asked_by_state, "session_ambient_judgments_asked_by_state_check")
      check_constraint(:asked_by_state, "session_ambient_judgments_asked_by_shape_check")
      check_constraint(:action, "session_ambient_judgments_action_contract_check")
    end
  end

  attributes do
    attribute(:signal_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:action, :string, allow_nil?: false)
    attribute(:authority, :string, allow_nil?: false)
    attribute(:handoff_job_id, :integer, constraints: [min: 1])

    attribute(:reason, :string,
      default: "",
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:asked_by_message_id, Ankole.Ash.Types.UUIDv7)
    attribute(:asked_by_state, :string)
    attribute(:judged_until, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :record do
      primary?(true)
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

      accept([
        :signal_id,
        :agent_uid,
        :conversation_id,
        :action,
        :authority,
        :handoff_job_id,
        :reason,
        :asked_by_message_id,
        :asked_by_state,
        :judged_until
      ])

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :reason,
          String.slice(Ash.Changeset.get_attribute(changeset, :reason) || "", 0, 2_000)
        )
      end)

      validate(attribute_in(:action, ~w(NOOP FOREGROUND_REPLY NEW_WORK HANDOFF)))
      validate(attribute_in(:authority, ~w(NONE EXPLICIT_REQUEST STANDING_ORDER)))
      validate(attribute_in(:asked_by_state, [nil, "accepted", "degraded"]))

      validate(attribute_equals(:authority, "NONE"),
        where: [attribute_does_not_equal(:action, "NEW_WORK")]
      )

      validate(present(:handoff_job_id), where: [attribute_equals(:action, "HANDOFF")])
      validate(absent(:handoff_job_id), where: [attribute_does_not_equal(:action, "HANDOFF")])

      validate(present(:asked_by_message_id),
        where: [attribute_equals(:asked_by_state, "accepted")]
      )

      validate(absent(:asked_by_message_id),
        where: [attribute_does_not_equal(:asked_by_state, "accepted")]
      )
    end

    atomic_in_tx_update :degrade_anchor do
      accept([])
      change(set_attribute(:asked_by_state, "degraded"))
      change(set_attribute(:asked_by_message_id, nil))
    end
  end
end
