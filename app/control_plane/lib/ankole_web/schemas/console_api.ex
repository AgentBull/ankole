defmodule AnkoleWeb.Schemas.ConsoleApi do
  @moduledoc """
  OpenAPI schemas for the console REST API.
  """

  alias OpenApiSpex.Schema

  defmodule JsonValue do
    @moduledoc """
    Any JSON-compatible value.
    """

    @behaviour OpenApiSpex.Schema

    # Deliberately untyped: each AppConfigure key has its own value schema, which
    # the context enforces. Constraining the type here would force a single shape
    # across every key, so the wire schema stays open and validation lives downstream.
    @impl OpenApiSpex.Schema
    def schema do
      %Schema{
        title: "JsonValue",
        nullable: true,
        description: "Any JSON-compatible value. AppConfigure validates the concrete key schema."
      }
    end
  end

  defmodule LocalizedText do
    @moduledoc """
    Locale-keyed operator-facing text with a required default fallback.
    """

    @behaviour OpenApiSpex.Schema

    @impl OpenApiSpex.Schema
    def schema do
      %Schema{
        title: "LocalizedText",
        type: :object,
        properties: %{
          default: %Schema{type: :string}
        },
        required: [:default],
        additionalProperties: %Schema{type: :string}
      }
    end
  end

  defmodule ErrorDetail do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConsoleApiErrorDetail",
        type: :object,
        properties: %{
          path: %Schema{type: :string, nullable: true},
          message: %Schema{type: :string}
        },
        required: [:message],
        additionalProperties: true
      },
      struct?: false
    )
  end

  defmodule ErrorObject do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConsoleApiError",
        type: :object,
        properties: %{
          code: %Schema{type: :string},
          message: %Schema{type: :string},
          details: %Schema{type: :array, items: ErrorDetail, nullable: true}
        },
        required: [:code, :message],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ErrorEnvelope do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConsoleApiErrorEnvelope",
        type: :object,
        properties: %{
          error: ErrorObject
        },
        required: [:error],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AuthSessionDeleteResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AuthSessionDeleteResponse",
        type: :object,
        properties: %{
          ok: %Schema{type: :boolean}
        },
        required: [:ok],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleTokenRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConsoleTokenRequest",
        type: :object,
        properties: %{
          grant_type: %Schema{type: :string},
          refresh_token: %Schema{type: :string}
        },
        required: [:grant_type],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleTokenResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConsoleTokenResponse",
        type: :object,
        properties: %{
          access_token: %Schema{type: :string},
          expires_in: %Schema{type: :integer},
          refresh_token: %Schema{type: :string},
          refresh_token_expires_in: %Schema{type: :integer},
          scope: %Schema{type: :string},
          token_type: %Schema{type: :string, enum: ["Bearer"]}
        },
        required: [
          :access_token,
          :expires_in,
          :refresh_token,
          :refresh_token_expires_in,
          :scope,
          :token_type
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule OAuthErrorResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "OAuthErrorResponse",
        type: :object,
        properties: %{
          error: %Schema{type: :string},
          error_description: %Schema{type: :string}
        },
        required: [:error, :error_description],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AgentItem",
        type: :object,
        properties: %{
          uid: %Schema{type: :string},
          status: %Schema{type: :string, enum: ["active", "disabled"]},
          display_name: %Schema{type: :string, nullable: true},
          avatar_url: %Schema{type: :string, nullable: true},
          type: %Schema{type: :string, enum: ["ai_colleague"]},
          role: %Schema{type: :string},
          options: %Schema{type: :object, additionalProperties: true},
          created_by_principal_uid: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [
          :uid,
          :status,
          :type,
          :role,
          :options,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AgentListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: AgentItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AgentResponse",
        type: :object,
        properties: %{
          data: AgentItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentCreateRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AgentCreateRequest",
        type: :object,
        properties: %{
          uid: %Schema{type: :string},
          display_name: %Schema{type: :string, nullable: true},
          avatar_url: %Schema{type: :string, nullable: true},
          role: %Schema{type: :string},
          options: %Schema{type: :object, additionalProperties: true}
        },
        required: [:uid, :role],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentUpdateRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AgentUpdateRequest",
        type: :object,
        properties: %{
          display_name: %Schema{type: :string, nullable: true},
          avatar_url: %Schema{type: :string, nullable: true},
          role: %Schema{type: :string},
          options: %Schema{type: :object, additionalProperties: true}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AppConfigurationItem do
    @moduledoc false

    require OpenApiSpex

    # One AppConfigure entry as the console sees it. The shape reflects the
    # registry model: `kind` distinguishes exact keys from pattern keys and their
    # materialized instances; `source`/`overridden`/`default_present` describe
    # whether the effective value comes from the compiled default or a global
    # override; `encrypted`/`editable` drive what the UI may show or change.
    OpenApiSpex.schema(
      %{
        title: "AppConfigurationItem",
        type: :object,
        properties: %{
          key: %Schema{type: :string},
          kind: %Schema{
            type: :string,
            enum: ["exact", "pattern", "pattern_concrete"]
          },
          pattern: %Schema{type: :string, nullable: true},
          pattern_id: %Schema{type: :string, nullable: true},
          description: %Schema{type: :string, nullable: true},
          encrypted: %Schema{type: :boolean},
          scope: %Schema{type: :string, enum: ["scoped", "global"]},
          editable: %Schema{type: :boolean},
          default_present: %Schema{type: :boolean},
          overridden: %Schema{type: :boolean},
          present: %Schema{type: :boolean},
          source: %Schema{
            type: :string,
            enum: ["default", "global", "missing", "pattern", "error"]
          },
          value: JsonValue,
          error: %Schema{type: :string, nullable: true}
        },
        required: [
          :key,
          :kind,
          :encrypted,
          :scope,
          :editable,
          :default_present,
          :overridden,
          :present,
          :source
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AppConfigurationListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AppConfigurationListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: AppConfigurationItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AppConfigurationResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AppConfigurationResponse",
        type: :object,
        properties: %{
          data: AppConfigurationItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AppConfigurationUpdateRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AppConfigurationUpdateRequest",
        type: :object,
        properties: %{
          value: JsonValue
        },
        required: [:value],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AppConfigurationDecryptionValue do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AppConfigurationDecryptionValue",
        type: :object,
        properties: %{
          key: %Schema{type: :string},
          value: JsonValue
        },
        required: [:key, :value],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AppConfigurationDecryptionResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AppConfigurationDecryptionResponse",
        type: :object,
        properties: %{
          data: AppConfigurationDecryptionValue
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalAdapterFieldOption do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalAdapterFieldOption",
        type: :object,
        properties: %{
          value: %Schema{type: :string},
          label: LocalizedText,
          description: LocalizedText
        },
        required: [:value],
        additionalProperties: true
      },
      struct?: false
    )
  end

  defmodule SignalAdapterField do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalAdapterField",
        type: :object,
        properties: %{
          path: %Schema{type: :string},
          type: %Schema{type: :string},
          label: LocalizedText,
          description: LocalizedText,
          default: JsonValue,
          advanced: %Schema{type: :boolean},
          required: %Schema{type: :boolean, nullable: true},
          encrypted: %Schema{type: :boolean, nullable: true},
          min: %Schema{type: :integer, nullable: true},
          max: %Schema{type: :integer, nullable: true},
          options: %Schema{type: :array, items: SignalAdapterFieldOption, nullable: true}
        },
        required: [:path, :type],
        additionalProperties: true
      },
      struct?: false
    )
  end

  defmodule SignalAdapterItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalAdapterItem",
        type: :object,
        properties: %{
          adapter_id: %Schema{type: :string},
          plugin_id: %Schema{type: :string, nullable: true},
          display_name: LocalizedText,
          fields: %Schema{type: :array, items: SignalAdapterField},
          group_message_mode_field: SignalAdapterField
        },
        required: [:adapter_id, :fields, :group_message_mode_field],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalAdapterListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalAdapterListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: SignalAdapterItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderAdapterItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderAdapterItem",
        type: :object,
        properties: %{
          adapter_id: %Schema{type: :string},
          plugin_id: %Schema{type: :string, nullable: true},
          display_name: LocalizedText,
          capabilities: %Schema{type: :array, items: %Schema{type: :string}},
          fields: %Schema{type: :array, items: SignalAdapterField},
          default_provider_id: %Schema{type: :string}
        },
        required: [:adapter_id, :capabilities, :fields, :default_provider_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderAdapterListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderAdapterListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: IdentityProviderAdapterItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderItem",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          adapter_id: %Schema{type: :string},
          plugin_id: %Schema{type: :string},
          config_key: %Schema{type: :string},
          enabled: %Schema{type: :boolean},
          config: JsonValue
        },
        required: [:provider_id, :adapter_id, :plugin_id, :config_key, :enabled, :config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: IdentityProviderItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderResponse",
        type: :object,
        properties: %{
          data: IdentityProviderItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderWriteRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderWriteRequest",
        type: :object,
        properties: %{
          adapter_id: %Schema{type: :string},
          config: JsonValue,
          enabled: %Schema{type: :boolean}
        },
        required: [:adapter_id, :config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderSyncRunItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderSyncRunItem",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          status: %Schema{type: :string, enum: ["enqueued"]},
          job_id: %Schema{type: :integer, nullable: true}
        },
        required: [:provider_id, :status],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderSyncRunResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "IdentityProviderSyncRunResponse",
        type: :object,
        properties: %{
          data: IdentityProviderSyncRunItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingWriteRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalBindingWriteRequest",
        type: :object,
        properties: %{
          config: JsonValue,
          group_message_mode: %Schema{
            type: :string,
            enum: ["addressed_only", "observe_all", "may_intervene"],
            nullable: true
          }
        },
        required: [:config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalBindingItem",
        type: :object,
        properties: %{
          agent_uid: %Schema{type: :string},
          name: %Schema{type: :string},
          adapter: %Schema{type: :string},
          config_ref: %Schema{type: :string},
          config_key: %Schema{type: :string},
          unaddressed_group_message_policy: %Schema{
            type: :string,
            enum: ["ignore", "record_only", "may_intervene"]
          },
          enabled: %Schema{type: :boolean},
          unavailable_reason: %Schema{type: :string, nullable: true}
        },
        required: [
          :agent_uid,
          :name,
          :adapter,
          :config_ref,
          :config_key,
          :unaddressed_group_message_policy,
          :enabled
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalBindingResponse",
        type: :object,
        properties: %{
          data: SignalBindingItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SignalBindingListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: SignalBindingItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronWriteRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ScheduleCronWriteRequest",
        type: :object,
        properties: %{
          binding_name: %Schema{type: :string},
          name: %Schema{type: :string, nullable: true},
          status: %Schema{type: :string, enum: ["active", "paused"], nullable: true},
          schedule: JsonValue,
          timezone: %Schema{type: :string, nullable: true},
          payload: JsonValue,
          delivery: JsonValue,
          idempotency_key: %Schema{type: :string},
          failure_policy: JsonValue
        },
        required: [:binding_name, :schedule, :delivery, :idempotency_key],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronUpdateRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ScheduleCronUpdateRequest",
        type: :object,
        properties: %{
          name: %Schema{type: :string, nullable: true},
          schedule: JsonValue,
          timezone: %Schema{type: :string, nullable: true},
          payload: JsonValue,
          delivery: JsonValue,
          failure_policy: JsonValue
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronScheduleResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ScheduleCronScheduleResponse",
        type: :object,
        properties: %{data: JsonValue},
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronScheduleListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ScheduleCronScheduleListResponse",
        type: :object,
        properties: %{data: %Schema{type: :array, items: JsonValue}},
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleEventResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ScheduleEventResponse",
        type: :object,
        properties: %{data: JsonValue},
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleEventListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ScheduleEventListResponse",
        type: :object,
        properties: %{data: %Schema{type: :array, items: JsonValue}},
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderEncryptedOptionProjection do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AIGatewayProviderEncryptedOptionProjection",
        type: :object,
        properties: %{
          present: %Schema{type: :boolean},
          masked: %Schema{type: :string, nullable: true}
        },
        required: [:present],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderEncryptedOptionsProjection do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AIGatewayProviderEncryptedOptionsProjection",
        type: :object,
        additionalProperties: AIGatewayProviderEncryptedOptionProjection
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AIGatewayProviderItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          provider_id: %Schema{type: :string},
          provider_kind: %Schema{type: :string},
          base_url: %Schema{type: :string, nullable: true},
          connection_options: %Schema{type: :object, additionalProperties: true},
          encrypted_options: AIGatewayProviderEncryptedOptionsProjection,
          disabled_at: %Schema{type: :string, nullable: true},
          provider_metadata: %Schema{type: :object, additionalProperties: true}
        },
        required: [
          :id,
          :provider_id,
          :provider_kind,
          :connection_options,
          :encrypted_options,
          :provider_metadata
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AIGatewayProviderListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: AIGatewayProviderItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AIGatewayProviderResponse",
        type: :object,
        properties: %{
          data: AIGatewayProviderItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderWriteRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AIGatewayProviderWriteRequest",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          provider_kind: %Schema{type: :string},
          base_url: %Schema{type: :string, nullable: true},
          connection_options: %Schema{type: :object, additionalProperties: true}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderKindItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
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
            items: %Schema{type: :object, additionalProperties: true}
          },
          capability_specs: %Schema{
            type: :array,
            items: %Schema{type: :object, additionalProperties: true}
          },
          connection_options: %Schema{type: :array, items: %Schema{type: :string}},
          runtime_provider_options: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [
          :provider_kind,
          :label,
          :capabilities,
          :default_base_url,
          :settings,
          :capability_specs,
          :connection_options,
          :runtime_provider_options
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderKindListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AIGatewayProviderKindListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: AIGatewayProviderKindItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ModelProfilesResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ModelProfilesResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :object, additionalProperties: true}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ModelProfileResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ModelProfileResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :object, additionalProperties: true}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ModelProfileWriteRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ModelProfileWriteRequest",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          model: %Schema{type: :string},
          context_length: %Schema{type: :integer, minimum: 1},
          provider_options: %Schema{type: :object, additionalProperties: true}
        },
        required: [:provider_id, :model],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentComputerWorkerItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AgentComputerWorkerItem",
        type: :object,
        properties: %{
          worker_id: %Schema{type: :string},
          status: %Schema{
            type: :string,
            enum: ["ready", "stale", "draining", "stopped"]
          },
          version: %Schema{type: :string},
          capacity: %Schema{type: :object, additionalProperties: true},
          load: %Schema{type: :object, additionalProperties: true},
          last_worker_heartbeat_at: %Schema{type: :string, nullable: true},
          started_at: %Schema{type: :string, nullable: true},
          stopped_at: %Schema{type: :string, nullable: true},
          stop_reason: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [
          :worker_id,
          :status,
          :version,
          :capacity,
          :load,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentComputerWorkerListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "AgentComputerWorkerListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: AgentComputerWorkerItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileEntry do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileEntry",
        type: :object,
        properties: %{
          relative_path: %Schema{type: :string},
          kind: %Schema{type: :string, enum: ["file", "directory", "other"]},
          size: %Schema{type: :integer},
          modified_unix_ms: %Schema{type: :integer}
        },
        required: [:relative_path, :kind, :size, :modified_unix_ms],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileListData do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileListData",
        type: :object,
        properties: %{
          root: %Schema{
            type: :string,
            enum: ["workspace_sessions", "user_files", "agent_installed_skills"]
          },
          path: %Schema{type: :string},
          entries: %Schema{type: :array, items: WorkerFileEntry},
          truncated: %Schema{type: :boolean}
        },
        required: [:root, :path, :entries, :truncated],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileListResponse",
        type: :object,
        properties: %{
          data: WorkerFileListData
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileUploadRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileUploadRequest",
        type: :object,
        properties: %{
          root: %Schema{
            type: :string,
            enum: ["workspace_sessions", "user_files", "agent_installed_skills"]
          },
          path: %Schema{type: :string},
          file: %Schema{type: :string, format: :binary}
        },
        required: [:root, :path, :file],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileUploadResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileUploadResponse",
        type: :object,
        properties: %{
          data: %Schema{
            type: :object,
            properties: %{
              root: %Schema{
                type: :string,
                enum: ["workspace_sessions", "user_files", "agent_installed_skills"]
              },
              relative_path: %Schema{type: :string},
              size: %Schema{type: :integer},
              xxh3_128: %Schema{type: :string, nullable: true}
            },
            required: [:root, :relative_path, :size],
            additionalProperties: false
          }
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileMoveRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileMoveRequest",
        type: :object,
        properties: %{
          root: %Schema{
            type: :string,
            enum: ["workspace_sessions", "user_files", "agent_installed_skills"]
          },
          from_path: %Schema{type: :string},
          to_path: %Schema{type: :string},
          overwrite: %Schema{type: :boolean}
        },
        required: [:root, :from_path, :to_path],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileMoveResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileMoveResponse",
        type: :object,
        properties: %{
          data: %Schema{
            type: :object,
            properties: %{
              root: %Schema{
                type: :string,
                enum: ["workspace_sessions", "user_files", "agent_installed_skills"]
              },
              from_relative_path: %Schema{type: :string},
              to_relative_path: %Schema{type: :string},
              moved: %Schema{type: :boolean}
            },
            required: [:root, :from_relative_path, :to_relative_path, :moved],
            additionalProperties: false
          }
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileDeleteResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkerFileDeleteResponse",
        type: :object,
        properties: %{
          data: %Schema{
            type: :object,
            properties: %{
              root: %Schema{
                type: :string,
                enum: ["workspace_sessions", "user_files", "agent_installed_skills"]
              },
              relative_path: %Schema{type: :string},
              deleted: %Schema{type: :boolean}
            },
            required: [:root, :relative_path, :deleted],
            additionalProperties: false
          }
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SubagentDelegationEventItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SubagentDelegationEventItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          seq: %Schema{type: :integer},
          direction: %Schema{type: :string},
          event_type: %Schema{type: :string},
          payload: %Schema{type: :object, additionalProperties: true},
          redaction: %Schema{type: :object, additionalProperties: true},
          occurred_at: %Schema{type: :string}
        },
        required: [:id, :seq, :direction, :event_type, :payload, :redaction, :occurred_at],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SubagentDelegationItem do
    @moduledoc false

    require OpenApiSpex

    @statuses Ankole.SubagentDelegations.Schemas.Delegation.statuses()

    OpenApiSpex.schema(
      %{
        title: "SubagentDelegationItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          agent_uid: %Schema{type: :string},
          session_id: %Schema{type: :string},
          runtime: %Schema{type: :string, enum: ["codex"]},
          runtime_thread_id: %Schema{type: :string, nullable: true},
          title: %Schema{type: :string, nullable: true},
          prompt: %Schema{type: :string, nullable: true},
          status: %Schema{
            type: :string,
            enum: @statuses
          },
          attempts: %Schema{type: :integer},
          workdir: %Schema{type: :string, nullable: true},
          reply_route: %Schema{type: :object, additionalProperties: true},
          result: %Schema{type: :object, additionalProperties: true},
          error: %Schema{type: :object, additionalProperties: true},
          metadata: %Schema{type: :object, additionalProperties: true},
          duration_seconds: %Schema{type: :integer},
          queued_at: %Schema{type: :string, nullable: true},
          started_at: %Schema{type: :string, nullable: true},
          completed_at: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string},
          events: %Schema{type: :array, items: SubagentDelegationEventItem}
        },
        required: [
          :id,
          :agent_uid,
          :session_id,
          :runtime,
          :status,
          :attempts,
          :reply_route,
          :result,
          :error,
          :metadata,
          :duration_seconds,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SubagentDelegationListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SubagentDelegationListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: SubagentDelegationItem},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:data, :next_cursor],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SubagentDelegationResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SubagentDelegationResponse",
        type: :object,
        properties: %{
          data: SubagentDelegationItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
