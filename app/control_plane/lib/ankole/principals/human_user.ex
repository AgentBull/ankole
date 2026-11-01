defmodule Ankole.Principals.HumanUser do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Principals

  @email_format ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/

  postgres do
    table("human_users")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(email: "human_users_email_index", mobile: "human_users_mobile_index")
    foreign_key_names([{:principal_uid, "human_users_principal_uid_fkey"}])

    unique_index_names([
      {[:email], "human_users_email_index"},
      {[:mobile], "human_users_mobile_index"}
    ])
  end

  attributes do
    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:email, :string, public?: true)
    attribute(:mobile, :string, public?: true)
    attribute(:job_title, :string, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:email, [:email])
    identity(:mobile, [:mobile])
  end

  relationships do
    belongs_to :principal, Ankole.Principals.Principal do
      source_attribute(:principal_uid)
      destination_attribute(:uid)
      define_attribute?(false)
    end
  end

  changes do
    change(Ankole.Principals.Changes.NormalizeContact)
  end

  validations do
    validate(match(:email, @email_format), message: "is invalid")
  end

  actions do
    defaults([:read])

    read :read_across_tenants do
      multitenancy(:allow_global)
    end

    create :create_in_tx do
      accept([:principal_uid, :email, :mobile, :job_title])
    end

    update :profile_in_tx do
      accept([:email, :mobile, :job_title])
    end
  end

  @type t :: %__MODULE__{}
  def email_format, do: @email_format
end
