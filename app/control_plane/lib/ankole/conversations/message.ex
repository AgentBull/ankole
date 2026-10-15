defmodule Ankole.Conversations.Message do
  @moduledoc "A committed statement. External observations follow provider edits and removals."
  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true
  import Ecto.Changeset

  @primary_key {:id, Ankole.Ecto.UUIDv7, []}
  @type t :: %__MODULE__{}

  schema "conversation_messages" do
    field :conversation_id, Ankole.Ecto.UUIDv7
    field :seq, :integer
    field :author_type, Ecto.Enum, values: [:human, :agent, :unknown]
    field :author_uid, Ankole.Ecto.PrincipalKey
    field :kind, Ecto.Enum, values: [:message, :notice], default: :message
    field :text, :string
    field :attachments, {:array, :map}, default: []
    field :links, {:array, :map}, default: []
    field :mentions, {:array, :map}, default: []
    field :rich_content, :map
    field :reply_to_message_id, Ankole.Ecto.UUIDv7
    field :origin, Ecto.Enum, values: [:native, :external], default: :native
    field :session_id, :string
    field :signal_id, Ankole.Ecto.UUIDv7
    field :created_at, :utc_datetime_usec
  end

  def changeset(message, attrs) do
    message
    |> cast(
      attrs,
      [
        :id,
        :conversation_id,
        :seq,
        :author_type,
        :author_uid,
        :kind,
        :text,
        :attachments,
        :links,
        :mentions,
        :rich_content,
        :reply_to_message_id,
        :origin,
        :session_id,
        :signal_id,
        :created_at
      ],
      empty_values: []
    )
    |> validate_required([
      :id,
      :conversation_id,
      :seq,
      :author_type,
      :kind,
      :attachments,
      :origin,
      :created_at
    ])
    |> validate_native_statement()
    |> Ankole.Ecto.JSONPayload.validate_list(:attachments, allow_datetime: true)
    |> Ankole.Ecto.JSONPayload.validate_list(:links, allow_datetime: true)
    |> Ankole.Ecto.JSONPayload.validate_list(:mentions, allow_datetime: true)
    |> validate_number(:seq, greater_than: 0)
    |> unique_constraint([:tenant_id, :id], name: :conversation_messages_pkey)
    |> unique_constraint([:tenant_id, :conversation_id, :seq],
      name: :conversation_messages_sequence_index
    )
    |> unique_constraint([:tenant_id, :conversation_id, :signal_id],
      name: :conversation_messages_signal_index
    )
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:author_uid)
    |> foreign_key_constraint(:signal_id)
    |> foreign_key_constraint(:reply_to_message_id)
    |> check_constraint(:text, name: :conversation_messages_text_present)
    |> check_constraint(:author_type, name: :conversation_messages_author_type_check)
    |> check_constraint(:kind, name: :conversation_messages_kind_check)
    |> check_constraint(:origin, name: :conversation_messages_origin_check)
    |> check_constraint(:signal_id, name: :conversation_messages_provenance_check)
  end

  defp validate_native_statement(changeset) do
    if get_field(changeset, :origin) == :native do
      validate_required(changeset, [:author_uid, :text])
    else
      changeset
    end
  end
end
