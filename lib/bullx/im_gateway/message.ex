defmodule BullX.IMGateway.Message do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.IMGateway.Room
  alias BullX.Principals.{ExternalIdentity, Principal}

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @directions [:inbound, :outbound]
  @statuses [:pending, :received, :sent, :edited, :recalled, :deleted, :failed]

  @type t :: %__MODULE__{}

  schema "im_messages" do
    belongs_to :room, Room

    field :direction, Ecto.Enum, values: @directions
    field :status, Ecto.Enum, values: @statuses
    field :provider_message_id, :string
    field :provider_occurrence_id, :string
    field :actor_kind, :string, default: "unknown"
    belongs_to :actor_principal, Principal
    belongs_to :actor_external_identity, ExternalIdentity
    field :actor_provider_id, :string
    field :actor, :map, default: %{}
    field :message_kind, :string
    field :text, :string
    field :content, BullX.Ecto.JSONB, default: %{}
    field :attachments, BullX.Ecto.JSONB, default: []
    field :mentions, BullX.Ecto.JSONB, default: []
    field :reply_address, :map
    field :provider_created_at, :utc_datetime_usec
    field :provider_updated_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
    field :safe_error, :map

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) when is_map(attrs) do
    message
    |> cast(attrs, [
      :room_id,
      :direction,
      :status,
      :provider_message_id,
      :provider_occurrence_id,
      :actor_kind,
      :actor_principal_id,
      :actor_external_identity_id,
      :actor_provider_id,
      :actor,
      :message_kind,
      :text,
      :content,
      :attachments,
      :mentions,
      :reply_address,
      :provider_created_at,
      :provider_updated_at,
      :received_at,
      :sent_at,
      :safe_error
    ])
    |> validate_required([
      :room_id,
      :direction,
      :status,
      :actor_kind,
      :actor,
      :message_kind,
      :content,
      :attachments,
      :mentions,
      :received_at
    ])
    |> validate_non_empty(:actor_kind)
    |> validate_non_empty(:message_kind)
    |> validate_human_actor_has_principal()
    |> validate_json_object(:actor)
    |> validate_json_object(:content)
    |> validate_json_array(:attachments)
    |> validate_json_array(:mentions)
    |> validate_optional_json_object(:reply_address)
    |> validate_optional_json_object(:safe_error)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:actor_principal_id)
    |> foreign_key_constraint(:actor_external_identity_id)
    |> unique_constraint([:room_id, :provider_message_id],
      name: :im_messages_provider_message_unique_idx
    )
    |> unique_constraint([:room_id, :provider_occurrence_id],
      name: :im_messages_provider_occurrence_unique_idx
    )
    |> check_constraint(:message_kind, name: :im_messages_message_kind_present)
    |> check_constraint(:actor_kind, name: :im_messages_actor_kind_present)
    |> check_constraint(:actor_principal_id, name: :im_messages_human_actor_has_principal)
    |> check_constraint(:actor, name: :im_messages_actor_object)
    |> check_constraint(:content, name: :im_messages_content_object)
    |> check_constraint(:attachments, name: :im_messages_attachments_array)
    |> check_constraint(:mentions, name: :im_messages_mentions_array)
    |> check_constraint(:reply_address, name: :im_messages_reply_address_object)
    |> check_constraint(:safe_error, name: :im_messages_safe_error_object)
  end

  defp validate_human_actor_has_principal(changeset) do
    case {get_field(changeset, :actor_kind), get_field(changeset, :actor_principal_id)} do
      {"human", principal_id} when is_binary(principal_id) ->
        changeset

      {"human", _missing} ->
        add_error(changeset, :actor_principal_id, "is required for human actor")

      _other ->
        changeset
    end
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

  defp validate_optional_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_nil(value) or BullX.JSON.json_object?(value) do
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
