defmodule BullX.AuthZ.PrincipalGroupMembership do
  @moduledoc """
  Join row that grants a Principal membership in an AuthZ group.

  Groups are authorization subjects, not organizational tenants. Membership
  lets a grant apply to many Principals while each Principal remains the durable
  actor recorded on audit and runtime facts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.AuthZ.PrincipalGroup
  alias BullX.Principals.Principal

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "principal_group_memberships" do
    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: :string,
      primary_key: true

    belongs_to :group, PrincipalGroup, type: :binary_id, primary_key: true

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:principal_uid, :group_id])
    |> validate_required([:principal_uid, :group_id])
    |> assoc_constraint(:principal)
    |> assoc_constraint(:group)
    |> unique_constraint([:principal_uid, :group_id], name: :principal_group_memberships_pkey)
  end
end
