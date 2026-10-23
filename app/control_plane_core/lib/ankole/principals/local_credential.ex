defmodule Ankole.Principals.LocalCredential do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals

  postgres do
    table("human_user_local_credentials")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:principal_uid, "human_user_local_credentials_principal_uid_fkey"}])
  end

  attributes do
    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:password_hash, :string, public?: true, allow_nil?: false, sensitive?: true)
    attribute(:must_change_password, :boolean, public?: true, allow_nil?: false, default: false)
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    belongs_to :human_user, Ankole.Principals.HumanUser do
      source_attribute(:principal_uid)
      destination_attribute(:principal_uid)
      define_attribute?(false)
    end
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([:principal_uid, :password_hash, :must_change_password])
    end

    update :set_password_in_tx do
      accept([:password_hash, :must_change_password])
    end

    action :complete_forced_password_change, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :term, allow_nil?: false)
      argument(:password_hash, :term, allow_nil?: false, sensitive?: true)
      argument(:credential_version, :integer, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.complete_forced_password_change_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.password_hash,
          input.arguments.credential_version
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :put_password, :struct do
      constraints(instance_of: __MODULE__)
      argument(:uid, :term, allow_nil?: false)
      argument(:password_hash, :term, allow_nil?: false, sensitive?: true)
      argument(:must_change_password, :boolean, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Principals.put_local_password_in_tx(
          Ankole.Repo,
          input.arguments.uid,
          input.arguments.password_hash,
          input.arguments.must_change_password
        )
        |> Ankole.Errors.wrap()
      end)
    end
  end

  @type t :: %__MODULE__{}
  @initial_password_alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
  @initial_password_length 16

  def version(%{__struct__: __MODULE__, updated_at: %DateTime{} = updated_at}),
    do: DateTime.to_unix(updated_at, :microsecond)

  def generate_initial_password do
    alphabet_size = length(@initial_password_alphabet)

    @initial_password_length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(&Enum.at(@initial_password_alphabet, rem(&1, alphabet_size)))
    |> List.to_string()
  end
end
