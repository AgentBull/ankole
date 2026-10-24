defmodule Ankole.AIAgent.Console do
  @moduledoc "The Console actions for Agent model profiles and token quotas."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.AIAgent,
    data_layer: Ash.DataLayer.Simple,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:agent_uid, :principal_key)
    resolve_param(:profile, :model_profile)

    allow(:model_profiles,
      resource: "site_console:agent:{agent_uid}:model_profiles",
      action: "read"
    )

    allow(:put_model_profile,
      resource: "site_console:agent:{agent_uid}:model_profile:{profile}",
      action: "update"
    )

    allow(:delete_model_profile,
      resource: "site_console:agent:{agent_uid}:model_profile:{profile}",
      action: "delete"
    )

    allow(:put_provider_hosted,
      resource: "site_console:agent:{agent_uid}:model_profiles",
      action: "update"
    )

    allow(:token_quota, resource: "site_console:agent:{agent_uid}:token_quota", action: "read")

    allow(:put_token_quota,
      resource: "site_console:agent:{agent_uid}:token_quota",
      action: "update"
    )

    allow(:delete_token_quota,
      resource: "site_console:agent:{agent_uid}:token_quota",
      action: "delete"
    )

    allow(:reset_token_quota,
      resource: "site_console:agent:{agent_uid}:token_quota",
      action: "update"
    )
  end

  @provider_hosted_fields [
    web_search: [type: :boolean, allow_nil?: false],
    image_generate: [type: :boolean, allow_nil?: false]
  ]
  @profile_fields [
    provider_id: [type: :string],
    model: [type: :string],
    description: [type: :string],
    context_length: [type: :integer],
    provider_options: [type: :map]
  ]
  @quota_fields [
    period_days: [type: :integer, allow_nil?: false],
    period_start_at: [type: :string, allow_nil?: false],
    limit_tokens: [type: :integer, allow_nil?: false]
  ]
  @quota_status_fields [
    token_quota: [type: :map, constraints: [fields: @quota_fields]],
    usage: [
      type: :map,
      constraints: [
        fields: [
          window_started_at: [type: :utc_datetime_usec, allow_nil?: false],
          window_ends_at: [type: :utc_datetime_usec, allow_nil?: false],
          used_tokens: [type: :integer, allow_nil?: false],
          exceeded: [type: :boolean, allow_nil?: false]
        ]
      ]
    ]
  ]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("agent_model_configuration")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :model_profiles, :map do
      transaction?(false)

      constraints(
        fields: [
          model_profiles: [type: :map, allow_nil?: false],
          provider_hosted: [
            type: :map,
            allow_nil?: false,
            constraints: [fields: @provider_hosted_fields]
          ]
        ]
      )

      argument(:agent_uid, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :put_model_profile, :map do
      transaction?(false)

      constraints(
        fields: [
          model_profile: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields:
                @profile_fields ++
                  [
                    profile: [type: :string, allow_nil?: false],
                    configured: [type: :boolean, allow_nil?: false]
                  ]
            ]
          ]
        ]
      )

      argument(:agent_uid, :string, allow_nil?: false)
      argument(:profile, :string, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false, constraints: [fields: @profile_fields])
      run(__MODULE__.Actions)
    end

    action :delete_model_profile, :map do
      transaction?(false)

      constraints(
        fields: [
          model_profile: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields:
                @profile_fields ++
                  [
                    profile: [type: :string, allow_nil?: false],
                    configured: [type: :boolean, allow_nil?: false]
                  ]
            ]
          ]
        ]
      )

      argument(:agent_uid, :string, allow_nil?: false)
      argument(:profile, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :put_provider_hosted, :map do
      transaction?(false)

      constraints(
        fields: [
          provider_hosted: [
            type: :map,
            allow_nil?: false,
            constraints: [fields: @provider_hosted_fields]
          ]
        ]
      )

      argument(:agent_uid, :string, allow_nil?: false)
      argument(:web_search, :boolean)
      argument(:image_generate, :boolean)
      run(__MODULE__.Actions)
    end

    action :token_quota, :map do
      transaction?(false)
      constraints(fields: @quota_status_fields)
      argument(:agent_uid, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :put_token_quota, :map do
      transaction?(false)
      constraints(fields: @quota_status_fields)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:period_days, :integer, allow_nil?: false)
      argument(:period_start_at, :string)
      argument(:limit_tokens, :integer, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :delete_token_quota, :map do
      transaction?(false)
      constraints(fields: @quota_status_fields)
      argument(:agent_uid, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :reset_token_quota, :map do
      transaction?(false)
      constraints(fields: @quota_status_fields)
      argument(:agent_uid, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end
  end
end
