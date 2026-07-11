defmodule Ankole.AIAgent.CodexAccounts.Account do
  @moduledoc """
  Operator-managed ChatGPT subscription account used by Codex workers.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  @primary_key {:account_id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @account_id_format ~r/\A(?!\.{1,2}\z)[A-Za-z0-9._-]+\z/

  schema "codex_accounts" do
    field(:name, :string)
    field(:encrypted_auth_json, :string)
    field(:auth_hash, :string)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:account_id, :name, :encrypted_auth_json, :auth_hash])
    |> normalize_blank([:account_id, :name, :encrypted_auth_json, :auth_hash])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:account_id, :name, :encrypted_auth_json, :auth_hash])
    |> validate_length(:name, max: 120)
    |> validate_format(:account_id, @account_id_format)
    |> validate_exclusion(:account_id, ["aigateway"])
    |> unique_constraint(:account_id, name: :codex_accounts_pkey)
    |> unique_constraint(:name, name: :codex_accounts_name_lower_index)
    |> check_constraint(:name, name: :codex_accounts_name_present)
    |> check_constraint(:encrypted_auth_json, name: :codex_accounts_auth_present)
    |> check_constraint(:auth_hash, name: :codex_accounts_hash_present)
  end
end
