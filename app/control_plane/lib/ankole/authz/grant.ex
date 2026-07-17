defmodule Ankole.AuthZ.Grant do
  @moduledoc """
  Permission grant owned by either one Principal or one Principal group.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "permission_grants" do
    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    belongs_to :group, Group, type: :binary_id

    field :resource_pattern, :string
    field :action, :string
    field :condition, :string, default: "true"
    field :description, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for authorization grant rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :principal_uid,
      :group_id,
      :resource_pattern,
      :action,
      :condition,
      :description,
      :metadata
    ])
    |> normalize_blank([
      :principal_uid,
      :group_id,
      :resource_pattern,
      :action,
      :condition,
      :description
    ])
    |> default_condition()
    |> validate_required([:resource_pattern, :action, :condition, :metadata])
    |> validate_no_colon(:action)
    |> JSONPayload.validate_map(:metadata)
    |> validate_owner_shape()
    |> validate_resource_pattern(:resource_pattern)
    |> validate_condition(:condition)
    |> foreign_key_constraint(:principal_uid)
    |> foreign_key_constraint(:group_id)
    |> unique_constraint(:principal_uid, name: :permission_grants_principal_natural_index)
    |> unique_constraint(:group_id, name: :permission_grants_group_natural_index)
    |> check_constraint(:principal_uid, name: :permission_grants_owner_shape)
    |> check_constraint(:resource_pattern, name: :permission_grants_resource_pattern_present)
    |> check_constraint(:action, name: :permission_grants_action_present)
    |> check_constraint(:action, name: :permission_grants_action_no_colon)
    |> check_constraint(:condition, name: :permission_grants_condition_present)
    |> check_constraint(:metadata, name: :permission_grants_metadata_object)
  end

  defp default_condition(changeset) do
    case get_field(changeset, :condition) do
      nil -> put_change(changeset, :condition, "true")
      _condition -> changeset
    end
  end

  defp validate_owner_shape(changeset) do
    case {get_field(changeset, :principal_uid), get_field(changeset, :group_id)} do
      {principal_uid, nil} when is_binary(principal_uid) -> changeset
      {nil, group_id} when is_binary(group_id) -> changeset
      {nil, nil} -> add_error(changeset, :principal_uid, "or group_id is required")
      {_principal_uid, _group_id} -> add_error(changeset, :group_id, "must be blank")
    end
  end

  defp validate_resource_pattern(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Input.validate_resource_pattern_syntax(value) do
        :ok -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end

  defp validate_condition(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Input.validate_condition_syntax(value) do
        :ok -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end

  defp validate_no_colon(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_binary(value) and String.contains?(value, ":") do
        true -> [{field, "must not contain colon"}]
        false -> []
      end
    end)
  end
end
