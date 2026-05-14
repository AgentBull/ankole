defmodule BullX.Principals.Agent do
  @moduledoc """
  Agent-specific extension row for an Agent Principal.

  `profile` stays JSONB in PostgreSQL. Runtime-specific profile validation is
  owned by the runtime design that introduces those profile fields.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Principal

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "agents" do
    belongs_to :principal, Principal, primary_key: true
    field :profile, :map, default: %{}
    belongs_to :created_by_principal, Principal

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:principal_id, :profile, :created_by_principal_id])
    |> validate_required([:principal_id, :profile])
    |> validate_map(:profile)
    |> foreign_key_constraint(:principal_id)
    |> foreign_key_constraint(:created_by_principal_id)
    |> unique_constraint(:principal_id, name: :agents_pkey)
    |> check_constraint(:profile, name: :agents_profile_object)
  end
end
