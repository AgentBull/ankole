defmodule BullX.Principals.ActivationCode do
  @moduledoc """
  Single-use preauth credential for creating a Human Principal from a channel.

  Plaintext activation codes are returned once to callers and never stored.
  Used rows are retained with consumption context for audit and setup flows.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Principal

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "activation_codes" do
    field :code_hash, :string
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec
    field :used_by_adapter, :string
    field :used_by_channel_id, :string
    field :used_by_external_id, :string
    field :metadata, :map, default: %{}

    belongs_to :created_by_principal, Principal
    belongs_to :used_by_principal, Principal

    timestamps()
  end

  def changeset(activation_code, attrs) do
    activation_code
    |> cast(attrs, [
      :code_hash,
      :expires_at,
      :created_by_principal_id,
      :revoked_at,
      :used_at,
      :used_by_principal_id,
      :used_by_adapter,
      :used_by_channel_id,
      :used_by_external_id,
      :metadata
    ])
    |> validate_required([:code_hash, :expires_at, :metadata])
    |> validate_map(:metadata)
    |> foreign_key_constraint(:created_by_principal_id)
    |> foreign_key_constraint(:used_by_principal_id)
    |> unique_constraint(:code_hash)
    |> check_constraint(:metadata, name: :activation_codes_metadata_object)
  end
end
