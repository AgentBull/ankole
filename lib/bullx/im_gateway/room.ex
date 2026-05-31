defmodule BullX.IMGateway.Room do
  @moduledoc """
  Canonical room mirror for an external IM provider space.

  The uniqueness boundary is provider + connected realm + provider room id, not
  a BullX channel-source id. Multiple bot sources may observe the same external
  room, but BullX should still store one room fact for that external place.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.IMGateway.Message

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds [:direct, :group, :unknown]

  @type t :: %__MODULE__{}

  schema "im_rooms" do
    field :provider, :string
    field :provider_realm_id, :string, default: ""
    field :provider_room_id, :string
    field :kind, Ecto.Enum, values: @kinds, default: :unknown
    field :title, :string
    field :metadata, :map, default: %{}

    belongs_to :parent_room, __MODULE__
    has_many :messages, Message

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(room, attrs) when is_map(attrs) do
    room
    |> cast(attrs, [
      :provider,
      :provider_realm_id,
      :provider_room_id,
      :kind,
      :title,
      :parent_room_id,
      :metadata
    ])
    |> validate_required([:provider, :provider_room_id, :kind, :metadata])
    |> validate_non_empty(:provider)
    |> validate_non_empty(:provider_room_id)
    |> validate_json_object(:metadata)
    |> unique_constraint([:provider, :provider_realm_id, :provider_room_id],
      name: :im_rooms_provider_realm_room_unique_idx
    )
    |> foreign_key_constraint(:parent_room_id)
    |> check_constraint(:provider, name: :im_rooms_provider_present)
    |> check_constraint(:provider_room_id, name: :im_rooms_provider_room_id_present)
    |> check_constraint(:metadata, name: :im_rooms_metadata_object)
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
end
