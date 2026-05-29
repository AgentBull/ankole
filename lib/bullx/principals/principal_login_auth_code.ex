defmodule BullX.Principals.PrincipalLoginAuthCode do
  @moduledoc """
  Short-lived one-time Web login code for an already bound Human Principal.

  Expiry is computed from `inserted_at` plus runtime configuration. Successful
  consumption deletes the row.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.Principal

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "principal_login_auth_codes" do
    field :code_hash, :string
    field :metadata, :map, default: %{}

    belongs_to :principal, Principal,
      foreign_key: :principal_uid,
      references: :uid,
      type: :string

    timestamps()
  end

  def changeset(login_auth_code, attrs) do
    login_auth_code
    |> cast(attrs, [:code_hash, :principal_uid, :metadata])
    |> validate_required([:code_hash, :principal_uid, :metadata])
    |> validate_map(:metadata)
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:code_hash)
    |> check_constraint(:metadata, name: :principal_login_auth_codes_metadata_object)
  end
end
