defmodule Ankole.AppConfigure.SiteOperations do
  @moduledoc "Registry setting operations for the site Console."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.AppConfigure.Site,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("site_app_configuration_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_list, :map do
      transaction?(false)

      constraints(
        fields: [
          app_configurations: [type: {:array, Ankole.AppConfigure.ConsoleItem}, allow_nil?: false]
        ]
      )

      run({Ankole.AppConfigure.ConsoleActions, scope: :global})
    end

    action :console_show, :map do
      transaction?(false)

      constraints(
        fields: [app_configuration: [type: Ankole.AppConfigure.ConsoleItem, allow_nil?: false]]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AppConfigure.ConsoleActions, scope: :global})
    end

    action :console_update, :map do
      transaction?(false)

      constraints(
        fields: [app_configuration: [type: Ankole.AppConfigure.ConsoleItem, allow_nil?: false]]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:value, Ankole.Ash.Types.JSONValue, sensitive?: true)
      run({Ankole.AppConfigure.ConsoleActions, scope: :global})
    end

    action :console_delete, :map do
      transaction?(false)

      constraints(
        fields: [app_configuration: [type: Ankole.AppConfigure.ConsoleItem, allow_nil?: false]]
      )

      argument(:key, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AppConfigure.ConsoleActions, scope: :global})
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
      run({Ankole.AppConfigure.ConsoleActions, scope: :global})
    end
  end
end
