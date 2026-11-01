defmodule Ankole.Conversations.ActionCard do
  @moduledoc """
  Durable privilege-escalated action card drafted by an Agent and confirmed or
  cancelled by an authorized human Principal.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  @action_kinds ~w(
    pod.page.set_sharing
    pod.page.delete
    pod.page.restore
    pod.base.delete_table
    conversation.add_participants
  )

  @statuses [:prepared, :executed, :stale, :cancelled]

  def action_kinds, do: @action_kinds
  def statuses, do: @statuses

  postgres do
    table("conversation_action_cards")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:conversation_id, "conversation_action_cards_conversation_fkey"},
      {:source_signal_id, "conversation_action_cards_signal_fkey"}
    ])

    identity_index_names(signal_interaction: "conversation_action_cards_signal_interaction_index")

    unique_index_names([{[:tenant_id, :id], "conversation_action_cards_pkey"}])

    check_constraints do
      check_constraint(:status, "conversation_action_cards_status_check")
      check_constraint(:action_kind, "conversation_action_cards_action_kind_check")
      check_constraint(:summary, "conversation_action_cards_summary_check")
      check_constraint(:resolved_at, "conversation_action_cards_resolution_shape")
      check_constraint(:notified_senders, "conversation_action_cards_notified_senders_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0,
      public?: true
    )

    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false, public?: true)
    attribute(:session_id, :string, allow_nil?: false, constraints: [trim?: false], public?: true)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)
    attribute(:source_signal_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false, public?: true)

    attribute(:interaction_id, :string,
      allow_nil?: false,
      constraints: [trim?: false],
      public?: true
    )

    attribute(:action_kind, :string,
      allow_nil?: false,
      constraints: [trim?: false],
      public?: true
    )

    attribute(:summary, :string,
      allow_nil?: false,
      constraints: [trim?: false, min_length: 1, max_length: 500],
      public?: true
    )

    attribute(:target_node_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:payload, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    attribute(:preconditions, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    attribute(:status, :atom,
      allow_nil?: false,
      default: :prepared,
      constraints: [one_of: @statuses],
      public?: true
    )

    attribute(:resolved_by_uid, Ankole.Ash.Types.PrincipalKey, public?: true)
    attribute(:resolved_by_name, :string, constraints: [trim?: false], public?: true)
    attribute(:resolved_at, :utc_datetime_usec, public?: true)
    attribute(:resolution_note, :string, constraints: [trim?: false], public?: true)

    attribute(:notified_senders, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true
    )

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:signal_interaction, [:source_signal_id, :interaction_id])
  end

  validations do
    validate(one_of(:action_kind, @action_kinds))
  end

  actions do
    defaults([:read])

    create :prepare_in_tx do
      primary?(true)
      upsert?(true)
      upsert_identity(:signal_interaction)
      upsert_fields([])

      accept([
        :id,
        :conversation_id,
        :session_id,
        :agent_uid,
        :source_signal_id,
        :interaction_id,
        :action_kind,
        :summary,
        :target_node_id,
        :payload,
        :preconditions
      ])
    end

    update :resolve_in_tx do
      require_atomic?(false)

      accept([
        :status,
        :resolved_by_uid,
        :resolved_by_name,
        :resolved_at,
        :resolution_note,
        :notified_senders
      ])
    end

    update :record_notified_senders_in_tx do
      require_atomic?(false)
      accept([:notified_senders])
    end
  end

  @type t :: %__MODULE__{}
end
