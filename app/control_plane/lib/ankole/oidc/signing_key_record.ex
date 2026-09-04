defmodule Ankole.OIDC.SigningKeyRecord do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "oidc_signing_keys" do
    field :kid, :string
    field :public_jwk, :map
    field :private_key_ciphertext, :string, redact: true
    timestamps()
  end

  def changeset(key, attrs) do
    key
    |> cast(attrs, [:id, :kid, :public_jwk, :private_key_ciphertext])
    |> validate_required([:id, :kid, :public_jwk, :private_key_ciphertext])
    |> check_constraint(:id, name: :oidc_signing_keys_primary_only)
    |> unique_constraint(:kid)
  end
end
