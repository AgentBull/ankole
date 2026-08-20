defmodule Ankole.AuthZ.Group do
  @moduledoc """
  Principal group used by the AuthZ rule engine.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Membership

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "principal_groups" do
    field :name, :string
    field :display_name, :string

    field :domain, Ecto.Enum,
      values: [:operator, :directory, :im_group, :signal_source],
      default: :operator

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

  @doc """
  Builds a changeset for authorization group rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :display_name,
      :domain,
      :kind,
      :built_in,
      :computed_condition,
      :description,
      :metadata
    ])
    |> normalize_blank([:name, :display_name, :computed_condition, :description])
    |> normalize_name()
    |> validate_required([:name, :display_name, :domain, :kind, :built_in, :metadata])
    |> JSONPayload.validate_map(:metadata)
    |> validate_kind_shape()
    |> unique_constraint(:name, name: :principal_groups_name_index)
    |> check_constraint(:name, name: :principal_groups_name_present)
    |> check_constraint(:name, name: :principal_groups_name_lowercase)
    |> check_constraint(:display_name, name: :principal_groups_display_name_present)
    |> check_constraint(:computed_condition, name: :principal_groups_computed_condition_by_kind)
    |> check_constraint(:domain, name: :principal_groups_computed_domain)
    |> check_constraint(:metadata, name: :principal_groups_metadata_object)
  end

  defp validate_kind_shape(changeset) do
    case get_field(changeset, :kind) do
      :static ->
        validate_absent(changeset, :computed_condition)

      :computed ->
        changeset
        |> validate_required([:computed_condition])
        |> validate_condition(:computed_condition)
        |> validate_operator_domain()

      _kind ->
        changeset
    end
  end

  defp validate_operator_domain(changeset) do
    case get_field(changeset, :domain) do
      :operator -> changeset
      _domain -> add_error(changeset, :domain, "must be operator for computed groups")
    end
  end

  defp validate_condition(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case Input.validate_condition_syntax(value) do
        :ok -> []
        {:error, reason} -> [{field, reason}]
      end
    end)
  end

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
end
