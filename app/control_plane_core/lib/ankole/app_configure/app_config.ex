defmodule Ankole.AppConfigure.AppConfig do
  @moduledoc "One durable tenant configuration value under its natural scope and key."

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.AppConfigure.Domain,
    tenant_in_primary_key: true

  postgres do
    table("app_configurations")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(scope_key: "app_configurations_scope_key_unique")

    check_constraints do
      check_constraint(:scope, "app_configurations_scope_check")
      check_constraint(:value, "app_configurations_value_envelope_check")
    end
  end

  attributes do
    attribute(:scope, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false]
    )

    attribute(:key, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, match: ~r/\S/]
    )

    attribute(:value, Ankole.AppConfigure.Envelope,
      allow_nil?: false,
      public?: true,
      sensitive?: true
    )

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  identities do
    identity(:scope_key, [:scope, :key])
  end

  actions do
    defaults([:read])

    create :put do
      accept([:scope, :key])
      argument(:input, :term)
      transaction?(false)
      upsert?(true)
      upsert_identity(:scope_key)
      upsert_fields([:value, :updated_at])
      validate(present([:scope, :key]))
      validate(Ankole.AppConfigure.Scope)
      change(Ankole.AppConfigure.Changes.EncodeValue, only_when_valid?: true)
    end

    create :import_envelope do
      accept([:scope, :key, :value])
      transaction?(false)
      validate(Ankole.AppConfigure.Scope)
    end

    atomic_in_tx_update :record_platform_application do
      accept([])
      argument(:application, :string, constraints: [trim?: false])

      change(Ankole.AppConfigure.Changes.RecordPlatformApplication)
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}

  def for_scope("global"), do: Ankole.AppConfigure.SiteConfig
  def for_scope(_scope), do: __MODULE__
end
