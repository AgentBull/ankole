defmodule Ankole.Principals.Invitation do
  @moduledoc "A revocable Pod invitation with a bounded use count."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals

  postgres do
    table("pod_invitations")
    repo(Ankole.Repo)
    migrate?(false)

    check_constraints do
      check_constraint(:kind, "pod_invitations_target")
      check_constraint(:membership, "pod_invitations_membership")
      check_constraint(:used_count, "pod_invitations_quota")
    end

    foreign_key_names([{:created_by_principal_uid, "pod_invitations_creator_fkey"}])

    unique_index_names([
      {[:token_digest], "pod_invitations_token_digest_index"},
      {[:code_digest], "pod_invitations_code_digest_index"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:kind, :atom, allow_nil?: false, constraints: [one_of: [:link, :email]])
    attribute(:invited_email, :string)

    attribute(:membership, :atom,
      allow_nil?: false,
      default: :member,
      constraints: [one_of: [:member, :guest]]
    )

    attribute(:token_digest, :binary, allow_nil?: false, sensitive?: true)
    attribute(:code_digest, :binary, allow_nil?: false, sensitive?: true)
    attribute(:max_uses, :integer, constraints: [min: 1])
    attribute(:used_count, :integer, allow_nil?: false, default: 0, constraints: [min: 0])
    attribute(:created_by_principal_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    read :read_across_tenants do
      multitenancy(:allow_global)
    end

    create :create_in_tx do
      accept([
        :kind,
        :invited_email,
        :membership,
        :token_digest,
        :code_digest,
        :max_uses,
        :created_by_principal_uid,
        :expires_at
      ])
    end

    update :use_in_tx do
      accept([])
      change(atomic_update(:used_count, expr(used_count + 1)))
    end

    update :revoke_in_tx do
      accept([])
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end
end
