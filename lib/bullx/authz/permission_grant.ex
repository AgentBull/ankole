defmodule BullX.AuthZ.PermissionGrant do
  @moduledoc """
  Allow grant assigned to exactly one Principal or Principal group.

  Applicability is decided by subject, exact action equality, and resource
  pattern matching. CEL evaluates `condition` only after those checks.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.AuthZ.CEL
  alias BullX.AuthZ.PrincipalGroup
  alias BullX.AuthZ.ResourcePattern
  alias BullX.Principals.Principal

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "permission_grants" do
    field :resource_pattern, :string
    field :action, :string
    field :condition, :string, default: "true"
    field :description, :string
    field :metadata, :map, default: %{}

    belongs_to :principal, Principal
    belongs_to :group, PrincipalGroup

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    has_condition? = condition_present?(attrs)

    grant
    |> cast(attrs, [
      :principal_id,
      :group_id,
      :resource_pattern,
      :action,
      :description,
      :metadata
    ])
    |> normalize_blank([:resource_pattern, :action, :description])
    |> handle_condition(attrs, has_condition?)
    |> validate_required([:resource_pattern, :action, :condition, :metadata])
    |> validate_map(:metadata)
    |> validate_current_condition()
    |> validate_principal_exclusive()
    |> validate_resource_pattern()
    |> validate_action()
    |> assoc_constraint(:principal)
    |> assoc_constraint(:group)
    |> check_constraint(:principal_id,
      name: :permission_grants_principal_exclusive,
      message: "exactly one of principal_id or group_id must be set"
    )
    |> check_constraint(:resource_pattern,
      name: :permission_grants_resource_pattern_present,
      message: "must not be empty"
    )
    |> check_constraint(:action,
      name: :permission_grants_action_no_colon,
      message: "must not contain ':'"
    )
    |> check_constraint(:action,
      name: :permission_grants_action_present,
      message: "must not be empty"
    )
    |> check_constraint(:metadata, name: :permission_grants_metadata_object)
  end

  defp condition_present?(attrs) when is_map(attrs) do
    Map.has_key?(attrs, :condition) or Map.has_key?(attrs, "condition")
  end

  defp condition_value(attrs) do
    Map.get(attrs, :condition, Map.get(attrs, "condition"))
  end

  defp handle_condition(changeset, _attrs, false) do
    case get_field(changeset, :condition) do
      nil -> put_change(changeset, :condition, "true")
      _condition -> changeset
    end
  end

  defp handle_condition(changeset, attrs, true) do
    case condition_value(attrs) do
      value when is_binary(value) ->
        put_trimmed_condition(changeset, value)

      nil ->
        add_error(changeset, :condition, "must not be empty")

      _value ->
        add_error(changeset, :condition, "must be a string")
    end
  end

  defp put_trimmed_condition(changeset, value) do
    case String.trim(value) do
      "" -> add_error(changeset, :condition, "must not be empty")
      trimmed -> put_change(changeset, :condition, trimmed)
    end
  end

  defp validate_current_condition(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_current_condition(changeset) do
    case get_field(changeset, :condition) do
      condition when is_binary(condition) -> validate_condition_text(changeset, condition)
      _condition -> changeset
    end
  end

  defp validate_condition_text(changeset, condition) do
    case CEL.validate_condition(condition) do
      :ok -> changeset
      {:error, reason} -> add_error(changeset, :condition, "is invalid: #{reason}")
    end
  end

  defp validate_principal_exclusive(changeset) do
    principal_id = get_field(changeset, :principal_id)
    group_id = get_field(changeset, :group_id)

    case {principal_id, group_id} do
      {nil, nil} ->
        changeset
        |> add_error(:principal_id, "or group_id must be set")
        |> add_error(:group_id, "or principal_id must be set")

      {_principal_id, nil} ->
        changeset

      {nil, _group_id} ->
        changeset

      {_principal_id, _group_id} ->
        changeset
        |> add_error(:principal_id, "must be empty when group_id is set")
        |> add_error(:group_id, "must be empty when principal_id is set")
    end
  end

  defp validate_resource_pattern(changeset) do
    case get_field(changeset, :resource_pattern) do
      nil ->
        changeset

      pattern ->
        case ResourcePattern.validate(pattern) do
          :ok -> changeset
          {:error, reason} -> add_error(changeset, :resource_pattern, reason)
        end
    end
  end

  defp validate_action(changeset) do
    case get_field(changeset, :action) do
      nil ->
        changeset

      action ->
        case String.contains?(action, ":") do
          true -> add_error(changeset, :action, "must not contain ':'")
          false -> changeset
        end
    end
  end
end
