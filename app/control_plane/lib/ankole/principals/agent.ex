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

    field :group_memory_disclosure_mode, Ecto.Enum,
      values: [:strict, :relaxed],
      default: :strict

    belongs_to :owner_principal, Principal,
      foreign_key: :owner_principal_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

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
    |> cast(attrs, [
      :uid,
      :type,
      :role,
      :options,
      :owner_principal_uid,
      :group_memory_disclosure_mode,
      :created_by_principal_uid
    ])
    |> normalize_blank([:role, :owner_principal_uid, :created_by_principal_uid])
    |> validate_required([
      :uid,
      :type,
      :role,
      :options,
      :owner_principal_uid,
      :group_memory_disclosure_mode
    ])
    |> JSONPayload.validate_map(:options)
    |> foreign_key_constraint(:uid)
    |> foreign_key_constraint(:owner_principal_uid)
    |> foreign_key_constraint(:created_by_principal_uid)
    |> unique_constraint(:uid, name: :agents_pkey)
    |> check_constraint(:role, name: :agents_role_present)
    |> check_constraint(:options, name: :agents_options_object)
    |> check_constraint(:group_memory_disclosure_mode,
      name: :agents_group_memory_disclosure_mode_check
    )
  end
end
