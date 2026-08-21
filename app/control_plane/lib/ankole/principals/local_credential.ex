defmodule Ankole.Principals.LocalCredential do
  @moduledoc """
  Local email-and-password sign-in credential for one human user.

  The row stores an Argon2id hash in PHC string format. Only a human user can
  hold a local credential; the table keys on `human_users.principal_uid`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.HumanUser

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  # A-Z without I and O, a-z without l, and 2-9. The set avoids characters
  # that read alike when an operator sends the password to a user by hand.
  @initial_password_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
  @initial_password_length 16

  schema "human_user_local_credentials" do
    belongs_to :human_user, HumanUser,
      foreign_key: :principal_uid,
      references: :principal_uid,
      type: Ankole.Ecto.PrincipalKey,
      primary_key: true

    field :password_hash, :string
    field :must_change_password, :boolean, default: false

    timestamps()
  end

  @doc """
  Builds a changeset for local credential rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(local_credential, attrs) do
    local_credential
    |> cast(attrs, [:principal_uid, :password_hash, :must_change_password])
    |> validate_required([:principal_uid, :password_hash, :must_change_password])
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint(:principal_uid, name: :human_user_local_credentials_pkey)
  end

  @doc """
  Generates one random 16-character initial password.
  """
  @spec generate_initial_password() :: String.t()
  def generate_initial_password do
    alphabet_size = length(@initial_password_alphabet)

    @initial_password_length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(&Enum.at(@initial_password_alphabet, rem(&1, alphabet_size)))
    |> List.to_string()
  end
end
