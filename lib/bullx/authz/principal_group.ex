defmodule BullX.AuthZ.PrincipalGroup do
  @moduledoc """
  Authorization group for BullX Principals.

  `name` is the stable lowercase group key. `kind` separates static membership
  groups from CEL-computed effective groups. Public changesets cannot set
  `built_in`; that flag is reserved for BullX-managed groups such as `admin`
  and `all_humans`.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.AuthZ.CEL
  alias BullX.AuthZ.PrincipalGroupMembership
  alias BullX.AuthZ.PermissionGrant

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "principal_groups" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:static, :computed], default: :static
    field :description, :string
    field :computed_condition, :string
    field :built_in, :boolean, default: false

    has_many :memberships, PrincipalGroupMembership, foreign_key: :group_id
    has_many :permission_grants, PermissionGrant, foreign_key: :group_id

    timestamps()
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :kind, :description, :computed_condition])
    |> common_validations()
  end

  @spec system_create_changeset(t(), map()) :: Ecto.Changeset.t()
  def system_create_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :kind, :description, :computed_condition, :built_in])
    |> common_validations()
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [:description, :computed_condition])
    |> normalize_blank([:description, :computed_condition])
    |> validate_kind_condition()
  end

  defp common_validations(changeset) do
    changeset
    |> normalize_blank([:name, :description, :computed_condition])
    |> normalize_name()
    |> validate_required([:name, :kind, :built_in])
    |> validate_kind_condition()
    |> unique_constraint(:name)
    |> check_constraint(:name, name: :principal_groups_name_present, message: "must not be empty")
    |> check_constraint(:name,
      name: :principal_groups_name_lowercase,
      message: "must be lowercase"
    )
    |> check_constraint(:computed_condition,
      name: :principal_groups_computed_condition_by_kind,
      message: "must be present only for computed groups"
    )
  end

  defp normalize_name(changeset) do
    update_change(changeset, :name, &String.downcase/1)
  end

  defp validate_kind_condition(changeset) do
    case get_field(changeset, :kind) do
      :static -> validate_static_group(changeset)
      :computed -> validate_computed_group(changeset)
      _kind -> changeset
    end
  end

  defp validate_static_group(changeset) do
    case get_field(changeset, :computed_condition) do
      nil -> changeset
      _condition -> add_error(changeset, :computed_condition, "must be empty for static groups")
    end
  end

  defp validate_computed_group(changeset) do
    changeset
    |> validate_required([:computed_condition])
    |> validate_computed_condition()
  end

  defp validate_computed_condition(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_computed_condition(changeset) do
    case get_field(changeset, :computed_condition) do
      condition when is_binary(condition) ->
        validate_computed_condition_text(changeset, condition)

      _condition ->
        changeset
    end
  end

  defp validate_computed_condition_text(changeset, condition) do
    case CEL.validate_condition(condition) do
      :ok -> changeset
      {:error, reason} -> add_error(changeset, :computed_condition, "is invalid: #{reason}")
    end
  end
end
