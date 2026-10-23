defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialPoolEntry do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayCredentialPoolEntry",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        label: %Schema{type: :string},
        source: %Schema{type: :string},
        priority: %Schema{type: :integer},
        disabled_at: %Schema{type: :string, nullable: true},
        credential_present: %Schema{type: :boolean},
        status: %Schema{type: :string, enum: ~w(ok exhausted dead disabled)},
        retry_at: %Schema{type: :string, nullable: true},
        request_count: %Schema{type: :integer},
        rate_limits: %Schema{type: :object, additionalProperties: true},
        usage: %Schema{type: :object, additionalProperties: true},
        last_selected_at: %Schema{type: :string, nullable: true},
        last_error_code: %Schema{type: :string, nullable: true},
        last_error_reason: %Schema{type: :string, nullable: true},
        last_error_message: %Schema{type: :string, nullable: true},
        provider_status: %Schema{type: :integer, nullable: true},
        reauth_required: %Schema{type: :boolean},
        account_id: %Schema{type: :string, nullable: true},
        plan_type: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string, nullable: true},
        last_refresh: %Schema{type: :string, nullable: true},
        auth_type: %Schema{type: :string, nullable: true}
      },
      required: [
        :id,
        :label,
        :source,
        :priority,
        :disabled_at,
        :credential_present,
        :status,
        :request_count,
        :rate_limits,
        :usage,
        :last_selected_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialPool do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialPoolEntry

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayCredentialPool",
      type: :object,
      properties: %{
        strategy: %Schema{
          type: :string,
          enum: ~w(fill_first round_robin least_used random)
        },
        entries: %Schema{type: :array, items: AIGatewayCredentialPoolEntry}
      },
      required: [:strategy, :entries],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayModelCatalogEntry do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayModelCatalogEntry",
      type: :object,
      properties: %{
        provider_id: %Schema{type: :string},
        model: %Schema{type: :string},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        capability: %Schema{type: :string, enum: ~w(llm embedding rerank image_generate other)},
        image_input: %Schema{type: :boolean}
      },
      required: [:provider_id, :model, :name, :description, :capability, :image_input],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayModelCatalogResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayModelCatalogEntry

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayModelCatalogResponse",
      type: :object,
      properties: %{models: %Schema{type: :array, items: AIGatewayModelCatalogEntry}},
      required: [:models],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialPool

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayProviderItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        provider_id: %Schema{type: :string},
        provider_kind: %Schema{type: :string},
        base_url: %Schema{type: :string, nullable: true},
        connection_options: %Schema{type: :object, additionalProperties: true},
        credential_pool: AIGatewayCredentialPool,
        disabled_at: %Schema{type: :string, nullable: true},
        provider_metadata: %Schema{type: :object, additionalProperties: true}
      },
      required: [
        :id,
        :provider_id,
        :provider_kind,
        :connection_options,
        :credential_pool,
        :provider_metadata
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayProviderResponse",
      type: :object,
      properties: %{
        ai_gateway_provider: AIGatewayProviderItem
      },
      required: [:ai_gateway_provider],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayCredentialWriteRequest",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        label: %Schema{type: :string},
        priority: %Schema{type: :integer},
        disabled_at: %Schema{type: :string, nullable: true}
      },
      additionalProperties: true
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayCredentialStrategyWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayCredentialStrategyWriteRequest",
      type: :object,
      properties: %{
        strategy: %Schema{
          type: :string,
          enum: ~w(fill_first round_robin least_used random)
        }
      },
      required: [:strategy],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginStartRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayChatGPTLoginStartRequest",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        label: %Schema{type: :string},
        priority: %Schema{type: :integer}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginPollRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayChatGPTLoginPollRequest",
      type: :object,
      properties: %{
        login_context: %Schema{type: :object, additionalProperties: true}
      },
      required: [:login_context],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTBrowserLoginRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayChatGPTBrowserLoginRequest",
      type: :object,
      properties: %{
        login_context: %Schema{type: :object, additionalProperties: true},
        callback_url: %Schema{type: :string}
      },
      required: [:login_context, :callback_url],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTEnterpriseCredentialRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayChatGPTEnterpriseCredentialRequest",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        label: %Schema{type: :string},
        priority: %Schema{type: :integer},
        access_token: %Schema{type: :string},
        account_id: %Schema{type: :string},
        plan_type: %Schema{type: :string},
        email: %Schema{type: :string},
        fedramp: %Schema{type: :boolean}
      },
      required: [:access_token, :account_id],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayChatGPTLoginResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayChatGPTLoginResponse",
      type: :object,
      additionalProperties: true
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderKindItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  defmodule Setting do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayProviderSetting",
        type: :object,
        properties: %{
          key: %Schema{type: :string},
          type: %Schema{
            type: :string,
            enum: ["boolean", "float", "integer", "map", "select", "string"]
          },
          default: JSONValue,
          options: %Schema{type: :array, items: %Schema{type: :string}},
          required: %Schema{type: :boolean},
          encrypted: %Schema{type: :boolean},
          advanced: %Schema{type: :boolean},
          scope: %Schema{type: :string, enum: ["connection", "credential", "request"]}
        },
        required: [:key, :type, :default, :options, :required, :encrypted, :advanced, :scope],
        additionalProperties: false
      },
      struct?: false
    )
  end

  OpenAPISpex.schema(
    %{
      title: "AIGatewayProviderKindItem",
      type: :object,
      properties: %{
        provider_kind: %Schema{type: :string},
        label: %Schema{type: :object, additionalProperties: %Schema{type: :string}},
        capabilities: %Schema{type: :array, items: %Schema{type: :string}},
        default_base_url: %Schema{type: :string, nullable: true},
        settings: %Schema{
          type: :array,
          items: Setting
        }
      },
      required: [
        :provider_kind,
        :label,
        :capabilities,
        :default_base_url,
        :settings
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderKindListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayProviderKindItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayProviderKindListResponse",
      type: :object,
      properties: %{
        provider_kinds: %Schema{type: :array, items: AIGatewayProviderKindItem}
      },
      required: [:provider_kinds],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedCapabilities do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ProviderHostedCapabilities",
      description:
        "Capabilities the Agent leaves to its language-model Provider. " <>
          "A capability set to true declares no Ankole tool or capability " <>
          "profile, and the Agent has no such capability when its Provider " <>
          "cannot run it.",
      type: :object,
      properties: %{
        web_search: %Schema{type: :boolean},
        image_generate: %Schema{type: :boolean}
      },
      required: [:web_search, :image_generate],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ProviderHostedWriteRequest",
      description: "Sets any of the capability switches. Omitted keys stay unchanged.",
      type: :object,
      properties: %{
        web_search: %Schema{type: :boolean},
        image_generate: %Schema{type: :boolean}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedCapabilities

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ProviderHostedResponse",
      type: :object,
      properties: %{provider_hosted: ProviderHostedCapabilities},
      required: [:provider_hosted],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ModelProfilesResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ProviderHostedCapabilities

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ModelProfilesResponse",
      type: :object,
      properties: %{
        model_profiles: %Schema{type: :object, additionalProperties: true},
        provider_hosted: ProviderHostedCapabilities
      },
      required: [:model_profiles, :provider_hosted],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ModelProfileResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ModelProfileResponse",
      type: :object,
      properties: %{
        model_profile: %Schema{type: :object, additionalProperties: true}
      },
      required: [:model_profile],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ModelProfileWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ModelProfileWriteRequest",
      type: :object,
      properties: %{
        provider_id: %Schema{type: :string},
        model: %Schema{type: :string},
        description: %Schema{type: :string, maxLength: 200},
        context_length: %Schema{type: :integer, minimum: 1},
        provider_options: %Schema{type: :object, additionalProperties: true}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.TokenQuota do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "TokenQuota",
      type: :object,
      properties: %{
        period_days: %Schema{type: :integer, minimum: 1},
        period_start_at: %Schema{type: :string},
        limit_tokens: %Schema{type: :integer, minimum: 1}
      },
      required: [:period_days, :period_start_at, :limit_tokens],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.TokenQuotaUsage do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "TokenQuotaUsage",
      type: :object,
      properties: %{
        window_started_at: %Schema{type: :string},
        window_ends_at: %Schema{type: :string},
        used_tokens: %Schema{type: :integer},
        exceeded: %Schema{type: :boolean}
      },
      required: [:window_started_at, :window_ends_at, :used_tokens, :exceeded],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.TokenQuotaResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.TokenQuota
  alias AnkoleWeb.Schemas.ConsoleAPI.TokenQuotaUsage

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "TokenQuotaResponse",
      type: :object,
      properties: %{
        token_quota: %Schema{oneOf: [TokenQuota], nullable: true},
        usage: %Schema{oneOf: [TokenQuotaUsage], nullable: true}
      },
      required: [:token_quota, :usage],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.TokenQuotaWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "TokenQuotaWriteRequest",
      type: :object,
      properties: %{
        period_days: %Schema{type: :integer, minimum: 1},
        period_start_at: %Schema{type: :string},
        limit_tokens: %Schema{type: :integer, minimum: 1}
      },
      required: [:period_days, :limit_tokens],
      additionalProperties: false
    },
    struct?: false
  )
end
