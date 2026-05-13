defmodule BullX.AuthZ.PrincipalGroup do
  @moduledoc """
  Static authorization group for BullX Principals.

  `name` is the stable lowercase group key. Public changesets cannot set
  `built_in`; that flag is reserved for BullX-managed groups such as `admin`.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.AuthZ.PrincipalGroupMembership
  alias BullX.AuthZ.PermissionGrant

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "principal_groups" do
    field :name, :string
    field :description, :string
    field :built_in, :boolean, default: false

    has_many :memberships, PrincipalGroupMembership, foreign_key: :group_id
    has_many :permission_grants, PermissionGrant, foreign_key: :group_id

    timestamps()
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description])
    |> common_validations()
  end

  @spec system_create_changeset(t(), map()) :: Ecto.Changeset.t()
  def system_create_changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :description, :built_in])
    |> common_validations()
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [:description])
    |> normalize_blank([:description])
  end

  defp common_validations(changeset) do
    changeset
    |> normalize_blank([:name, :description])
    |> normalize_name()
    |> validate_required([:name, :built_in])
    |> unique_constraint(:name)
    |> check_constraint(:name, name: :principal_groups_name_present, message: "must not be empty")
    |> check_constraint(:name,
      name: :principal_groups_name_lowercase,
      message: "must be lowercase"
    )
  end

  defp normalize_name(changeset) do
    update_change(changeset, :name, &String.downcase/1)
  end
end
