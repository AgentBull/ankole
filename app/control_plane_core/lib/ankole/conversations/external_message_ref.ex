defmodule Ankole.Conversations.ExternalMessageRef do
  @moduledoc "Adapter-owned platform identity and observations for one public Message."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Conversations

  @type t :: %__MODULE__{}

  postgres do
    table("external_message_refs")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:message_id, "external_message_refs_message_id_fkey"},
      {:conversation_id, "external_message_refs_conversation_id_fkey"}
    ])

    unique_index_names([
      {[:tenant_id, :message_id], "external_message_refs_pkey"},
      {[:tenant_id, :conversation_id, :provider_message_id],
       "external_message_refs_provider_identity_index"}
    ])

    check_constraints do
      check_constraint(:provider_message_id, "external_message_refs_provider_message_id_check")
      check_constraint(:metadata, "external_message_refs_objects_check")
    end
  end

  attributes do
    attribute(:message_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false, public?: true)

    attribute(:provider_message_id, :string,
      constraints: [trim?: false, match: ~r/\S/u],
      allow_nil?: false,
      public?: true
    )

    attribute(:reply_to_provider_message_id, :string, constraints: [trim?: false], public?: true)
    attribute(:provider_thread_id, :string, constraints: [trim?: false], public?: true)

    attribute(:author, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      constraints: [allow_datetime?: true],
      public?: true
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      constraints: [allow_datetime?: true],
      public?: true
    )

    attribute(:raw_payload, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      constraints: [allow_datetime?: true],
      public?: true
    )

    attribute(:provider_time, :utc_datetime_usec, public?: true)

    attribute(:reactions, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true
    )

    attribute(:raw_reaction_keys, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true
    )

    attribute(:content_hash, :string, constraints: [trim?: false], public?: true)
    attribute(:first_seen_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:last_seen_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:ai_message_id, :uuid, public?: true)
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :message_id,
        :conversation_id,
        :provider_message_id,
        :reply_to_provider_message_id,
        :provider_thread_id,
        :author,
        :metadata,
        :raw_payload,
        :provider_time,
        :reactions,
        :raw_reaction_keys,
        :content_hash,
        :first_seen_at,
        :last_seen_at,
        :ai_message_id
      ])
    end

    update :observe do
      accept([
        :reply_to_provider_message_id,
        :provider_thread_id,
        :author,
        :metadata,
        :raw_payload,
        :provider_time,
        :content_hash,
        :last_seen_at,
        :ai_message_id
      ])
    end

    update :fold_reaction do
      accept([:reactions, :raw_reaction_keys, :last_seen_at])
    end
  end
end
