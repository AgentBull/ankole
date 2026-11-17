defmodule Ankole.IdentityProviders.Console do
  @moduledoc "Typed Console transport for the identity-provider domain."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.IdentityProviders,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:provider_id, :provider_id)
    allow(:adapters, resource: "site_console:identity_provider_adapters", action: "read")
    allow(:providers, resource: "site_console:identity_providers", action: "read")

    allow(:save_provider,
      resource: "site_console:identity_provider:{provider_id}",
      action: "update"
    )

    allow(:create_provider,
      resource: "site_console:identity_provider:{provider_id}",
      action: "update"
    )

    allow(:run_sync, resource: "site_console:identity_provider:{provider_id}", action: "sync")
    allow(:directory, resource: "site_console:identity_provider:{provider_id}", action: "read")

    allow(:approve_directory,
      resource: "site_console:identity_provider:{provider_id}",
      action: "update"
    )

    allow(:review_event,
      resource: "site_console:identity_provider:{provider_id}",
      action: "update"
    )
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("identity_provider_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  @provider_fields [
    provider_id: [type: :string, allow_nil?: false],
    adapter_id: [type: :string, allow_nil?: false],
    plugin_id: [type: :string],
    config_key: [type: :string, allow_nil?: false],
    enabled: [type: :boolean, allow_nil?: false],
    display_name: [type: Ankole.Ash.Types.JSONMap],
    config: [type: Ankole.Ash.Types.JSONMap, allow_nil?: false],
    stored_secret_paths: [type: {:array, :string}, allow_nil?: false]
  ]
  @adapter_fields [
    adapter_id: [type: :string, allow_nil?: false],
    plugin_id: [type: :string],
    display_name: [type: Ankole.Ash.Types.JSONMap],
    capabilities: [type: {:array, :string}, allow_nil?: false],
    fields: [type: {:array, Ankole.Ash.Types.JSONMap}, allow_nil?: false],
    default_provider_id: [type: :string, allow_nil?: false]
  ]

  actions do
    action :adapters, :map do
      constraints(
        fields: [
          identity_provider_adapters: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @adapter_fields]]
          ]
        ]
      )

      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :providers, :map do
      constraints(
        fields: [
          identity_providers: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @provider_fields]]
          ]
        ]
      )

      transaction?(false)
      run(__MODULE__.Actions)
    end

    for operation <- [:create_provider, :save_provider] do
      action operation, :map do
        constraints(
          fields: [
            identity_provider: [
              type: :map,
              allow_nil?: false,
              constraints: [fields: @provider_fields]
            ]
          ]
        )

        argument(:provider_id, :string, allow_nil?: false)
        argument(:adapter_id, :string, allow_nil?: false)
        argument(:config, Ankole.Ash.Types.JSONMap, allow_nil?: false, sensitive?: true)
        argument(:enabled, :boolean, default: true)
        transaction?(false)
        run(__MODULE__.Actions)
      end
    end

    action :run_sync, :map do
      constraints(
        fields: [
          sync_run: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                provider_id: [type: :string, allow_nil?: false],
                status: [type: :string, allow_nil?: false],
                job_id: [type: :integer]
              ]
            ]
          ]
        ]
      )

      argument(:provider_id, :string, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :directory, Ankole.IdentityProviders.DirectoryView do
      argument(:provider_id, :string, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :approve_directory, Ankole.IdentityProviders.DirectoryView do
      argument(:provider_id, :string, allow_nil?: false)
      argument(:snapshot_fingerprint, :string, allow_nil?: false)
      argument(:reason, :string, allow_nil?: false, constraints: [min_length: 1])
      argument(:confirm_removals, :boolean, allow_nil?: false)
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :review_event, Ankole.IdentityProviders.DirectoryView do
      argument(:provider_id, :string, allow_nil?: false)
      argument(:event_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      argument(:action, :atom, allow_nil?: false, constraints: [one_of: [:retry, :dismiss]])
      argument(:reason, :string, allow_nil?: false, constraints: [min_length: 1])
      transaction?(false)
      run(__MODULE__.Actions)
    end
  end
end
