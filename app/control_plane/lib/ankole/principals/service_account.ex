defmodule Ankole.Principals.ServiceAccount do
  @moduledoc """
  The service-account subtype of a `:system` Principal.

  Singleton service accounts (`system`, `ankole_brain`, `ankole_applets`),
  per-Applet service accounts (`svc_applet_<page_hex>`), and external IM bot
  service accounts (`bot_<provider>_<slug>`) store their kind, Applet page
  binding, and token-quota options in `service_accounts` while sharing the
  tenant's `principals` identity and AuthZ graph.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Principals

  postgres do
    table("service_accounts")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:uid, "service_accounts_principal_fkey"},
      {:applet_page_id, "service_accounts_applet_page_fkey"}
    ])

    unique_index_names([
      {[:tenant_id, :applet_page_id], "service_accounts_applet_page_uidx"}
    ])

    check_constraints do
      check_constraint(:kind, "service_accounts_kind_check")
      check_constraint(:options, "service_accounts_options_object")
      check_constraint(:applet_page_id, "service_accounts_applet_page_shape")
    end
  end

  attributes do
    attribute(:uid, Ankole.Ash.Types.PrincipalKey,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:kind, :atom,
      public?: true,
      allow_nil?: false,
      constraints: [one_of: [:brain, :applet, :external_bot, :platform]]
    )

    attribute(:applet_page_id, Ankole.Ash.Types.UUIDv7, public?: true)

    attribute(:options, Ankole.Ash.Types.JSONMap,
      public?: true,
      allow_nil?: false,
      default: %{}
    )

    timestamps(type: :utc_datetime_usec, public?: true)
  end

  relationships do
    belongs_to :principal, Ankole.Principals.Principal do
      source_attribute(:uid)
      destination_attribute(:uid)
      define_attribute?(false)
    end
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      upsert?(true)
      upsert_fields([:options])
      accept([:uid, :kind, :applet_page_id, :options])
    end

    update :options_in_tx do
      accept([:options])
    end

    destroy(:delete_in_tx)
  end
end
