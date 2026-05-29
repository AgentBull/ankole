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
  @timestamps_opts [type: :utc_datetime_usec]

  @types [:ai_agent]

  @type t :: %__MODULE__{}

  schema "agents" do
    belongs_to :principal, Principal,
      foreign_key: :uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :type, Ecto.Enum, values: @types, default: :ai_agent
    field :profile, :map, default: %{}

    belongs_to :created_by_principal, Principal,
      foreign_key: :created_by_principal_uid,
      references: :uid,
      type: :string

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:uid, :type, :profile, :created_by_principal_uid])
    |> validate_required([:uid, :type, :profile])
    |> validate_map(:profile)
    |> foreign_key_constraint(:uid)
    |> foreign_key_constraint(:created_by_principal_uid)
    |> unique_constraint(:uid, name: :agents_pkey)
    |> check_constraint(:profile, name: :agents_profile_object)
  end
end
