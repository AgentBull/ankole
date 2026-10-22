defmodule Ankole.Principals.AccessRestriction do
  @moduledoc false
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Principals

  postgres do
    table("human_access_restrictions")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(active_restriction: "human_access_restrictions_active_index")
    identity_wheres_to_sql(active_restriction: "cleared_at IS NULL")
    foreign_key_names([{:principal_uid, "human_access_restrictions_principal_uid_fkey"}])

    unique_index_names([
      {[:principal_uid, :source, :reason], "human_access_restrictions_active_index"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, public?: true, allow_nil?: false)
    attribute(:source, :string, public?: true, allow_nil?: false, constraints: [max_length: 200])
    attribute(:reason, :string, public?: true, allow_nil?: false, constraints: [max_length: 2000])

    attribute(:operation_id, :string,
      public?: true,
      allow_nil?: false,
      constraints: [max_length: 200]
    )

    attribute(:provider_time, :utc_datetime_usec, public?: true)
    attribute(:recovery_verified_at, :utc_datetime_usec, public?: true)
    attribute(:cleared_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:active_restriction, [:principal_uid, :source, :reason],
      all_tenants?: true,
      where: expr(is_nil(cleared_at))
    )
  end

  actions do
    defaults([:read])

    create :restrict_in_tx do
      accept([:principal_uid, :source, :reason, :operation_id, :provider_time])
      change(set_attribute(:recovery_verified_at, nil))
    end

    update :repeat_restriction_in_tx do
      accept([:source, :reason, :operation_id, :provider_time])
      change(set_attribute(:recovery_verified_at, nil))
    end

    update :verify_recovery_in_tx do
      accept([:recovery_verified_at])
    end

    update :clear_in_tx do
      accept([:cleared_at])
    end
  end

  @type t :: %__MODULE__{}
end
