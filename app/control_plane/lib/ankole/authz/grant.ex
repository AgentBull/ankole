defmodule Ankole.AuthZ.Grant do
  @moduledoc """
  Permission grant owned by either one Principal or one Principal group.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AuthZ.Group
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "permission_grants" do
    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: :string

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
    |> normalize_uid(:principal_uid)
    |> validate_required([:resource_pattern, :action, :condition, :metadata])
    |> validate_no_colon(:action)
    |> validate_map(:metadata)
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
      case validate_kernel_pattern(value) do
        :ok -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end

  defp validate_condition(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case validate_kernel_condition(value) do
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

  defp validate_kernel_pattern(value) when is_binary(value) do
    try do
      case Ankole.Kernel.authz_validate_resource_pattern(value) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
        _other -> {:error, "is invalid"}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      _kind, reason -> {:error, inspect(reason)}
    end
  end

  defp validate_kernel_pattern(_value), do: {:error, "must be a string"}

  defp validate_kernel_condition(value) when is_binary(value) do
    try do
      case Ankole.Kernel.authz_validate_condition(value) do
        true -> :ok
        {:error, reason} -> {:error, to_string(reason)}
        _other -> {:error, "is invalid"}
      end
    rescue
      exception -> {:error, Exception.message(exception)}
    catch
      _kind, reason -> {:error, inspect(reason)}
    end
  end

  defp validate_kernel_condition(_value), do: {:error, "must be a string"}

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_map(value) do
        true -> []
        false -> [{field, "must be a map"}]
      end
    end)
  end
end
