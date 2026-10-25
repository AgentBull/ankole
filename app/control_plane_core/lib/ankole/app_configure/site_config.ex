defmodule Ankole.AppConfigure.SiteConfig do
  @moduledoc "One durable site configuration value under its natural scope and key."

  use Ankole.Ash.Resource,
    tenancy: :site,
    domain: Ankole.AppConfigure

  postgres do
    table("site_app_configurations")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(scope_key: "site_app_configurations_scope_key_unique")

    check_constraints do
      check_constraint(:scope, "site_app_configurations_scope_check")
      check_constraint(:value, "site_app_configurations_value_envelope_check")
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
      upsert?(true)
      upsert_identity(:scope_key)
      upsert_fields([:value, :updated_at])
      validate(present([:scope, :key]))
      validate(Ankole.AppConfigure.Scope)
      change(Ankole.AppConfigure.Changes.EncodeValue, only_when_valid?: true)
    end

    update :record_platform_application do
      require_atomic?(true)
      accept([])
      argument(:application, :string, constraints: [trim?: false])

      change(
        atomic_update(
          :value,
          expr(
            fragment(
              "? || jsonb_build_object('platform_application', ?::text)",
              value,
              ^arg(:application)
            )
          )
        )
      )
    end

    destroy :remove do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
