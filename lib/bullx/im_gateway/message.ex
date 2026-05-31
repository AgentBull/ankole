defmodule BullX.IMGateway.Message do
  @moduledoc """
  Canonical inbound IM message fact owned by `BullX.IMGateway`.

  This schema records what the external provider said happened in a room,
  including lifecycle state and provider timestamps. MailBox entries and Agent
  transcript messages are downstream projections; they should reference this
  provider fact rather than re-owning the external message.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.IMGateway.Room

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @lifecycle_states [:active, :edited, :recalled, :deleted]

  @type t :: %__MODULE__{}

  schema "im_messages" do
    belongs_to :room, Room

    field :lifecycle_state, Ecto.Enum, values: @lifecycle_states, default: :active
    field :provider_message_id, :string
    field :actor_kind, :string, default: "unknown"
    field :actor_provider_id, :string
    field :actor, :map, default: %{}
    field :message_kind, :string
    field :text, :string
    field :content, BullX.Ecto.JSONB, default: %{}
    field :attachments, BullX.Ecto.JSONB, default: []
    field :mentions, BullX.Ecto.JSONB, default: []
    field :provider_created_at, :utc_datetime_usec
    field :provider_updated_at, :utc_datetime_usec
    field :observed_at, :utc_datetime_usec

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) when is_map(attrs) do
    message
    |> cast(attrs, [
      :room_id,
      :lifecycle_state,
      :provider_message_id,
      :actor_kind,
      :actor_provider_id,
      :actor,
      :message_kind,
      :text,
      :content,
      :attachments,
      :mentions,
      :provider_created_at,
      :provider_updated_at,
      :observed_at
    ])
    |> validate_required([
      :room_id,
      :lifecycle_state,
      :provider_message_id,
      :actor_kind,
      :actor,
      :message_kind,
      :content,
      :attachments,
      :mentions,
      :observed_at
    ])
    |> validate_non_empty(:actor_kind)
    |> validate_non_empty(:provider_message_id)
    |> validate_non_empty(:message_kind)
    |> validate_json_object(:actor)
    |> validate_json_object(:content)
    |> validate_json_array(:attachments)
    |> validate_json_array(:mentions)
    |> foreign_key_constraint(:room_id)
    |> unique_constraint([:room_id, :provider_message_id],
      name: :im_messages_provider_message_unique_idx
    )
    |> check_constraint(:message_kind, name: :im_messages_message_kind_present)
    |> check_constraint(:provider_message_id, name: :im_messages_provider_message_id_present)
    |> check_constraint(:actor_kind, name: :im_messages_actor_kind_present)
    |> check_constraint(:actor, name: :im_messages_actor_object)
    |> check_constraint(:content, name: :im_messages_content_object)
    |> check_constraint(:attachments, name: :im_messages_attachments_array)
    |> check_constraint(:mentions, name: :im_messages_mentions_array)
  end

  defp validate_non_empty(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_binary(value) and String.trim(value) != "" do
        true -> []
        false -> [{field, "must be a non-empty string"}]
      end
    end)
  end

  defp validate_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case BullX.JSON.json_object?(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end

  defp validate_json_array(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_list(value) and BullX.JSON.json_neutral?(value) do
        true -> []
        false -> [{field, "must be a JSON array"}]
      end
    end)
  end
end
