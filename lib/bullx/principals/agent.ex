defmodule BullX.Principals.Agent do
  @moduledoc """
  Agent-specific extension row for an Agent Principal.

  `profile` stays JSONB in PostgreSQL. Runtime-specific profile validation is
  intentionally absent while Agent runtimes are being rebuilt.
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
    field :type, :string
    field :profile, :map, default: %{}
    belongs_to :created_by_principal, Principal

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:principal_id, :type, :profile, :created_by_principal_id])
    |> normalize_blank([:type])
    |> validate_required([:principal_id, :type, :profile])
    |> validate_format(:type, ~r/^[a-z][a-z0-9_:-]*$/)
    |> validate_map(:profile)
    |> foreign_key_constraint(:principal_id)
    |> foreign_key_constraint(:created_by_principal_id)
    |> unique_constraint(:principal_id, name: :agents_pkey)
    |> check_constraint(:profile, name: :agents_profile_object)
    |> check_constraint(:type, name: :agents_type_format)
  end
end
