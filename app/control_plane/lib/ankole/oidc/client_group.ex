defmodule Ankole.OIDC.ClientGroup do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AuthZ.Group
  alias Ankole.OIDC.Client

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "oidc_client_groups" do
    belongs_to :client, Client, primary_key: true
    belongs_to :group, Group, primary_key: true
    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:client_id, :group_id])
    |> validate_required([:client_id, :group_id])
    |> foreign_key_constraint(:client_id)
    |> foreign_key_constraint(:group_id)
    |> unique_constraint([:client_id, :group_id], name: :oidc_client_groups_pkey)
  end
end
