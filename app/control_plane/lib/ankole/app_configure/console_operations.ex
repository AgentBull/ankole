defmodule Ankole.AppConfigure.ConsoleOperations do
  @moduledoc "Registry setting operations for the tenant Console."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.AppConfigure,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:key, :string)
    allow(:console_list, resource: "site_console:app_configurations", action: "read")
    allow(:console_show, resource: "site_console:app_configuration:{key}", action: "read")
    allow(:console_update, resource: "site_console:app_configuration:{key}", action: "update")
    allow(:console_delete, resource: "site_console:app_configuration:{key}", action: "reset")
    allow(:console_decrypt, resource: "site_console:app_configuration:{key}", action: "decrypt")

    allow(:console_update_group,
      resource: "site_console:app_configurations",
      action: "update",
      permissions: &Ankole.AppConfigure.Groups.permissions/4
    )

    allow(:console_agent_resolution,
      resource: "site_console:app_configuration:{key}",
      action: "read"
    )
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("app_configuration_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_update_group, :map do
      transaction?(false)

      constraints(
        fields: [
          app_configurations: [type: {:array, Ankole.AppConfigure.ConsoleItem}, allow_nil?: false]
        ]
      )

      argument(:group, :string, allow_nil?: false)
      argument(:values, :map, allow_nil?: false, default: %{}, sensitive?: true)
      argument(:reset_keys, {:array, :string}, allow_nil?: false, default: [])
      run({Ankole.AppConfigure.ConsoleActions, scope: :tenant})
    end

    action :console_agent_resolution, :map do
      transaction?(false)

      constraints(
        fields: [app_configuration: [type: Ankole.AppConfigure.ConsoleItem, allow_nil?: false]]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:agent_uid, :string, allow_nil?: false)
      run({Ankole.AppConfigure.ConsoleActions, scope: :tenant})
    end

    action :console_list, :map do
      transaction?(false)

      constraints(
        fields: [
          app_configurations: [type: {:array, Ankole.AppConfigure.ConsoleItem}, allow_nil?: false]
        ]
      )

      run({Ankole.AppConfigure.ConsoleActions, scope: :tenant})
    end

    action :console_show, :map do
      transaction?(false)

      constraints(
        fields: [app_configuration: [type: Ankole.AppConfigure.ConsoleItem, allow_nil?: false]]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AppConfigure.ConsoleActions, scope: :tenant})
    end

    action :console_update, :map do
      transaction?(false)

      constraints(
        fields: [app_configuration: [type: Ankole.AppConfigure.ConsoleItem, allow_nil?: false]]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:value, Ankole.Ash.Types.JSONValue, sensitive?: true)
      run({Ankole.AppConfigure.ConsoleActions, scope: :tenant})
    end

    action :console_delete, :map do
      transaction?(false)

      constraints(
        fields: [app_configuration: [type: Ankole.AppConfigure.ConsoleItem, allow_nil?: false]]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AppConfigure.ConsoleActions, scope: :tenant})
    end

    action :console_decrypt, :map do
      transaction?(false)

      constraints(
        fields: [
          decrypted_value: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                key: [type: :string, allow_nil?: false],
                value: [type: Ankole.Ash.Types.JSONValue]
              ]
            ]
          ]
        ]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AppConfigure.ConsoleActions, scope: :tenant})
    end
  end
end
