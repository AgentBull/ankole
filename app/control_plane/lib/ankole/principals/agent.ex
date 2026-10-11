defmodule Ankole.Principals.Agent do
  @moduledoc """
  Agent-specific subtype row keyed by `principals.uid`.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2, normalize_lower: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "agents" do
    belongs_to :principal, Principal,
      foreign_key: :uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey,
      primary_key: true

    field :handle, :string
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

    field :created_by, Ankole.Ecto.ActorRef

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
      :handle,
      :type,
      :role,
      :options,
      :owner_principal_uid,
      :group_memory_disclosure_mode,
      :created_by
    ])
    |> normalize_blank([:handle, :role, :owner_principal_uid])
    |> normalize_lower(:handle)
    |> validate_required([
      :uid,
      :handle,
      :type,
      :role,
      :options,
      :owner_principal_uid,
      :group_memory_disclosure_mode
    ])
    |> JSONPayload.validate_map(:options)
    |> foreign_key_constraint(:uid)
    |> foreign_key_constraint(:owner_principal_uid)
    |> unique_constraint(:uid, name: :agents_pkey)
    |> unique_constraint(:handle, name: :agents_tenant_id_handle_index)
    |> validate_format(:handle, ~r/\A[a-z0-9][a-z0-9._-]{0,95}\z/)
    |> check_constraint(:handle, name: :agents_handle_format)
    |> check_constraint(:role, name: :agents_role_present)
    |> check_constraint(:options, name: :agents_options_object)
    |> check_constraint(:group_memory_disclosure_mode,
      name: :agents_group_memory_disclosure_mode_check
    )
  end
end
