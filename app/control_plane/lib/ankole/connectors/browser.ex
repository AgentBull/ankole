defmodule Ankole.Connectors.Browser do
  @moduledoc "Typed tenant administration and personal connection operations."
  use Ankole.Ash.OperationResource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Connectors,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Ash.Types.{UUIDv7, JSONMap}

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("connector_operation")
  end

  authz do
    scope(:pod)
    allow(:catalog, check: :guardrail)
    allow(:connections, check: :guardrail)
    allow(:create_connection, check: :guardrail)
    allow(:update_connection, check: :guardrail)
    allow(:accounts, check: :guardrail)
    allow(:disconnect, check: :guardrail)
    allow(:oauth_begin, check: :guardrail)
    allow(:oauth_claim, check: :guardrail)
    allow(:triggers, check: :guardrail)
    allow(:create_trigger, check: :guardrail)
    allow(:retry_trigger, check: :guardrail)
    allow(:delete_trigger, check: :guardrail)
  end

  @connection_fields Ankole.Connectors.PublicSchema.connection_fields()
  @account_fields [
    id: [type: UUIDv7, allow_nil?: false],
    auth_config_id: [type: UUIDv7, allow_nil?: false],
    plugin_id: [type: :string, allow_nil?: false],
    subject_kind: [type: :string, allow_nil?: false],
    account_key: [type: :string, allow_nil?: false],
    owner_principal_uid: [type: :string],
    external_subject_id: [type: :string],
    granted_scopes: [type: {:array, :string}, allow_nil?: false],
    public_metadata: [type: JSONMap, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    expires_at: [type: :utc_datetime_usec],
    refresh_expires_at: [type: :utc_datetime_usec],
    last_error: [type: JSONMap],
    updated_at: [type: :utc_datetime_usec, allow_nil?: false]
  ]
  @trigger_fields [
    id: [type: UUIDv7, allow_nil?: false],
    auth_config_id: [type: UUIDv7, allow_nil?: false],
    connected_account_id: [type: UUIDv7],
    plugin_id: [type: :string, allow_nil?: false],
    trigger_type: [type: :string, allow_nil?: false],
    scope_key: [type: :string, allow_nil?: false],
    config: [type: JSONMap, allow_nil?: false],
    config_ref: [type: :string, allow_nil?: false],
    external_subscription_id: [type: :string],
    status: [type: :string, allow_nil?: false],
    last_error: [type: JSONMap],
    updated_at: [type: :utc_datetime_usec, allow_nil?: false]
  ]
  actions do
    action :catalog, :map do
      constraints(
        fields: [
          can_manage: [type: :boolean, allow_nil?: false],
          oauth_callback_url: [type: :string, allow_nil?: false],
          connectors: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: Ankole.Connectors.PublicSchema.catalog_fields()
              ]
            ]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :connections, :map do
      constraints(
        fields: [
          connections: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @connection_fields]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :create_connection, :map do
      constraints(
        fields: [
          connection: [type: :map, allow_nil?: false, constraints: [fields: @connection_fields]]
        ]
      )

      argument(:plugin_id, :string, allow_nil?: false)
      argument(:slug, :string, allow_nil?: false)
      argument(:display_name, :string)
      argument(:auth_scheme, :string, allow_nil?: false)
      argument(:is_default, :boolean)
      argument(:public_metadata, JSONMap)
      argument(:secret, JSONMap, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :update_connection, :map do
      constraints(
        fields: [
          connection: [type: :map, allow_nil?: false, constraints: [fields: @connection_fields]]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:slug, :string)
      argument(:display_name, :string)
      argument(:is_default, :boolean)
      argument(:public_metadata, JSONMap)
      argument(:secret, JSONMap)
      argument(:status, :string)
      run(__MODULE__.Actions)
    end

    action :accounts, :map do
      constraints(
        fields: [
          accounts: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @account_fields]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :disconnect, :map do
      constraints(
        fields: [account: [type: :map, allow_nil?: false, constraints: [fields: @account_fields]]]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :oauth_begin, :map do
      constraints(
        fields: [
          authorization_url: [type: :string, allow_nil?: false],
          expires_in: [type: :integer, allow_nil?: false]
        ]
      )

      argument(:connection, :string, allow_nil?: false)
      argument(:plugin_id, :string)
      argument(:subject_kind, :string)
      argument(:scopes, {:array, :string})
      argument(:return_to, :string)
      run(__MODULE__.Actions)
    end

    action :oauth_claim, :map do
      constraints(
        fields: [account: [type: :map, allow_nil?: false, constraints: [fields: @account_fields]]]
      )

      argument(:completion_code, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :triggers, :map do
      constraints(
        fields: [
          triggers: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @trigger_fields]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :create_trigger, :map do
      constraints(
        fields: [trigger: [type: :map, allow_nil?: false, constraints: [fields: @trigger_fields]]]
      )

      argument(:auth_config_id, UUIDv7, allow_nil?: false)
      argument(:connected_account_id, UUIDv7)
      argument(:trigger_type, :string, allow_nil?: false)
      argument(:scope_key, :string, allow_nil?: false)
      argument(:config, JSONMap)
      run(__MODULE__.Actions)
    end

    action :delete_trigger, :map do
      constraints(
        fields: [trigger: [type: :map, allow_nil?: false, constraints: [fields: @trigger_fields]]]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :retry_trigger, :map do
      constraints(
        fields: [trigger: [type: :map, allow_nil?: false, constraints: [fields: @trigger_fields]]]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      run(__MODULE__.Actions)
    end
  end
end
