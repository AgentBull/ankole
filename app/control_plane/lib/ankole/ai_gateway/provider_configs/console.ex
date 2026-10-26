defmodule Ankole.AIGateway.ProviderConfigs.Console do
  @moduledoc "The HTTP actions for provider catalogs and ChatGPT sign-in."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.AIGateway.ProviderConfigs,
    data_layer: Ash.DataLayer.Simple,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:provider_id, :provider_id)
    allow(:models, resource: "site_console:ai_gateway_providers", action: "read")
    allow(:provider_kinds, resource: "site_console:ai_gateway_provider_kinds", action: "read")
    allow(:start, resource: "site_console:ai_gateway_provider:{provider_id}", action: "update")
    allow(:poll, resource: "site_console:ai_gateway_provider:{provider_id}", action: "update")
    allow(:complete, resource: "site_console:ai_gateway_provider:{provider_id}", action: "update")

    allow(:enterprise,
      resource: "site_console:ai_gateway_provider:{provider_id}",
      action: "update"
    )
  end

  @model_fields [
    provider_id: [type: :string, allow_nil?: false],
    model: [type: :string, allow_nil?: false],
    name: [type: :string, allow_nil?: false],
    description: [type: :string, allow_nil?: false],
    capability: [type: :string, allow_nil?: false],
    image_input: [type: :boolean, allow_nil?: false]
  ]

  @setting_fields [
    key: [type: :string, allow_nil?: false],
    type: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: ~w(boolean float integer map select string)a]
    ],
    default: [type: Ankole.Ash.Types.JSONValue],
    options: [type: {:array, :string}, allow_nil?: false],
    required: [type: :boolean, allow_nil?: false],
    encrypted: [type: :boolean, allow_nil?: false],
    advanced: [type: :boolean, allow_nil?: false],
    scope: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: ~w(connection credential request)a]
    ]
  ]

  @kind_fields [
    provider_kind: [type: :string, allow_nil?: false],
    label: [type: :map, allow_nil?: false],
    capabilities: [type: {:array, :string}, allow_nil?: false],
    default_base_url: [type: :string],
    settings: [
      type: {:array, :map},
      allow_nil?: false,
      constraints: [items: [fields: @setting_fields]]
    ]
  ]

  @login_fields [
    status: [type: :string],
    mode: [type: :string],
    verification_url: [type: :string],
    authorization_url: [type: :string],
    redirect_uri: [type: :string],
    user_code: [type: :string],
    interval: [type: :integer],
    retry_after: [type: :integer],
    expires_at: [type: :string],
    login_context: [type: :map],
    ai_gateway_provider: [type: :map]
  ]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("chatgpt_login")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :models, :map do
      transaction?(false)

      constraints(
        fields: [
          models: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @model_fields]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :provider_kinds, :map do
      transaction?(false)

      constraints(
        fields: [
          provider_kinds: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @kind_fields]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :start, :map do
      transaction?(false)
      constraints(fields: @login_fields)
      argument(:provider_id, :string, allow_nil?: false)
      argument(:id, :string)
      argument(:label, :string)
      argument(:priority, :integer)
      run(__MODULE__.Actions)
    end

    action :poll, :map do
      transaction?(false)
      constraints(fields: @login_fields)
      argument(:provider_id, :string, allow_nil?: false)
      argument(:login_context, :map, allow_nil?: false, sensitive?: true)
      run(__MODULE__.Actions)
    end

    action :complete, :map do
      transaction?(false)
      constraints(fields: @login_fields)
      argument(:provider_id, :string, allow_nil?: false)
      argument(:login_context, :map, allow_nil?: false, sensitive?: true)
      argument(:callback_url, :string, allow_nil?: false, sensitive?: true)
      run(__MODULE__.Actions)
    end

    action :enterprise, :map do
      transaction?(false)
      constraints(fields: [ai_gateway_provider: [type: :map, allow_nil?: false]])
      argument(:provider_id, :string, allow_nil?: false)
      argument(:credential, :map, allow_nil?: false, sensitive?: true)
      run(__MODULE__.Actions)
    end
  end
end
