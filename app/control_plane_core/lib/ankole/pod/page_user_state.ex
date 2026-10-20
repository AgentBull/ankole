defmodule Ankole.Pod.PageUserState do
  @moduledoc """
  One person's relation to one page: when they favorited it and when they last
  visited it. A row with neither value carries no information.
  """

  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true

  import Ecto.Changeset

  @primary_key false
  schema "page_user_states" do
    field :principal_uid, Ankole.Ecto.PrincipalKey, primary_key: true
    field :page_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :favorited_at, :utc_datetime_usec
    field :visited_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:principal_uid, :page_id, :favorited_at, :visited_at])
    |> validate_required([:principal_uid, :page_id])
    |> foreign_key_constraint(:page_id, name: :page_user_states_tenant_id_page_id_fkey)
    |> unique_constraint([:principal_uid, :page_id], name: :page_user_states_pkey)
  end
end
