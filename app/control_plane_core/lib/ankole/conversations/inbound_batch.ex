defmodule Ankole.Conversations.InboundBatch do
  @moduledoc """
  Short-lived IM ingress grouping state before Signal creation.

  A row here is not actor work yet. It holds provider messages for one
  agent/binding/channel/thread until Conversations.Observe can decide whether they
  close as addressed input, ambient observation, or no Signal. Every row
  has one nullable direct reply target so unrelated references never merge.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Conversations.Domain,
    extensions: [AshStateMachine]

  postgres do
    table("conversation_inbound_batches")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "conversation_inbound_batches_agent_uid_fkey"},
      {:conversation_id, "conversation_inbound_batches_conversation_id_fkey"}
    ])

    unique_index_names([
      {[:agent_uid, :binding_name, :conversation_id, :provider_thread_id],
       "conversation_inbound_batches_open_index"}
    ])

    check_constraints do
      check_constraint(:entries, "inbound_batches_entries_array")
      check_constraint(:batch_state, "inbound_batches_state_check")
      check_constraint(:mode, "inbound_batches_mode_check")
      check_constraint(:policy, "inbound_batches_policy_check")
      check_constraint(:batch_revision, "inbound_batches_revision_non_negative")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)
    attribute(:binding_name, :string, allow_nil?: false, public?: true)
    attribute(:session_id, :string, allow_nil?: false, public?: true)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false, public?: true)

    attribute(:provider_thread_id, :string,
      default: "",
      allow_nil?: false,
      constraints: [allow_empty?: true],
      public?: true
    )

    attribute(:reply_to_provider_message_id, :string, public?: true)

    attribute(:batch_state, :atom,
      default: :open,
      allow_nil?: false,
      constraints: [one_of: [:open, :finalized, :canceled]]
    )

    attribute(:mode, :atom,
      default: :neutral,
      allow_nil?: false,
      constraints: [one_of: [:neutral, :addressed]],
      public?: true
    )

    attribute(:policy, :atom,
      allow_nil?: false,
      constraints: [one_of: [:ignore, :record_only, :may_intervene]],
      public?: true
    )

    attribute(:requester_sender_key, :string, public?: true)
    attribute(:entries, Ankole.Ash.Types.JSONValue, default: [], allow_nil?: false, public?: true)
    attribute(:available_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:batch_revision, :integer, default: 0, allow_nil?: false, constraints: [min: 0])
    timestamps(type: :utc_datetime_usec)
  end

  validations do
    validate(fn changeset, _context ->
      if is_list(Ash.Changeset.get_attribute(changeset, :entries)),
        do: :ok,
        else: {:error, field: :entries, message: "must be a JSON array"}
    end)
  end

  changes do
    change(filter(expr(batch_state == :open)), on: [:update])
  end

  state_machine do
    state_attribute(:batch_state)
    initial_states([:open])
    default_initial_state(:open)

    transitions do
      transition(:finalize, from: :open, to: :finalized)
      transition(:cancel, from: :open, to: :canceled)
    end
  end

  actions do
    defaults([:read])

    create :open do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

      accept([
        :agent_uid,
        :binding_name,
        :session_id,
        :conversation_id,
        :provider_thread_id,
        :reply_to_provider_message_id,
        :mode,
        :policy,
        :requester_sender_key,
        :entries,
        :available_at
      ])
    end

    in_tx_update :replace_prefix do
      accept([:entries])
      validate(attribute_equals(:batch_state, :open))
    end

    in_tx_update :revise do
      accept([
        :entries,
        :mode,
        :policy,
        :reply_to_provider_message_id,
        :requester_sender_key,
        :available_at
      ])

      validate(attribute_equals(:batch_state, :open))
      change(atomic_update(:batch_revision, expr(batch_revision + 1)))
    end

    in_tx_update :finalize do
      accept([])
      change(transition_state(:finalized))
      change(atomic_update(:batch_revision, expr(batch_revision + 1)))
    end

    in_tx_update :cancel do
      accept([:entries])
      change(transition_state(:canceled))
      change(atomic_update(:batch_revision, expr(batch_revision + 1)))
    end
  end
end
