defmodule Ankole.Conversations.ExternalMessageRef do
  @moduledoc "Adapter-owned platform identity and observations for one public Message."
  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true
  import Ecto.Changeset
  alias Ankole.Ecto.JSONPayload

  @primary_key false
  @type t :: %__MODULE__{}

  schema "external_message_refs" do
    field :message_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :conversation_id, Ankole.Ecto.UUIDv7
    field :provider_message_id, :string
    field :reply_to_provider_message_id, :string
    field :provider_thread_id, :string
    field :author, :map, default: %{}
    field :metadata, :map, default: %{}
    field :raw_payload, :map, default: %{}
    field :provider_time, :utc_datetime_usec
    field :reactions, :map, default: %{}
    field :raw_reaction_keys, :map, default: %{}
    field :content_hash, :string
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :ai_message_id, Ecto.UUID
  end

  def changeset(ref, attrs) do
    ref
    |> cast(attrs, [
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
    |> validate_required([
      :message_id,
      :conversation_id,
      :provider_message_id,
      :author,
      :metadata,
      :raw_payload,
      :reactions,
      :raw_reaction_keys,
      :first_seen_at,
      :last_seen_at
    ])
    |> JSONPayload.validate_map(:author, allow_datetime: true)
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> JSONPayload.validate_map(:raw_payload, allow_datetime: true)
    |> JSONPayload.validate_map(:reactions)
    |> JSONPayload.validate_map(:raw_reaction_keys)
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:tenant_id, :message_id], name: :external_message_refs_pkey)
    |> unique_constraint([:tenant_id, :conversation_id, :provider_message_id],
      name: :external_message_refs_provider_identity_index
    )
  end
end
