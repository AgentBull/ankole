defmodule Ankole.Conversations.Message do
  @moduledoc "A committed statement. External observations follow provider edits and removals."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  @type t :: %__MODULE__{}

  postgres do
    table("conversation_messages")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:tenant_id, :id], "conversation_messages_pkey"},
      {[:tenant_id, :conversation_id, :seq], "conversation_messages_sequence_index"},
      {[:tenant_id, :conversation_id, :signal_id, :delivery_key],
       "conversation_messages_signal_index"}
    ])

    foreign_key_names([
      {:conversation_id, "conversation_messages_conversation_id_fkey"},
      {:author_uid, "conversation_messages_author_uid_fkey"},
      {:signal_id, "conversation_messages_signal_id_fkey"},
      {:reply_to_message_id, "conversation_messages_reply_to_message_id_fkey"}
    ])

    check_constraints do
      check_constraint(:text, "conversation_messages_text_present")
      check_constraint(:author_type, "conversation_messages_author_type_check")
      check_constraint(:kind, "conversation_messages_kind_check")
      check_constraint(:origin, "conversation_messages_origin_check")
      check_constraint(:signal_id, "conversation_messages_provenance_check")
      check_constraint(:seq, "conversation_messages_sequence_positive")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false, public?: true)
    attribute(:seq, :integer, allow_nil?: false, constraints: [min: 1], public?: true)

    attribute(:author_type, :atom,
      constraints: [one_of: [:human, :agent, :unknown]],
      allow_nil?: false,
      public?: true
    )

    attribute(:author_display_name, :string,
      constraints: [trim?: false, match: ~r/\S/u],
      public?: true
    )

    attribute(:delivery_key, :string,
      default: "final",
      allow_nil?: false,
      constraints: [match: ~r/\S/u],
      public?: true
    )

    attribute(:author_uid, Ankole.Ash.Types.PrincipalKey, public?: true)

    attribute(:kind, :atom,
      constraints: [one_of: [:message, :notice]],
      default: :message,
      allow_nil?: false,
      public?: true
    )

    attribute(:text, :string, constraints: [trim?: false, allow_empty?: true], public?: true)

    attribute(:links, {:array, Ankole.Ash.Types.JSONMap},
      default: [],
      allow_nil?: false,
      constraints: [items: [allow_datetime?: true]],
      public?: true
    )

    attribute(:mentions, {:array, Ankole.Ash.Types.JSONMap},
      default: [],
      allow_nil?: false,
      constraints: [items: [allow_datetime?: true]],
      public?: true
    )

    attribute(:rich_content, Ankole.Ash.Types.JSONMap, public?: true)
    attribute(:reply_to_message_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:origin, :atom,
      constraints: [one_of: [:native, :external]],
      default: :native,
      allow_nil?: false,
      public?: true
    )

    attribute(:session_id, :string,
      constraints: [trim?: false, allow_empty?: true],
      public?: true
    )

    attribute(:signal_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end

  validations do
    validate(present(:author_display_name), where: [attribute_equals(:origin, :native)])

    validate(present(:text),
      where: [attribute_equals(:origin, :native), argument_equals(:attachments, [])]
    )

    validate(match(:text, ~r/\S/u),
      where: [attribute_equals(:origin, :native), argument_equals(:attachments, [])]
    )
  end

  calculations do
    calculate(
      :attachments,
      {:array, Ankole.Ash.Types.JSONMap},
      Ankole.Conversations.AttachmentReferences.Projection,
      constraints: [items: [allow_datetime?: true]],
      public?: true
    )

    # A Message is withdrawn when all its Agent inputs are removed.
    calculate(
      :withdrawn,
      :boolean,
      expr(
        exists(
          Ankole.Signals.Signal,
          message_id == parent(id) and fragment("? @> '{\"removed\": true}'::jsonb", data)
        ) and
          not exists(
            Ankole.Signals.Signal,
            message_id == parent(id) and not fragment("? @> '{\"removed\": true}'::jsonb", data)
          )
      )
    )
  end

  relationships do
    has_many :attachment_rows, Ankole.Conversations.MessageAttachment do
      source_attribute(:id)
      destination_attribute(:message_id)
    end
  end

  preparations do
    prepare({Ankole.Conversations.AttachmentReferences.Preparation, owner: :message})
  end

  changes do
    change({Ankole.Conversations.AttachmentReferences.Change, owner: :message},
      on: [:create, :update]
    )
  end

  actions do
    defaults([:read])

    read :history_page do
      pagination(keyset?: true, max_page_size: 500, countable: false, required?: false)
    end

    create :record do
      argument(:attachments, {:array, Ankole.Ash.Types.JSONMap},
        default: [],
        allow_nil?: false,
        constraints: [items: [allow_datetime?: true]]
      )

      change(Ankole.Conversations.Message.SnapshotAuthor)
      validate(present(:author_uid), where: [attribute_equals(:origin, :native)])

      validate(present(:signal_id),
        where: [attribute_equals(:origin, :native), attribute_equals(:author_type, :agent)]
      )

      accept([
        :id,
        :conversation_id,
        :seq,
        :author_type,
        :author_uid,
        :author_display_name,
        :delivery_key,
        :kind,
        :text,
        :links,
        :mentions,
        :rich_content,
        :reply_to_message_id,
        :origin,
        :session_id,
        :signal_id,
        :created_at
      ])
    end

    create_if_absent :record_once do
      argument(:attachments, {:array, Ankole.Ash.Types.JSONMap},
        default: [],
        allow_nil?: false,
        constraints: [items: [allow_datetime?: true]]
      )

      change(Ankole.Conversations.Message.SnapshotAuthor)
      validate(present(:author_uid), where: [attribute_equals(:origin, :native)])

      validate(present(:signal_id),
        where: [attribute_equals(:origin, :native), attribute_equals(:author_type, :agent)]
      )

      accept([
        :id,
        :conversation_id,
        :seq,
        :author_type,
        :author_uid,
        :author_display_name,
        :delivery_key,
        :kind,
        :text,
        :links,
        :mentions,
        :rich_content,
        :reply_to_message_id,
        :origin,
        :session_id,
        :signal_id,
        :created_at
      ])
    end

    update :edit do
      accept([:text, :links, :mentions])
      validate(attribute_equals(:origin, :native))
    end

    update :observe do
      argument(:attachments, {:array, Ankole.Ash.Types.JSONMap},
        constraints: [items: [allow_datetime?: true]]
      )

      accept([
        :author_type,
        :author_uid,
        :author_display_name,
        :delivery_key,
        :kind,
        :text,
        :links,
        :mentions,
        :rich_content,
        :reply_to_message_id,
        :session_id,
        :signal_id
      ])

      validate(attribute_equals(:origin, :external))
    end

    update :resolve_attachments do
      argument(:attachments, {:array, Ankole.Ash.Types.JSONMap},
        allow_nil?: false,
        constraints: [items: [allow_datetime?: true]]
      )

      accept([])
    end

    destroy :remove do
      require_atomic?(true)
    end
  end
end
