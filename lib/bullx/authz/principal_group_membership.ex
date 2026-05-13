defmodule BullX.AuthZ.PrincipalGroupMembership do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.AuthZ.PrincipalGroup
  alias BullX.Principals.Principal

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "principal_group_memberships" do
    belongs_to :principal, Principal, primary_key: true
    belongs_to :group, PrincipalGroup, primary_key: true

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:principal_id, :group_id])
    |> validate_required([:principal_id, :group_id])
    |> assoc_constraint(:principal)
    |> assoc_constraint(:group)
    |> unique_constraint([:principal_id, :group_id], name: :principal_group_memberships_pkey)
  end
end
