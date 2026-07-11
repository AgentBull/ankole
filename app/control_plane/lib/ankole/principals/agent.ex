defmodule Ankole.Principals.Agent do
  @moduledoc """
  Agent-specific subtype row keyed by `principals.uid`.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agents" do
    belongs_to :principal, Principal,
      foreign_key: :uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey,
      primary_key: true

    field :type, Ecto.Enum, values: [:ai_colleague], default: :ai_colleague
    field :role, :string
    field :options, :map, default: %{}

    belongs_to :created_by_principal, Principal,
      foreign_key: :created_by_principal_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    timestamps()
  end

  @doc """
  Builds a changeset for agent principal profile rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:uid, :type, :role, :options, :created_by_principal_uid])
    |> normalize_blank([:role, :created_by_principal_uid])
    |> validate_required([:uid, :type, :role, :options])
    |> JSONPayload.validate_map(:options)
    |> foreign_key_constraint(:uid)
    |> foreign_key_constraint(:created_by_principal_uid)
    |> unique_constraint(:uid, name: :agents_pkey)
    |> check_constraint(:role, name: :agents_role_present)
    |> check_constraint(:options, name: :agents_options_object)
  end
end
