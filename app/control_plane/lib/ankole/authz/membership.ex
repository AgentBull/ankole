defmodule Ankole.AuthZ.Membership do
  @moduledoc """
  Static Principal membership in an AuthZ group.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AuthZ.Group
  alias Ankole.Principals.Principal

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "principal_group_memberships" do
    belongs_to :group, Group, type: :binary_id, primary_key: true

    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: :string,
      primary_key: true

    timestamps(updated_at: false)
  end

  @doc """
  Builds a changeset for authorization membership rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:group_id, :principal_uid])
    |> normalize_uid(:principal_uid)
    |> validate_required([:group_id, :principal_uid])
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:group_id, name: :principal_group_memberships_pkey)
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      value -> value
    end)
  end
end
