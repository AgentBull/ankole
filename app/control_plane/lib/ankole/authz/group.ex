defmodule Ankole.AuthZ.Group do
  @moduledoc """
  Principal group used by the AuthZ rule engine.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Membership
  alias Ankole.Kernel, as: AnkoleKernel

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "principal_groups" do
    field :name, :string
    field :display_name, :string
    field :kind, Ecto.Enum, values: [:static, :computed], default: :static
    field :built_in, :boolean, default: false
    field :computed_condition, :string
    field :description, :string
    field :metadata, :map, default: %{}

    has_many :memberships, Membership, foreign_key: :group_id
    has_many :external_bindings, ExternalBinding, foreign_key: :group_id
    has_many :grants, Grant, foreign_key: :group_id

    timestamps()
  end

  @doc false
  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :display_name,
      :kind,
      :built_in,
      :computed_condition,
      :description,
      :metadata
    ])
    |> ensure_id()
    |> normalize_blank([:name, :display_name, :computed_condition, :description])
    |> normalize_name()
    |> validate_required([:name, :display_name, :kind, :built_in, :metadata])
    |> validate_map(:metadata)
    |> validate_kind_shape()
    |> unique_constraint(:name, name: :principal_groups_name_index)
    |> check_constraint(:name, name: :principal_groups_name_present)
    |> check_constraint(:name, name: :principal_groups_name_lowercase)
    |> check_constraint(:display_name, name: :principal_groups_display_name_present)
    |> check_constraint(:computed_condition, name: :principal_groups_computed_condition_by_kind)
    |> check_constraint(:metadata, name: :principal_groups_metadata_object)
  end

  defp ensure_id(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :id, AnkoleKernel.gen_uuid_v7())
      _id -> changeset
    end
  end

  defp validate_kind_shape(changeset) do
    case get_field(changeset, :kind) do
      :static ->
        validate_absent(changeset, :computed_condition)

      :computed ->
        changeset
        |> validate_required([:computed_condition])
        |> validate_condition(:computed_condition)

      _kind ->
        changeset
    end
  end

  defp validate_condition(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case validate_kernel_condition(value) do
        :ok -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end

  defp validate_kernel_condition(value) when is_binary(value) do
    try do
      case AnkoleKernel.authz_validate_condition(value) do
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

  defp validate_absent(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> add_error(changeset, field, "must be blank")
    end
  end

  defp normalize_name(changeset) do
    update_change(changeset, :name, fn
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
