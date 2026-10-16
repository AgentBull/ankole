defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterFieldOption do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalizedText

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
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

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterFieldRequirement do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalAdapterFieldRequirement",
      type: :object,
      properties: %{
        path: %Schema{type: :string},
        value: JSONValue
      },
      required: [:path, :value],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterPatternValidation do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalizedText

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalAdapterPatternValidation",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: ["pattern"]},
        message: LocalizedText,
        pattern: %Schema{type: :string}
      },
      required: [:kind, :message, :pattern],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterJSONObjectValidation do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalizedText

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalAdapterJSONObjectValidation",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: ["json_object"]},
        message: LocalizedText,
        requiredStringProperties: %Schema{type: :array, items: %Schema{type: :string}},
        stringPrefixes: %Schema{type: :object, additionalProperties: %Schema{type: :string}}
      },
      required: [:kind, :message],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterField do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalizedText
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterFieldOption
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterFieldRequirement
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterJSONObjectValidation
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterPatternValidation

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalAdapterField",
      type: :object,
      properties: %{
        path: %Schema{type: :string},
        type: %Schema{type: :string},
        label: LocalizedText,
        description: LocalizedText,
        default: JSONValue,
        advanced: %Schema{type: :boolean},
        required: %Schema{type: :boolean},
        requiredWhen: %Schema{type: :array, items: SignalAdapterFieldRequirement},
        encrypted: %Schema{type: :boolean},
        min: %Schema{type: :integer},
        max: %Schema{type: :integer},
        options: %Schema{type: :array, items: SignalAdapterFieldOption},
        validation: %Schema{
          oneOf: [SignalAdapterPatternValidation, SignalAdapterJSONObjectValidation]
        }
      },
      required: [:path, :type],
      additionalProperties: true
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalizedText
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterField

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalAdapterItem",
      type: :object,
      properties: %{
        adapter_id: %Schema{type: :string},
        adapter_category: %Schema{
          type: :string,
          enum: ["enterprise_im", "consumer_im", "email", "event_source"]
        },
        plugin_id: %Schema{type: :string, nullable: true},
        display_name: LocalizedText,
        fields: %Schema{type: :array, items: SignalAdapterField},
        group_message_mode_field: %Schema{allOf: [SignalAdapterField], nullable: true},
        unmatched_sender_policy_field: %Schema{allOf: [SignalAdapterField], nullable: true}
      },
      required: [
        :adapter_id,
        :adapter_category,
        :fields,
        :group_message_mode_field,
        :unmatched_sender_policy_field
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalAdapterListResponse",
      type: :object,
      properties: %{
        signal_adapters: %Schema{type: :array, items: SignalAdapterItem}
      },
      required: [:signal_adapters],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderAdapterItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalizedText
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalAdapterField

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
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

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderAdapterListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderAdapterItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityProviderAdapterListResponse",
      type: :object,
      properties: %{
        identity_provider_adapters: %Schema{type: :array, items: IdentityProviderAdapterItem}
      },
      required: [:identity_provider_adapters],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityProviderItem",
      type: :object,
      properties: %{
        provider_id: %Schema{type: :string},
        adapter_id: %Schema{type: :string},
        plugin_id: %Schema{type: :string},
        config_key: %Schema{type: :string},
        enabled: %Schema{type: :boolean},
        config: JSONValue,
        stored_secret_paths: %Schema{type: :array, items: %Schema{type: :string}}
      },
      required: [
        :provider_id,
        :adapter_id,
        :plugin_id,
        :config_key,
        :enabled,
        :config,
        :stored_secret_paths
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityProviderListResponse",
      type: :object,
      properties: %{
        identity_providers: %Schema{type: :array, items: IdentityProviderItem}
      },
      required: [:identity_providers],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityProviderResponse",
      type: :object,
      properties: %{
        identity_provider: IdentityProviderItem
      },
      required: [:identity_provider],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityProviderWriteRequest",
      type: :object,
      properties: %{
        adapter_id: %Schema{type: :string},
        config: JSONValue,
        enabled: %Schema{type: :boolean}
      },
      required: [:adapter_id, :config],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderSyncRunItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
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

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderSyncRunResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityProviderSyncRunItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityProviderSyncRunResponse",
      type: :object,
      properties: %{
        sync_run: IdentityProviderSyncRunItem
      },
      required: [:sync_run],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingRequestItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityMappingRequestItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        provider: %Schema{type: :string},
        external_id: %Schema{type: :string},
        display_name: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string, nullable: true},
        mobile: %Schema{type: :string, nullable: true},
        metadata: JSONValue,
        first_seen_at: %Schema{type: :string, format: :"date-time"},
        last_seen_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :provider, :external_id, :first_seen_at, :last_seen_at],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingRequestListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingRequestItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityMappingRequestListResponse",
      type: :object,
      properties: %{
        identity_mapping_requests: %Schema{type: :array, items: IdentityMappingRequestItem}
      },
      required: [:identity_mapping_requests],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingBindRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityMappingBindRequest",
      type: :object,
      properties: %{
        principal_uid: %Schema{type: :string}
      },
      required: [:principal_uid],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityMappingWriteRequest",
      type: :object,
      properties: %{
        principal_uid: %Schema{type: :string},
        provider: %Schema{type: :string},
        external_id: %Schema{type: :string}
      },
      required: [:principal_uid, :provider, :external_id],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityMappingItem",
      type: :object,
      properties: %{
        principal_uid: %Schema{type: :string},
        provider: %Schema{type: :string},
        external_id: %Schema{type: :string}
      },
      required: [:principal_uid, :provider, :external_id],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.IdentityMappingItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "IdentityMappingResponse",
      type: :object,
      properties: %{
        identity_mapping: IdentityMappingItem
      },
      required: [:identity_mapping],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalBindingWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalBindingWriteRequest",
      type: :object,
      properties: %{
        config: JSONValue,
        target: JSONValue,
        filters: JSONValue,
        group_message_mode: %Schema{
          type: :string,
          enum: ["addressed_only", "observe_all", "may_intervene"],
          nullable: true
        },
        unmatched_sender_policy: %Schema{
          type: :string,
          enum: ["manual_review", "create_standalone"],
          nullable: true
        }
      },
      required: [:config],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalBindingUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalBindingUpdateRequest",
      type: :object,
      properties: %{
        target_agent_uid: %Schema{type: :string},
        config: JSONValue,
        target: JSONValue,
        filters: JSONValue,
        group_message_mode: %Schema{
          type: :string,
          enum: ["addressed_only", "observe_all", "may_intervene"],
          nullable: true
        },
        unmatched_sender_policy: %Schema{
          type: :string,
          enum: ["manual_review", "create_standalone"],
          nullable: true
        }
      },
      required: [:target_agent_uid, :config],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalBindingItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalBindingItem",
      type: :object,
      properties: %{
        agent_uid: %Schema{type: :string},
        name: %Schema{type: :string},
        adapter: %Schema{type: :string},
        config_ref: %Schema{type: :string},
        config_key: %Schema{type: :string, nullable: true},
        target: JSONValue,
        filters: JSONValue,
        unaddressed_group_message_policy: %Schema{
          type: :string,
          enum: ["ignore", "record_only", "may_intervene"]
        },
        unmatched_sender_policy: %Schema{
          type: :string,
          enum: ["manual_review", "create_standalone"]
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
        :unmatched_sender_policy,
        :enabled
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalBindingResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalBindingResponse",
      type: :object,
      properties: %{
        signal_binding: SignalBindingItem
      },
      required: [:signal_binding],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalBindingDetailResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalBindingDetailResponse",
      type: :object,
      properties: %{
        signal_binding: SignalBindingItem,
        config: JSONValue,
        stored_secret_paths: %Schema{type: :array, items: %Schema{type: :string}}
      },
      required: [:signal_binding, :config, :stored_secret_paths],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalBindingListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalBindingItem
  alias AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryFailureItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalBindingListResponse",
      type: :object,
      properties: %{
        signal_bindings: %Schema{type: :array, items: SignalBindingItem},
        delivery_failures: %Schema{
          type: :array,
          maxItems: 100,
          items: SignalDeliveryFailureItem
        }
      },
      required: [:signal_bindings, :delivery_failures],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "WebhookEndpointItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        agent_uid: %Schema{type: :string, nullable: true},
        binding_name: %Schema{type: :string, nullable: true},
        session_id: %Schema{type: :string, nullable: true},
        event_format: %Schema{type: :string, enum: ["raw", "cloudevents"]},
        conversation_id: %Schema{type: :string, nullable: true},
        provider_thread_id: %Schema{type: :string, nullable: true},
        source_signal_id: %Schema{type: :string, format: :uuid, nullable: true},
        provider_message_id: %Schema{type: :string, nullable: true},
        source_provenance: JSONValue,
        automation_job_id: %Schema{
          type: :integer,
          minimum: 1000,
          maximum: 9_007_199_254_740_991,
          nullable: true
        },
        label: %Schema{type: :string},
        mode: %Schema{type: :string, enum: ["one_shot", "standing"]},
        status: %Schema{
          type: :string,
          enum: ["armed", "active", "fired", "expired", "cancelled"]
        },
        expires_at: %Schema{type: :string, format: :"date-time"},
        fired_at: %Schema{type: :string, format: :"date-time", nullable: true},
        cancelled_at: %Schema{type: :string, format: :"date-time", nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :agent_uid,
        :binding_name,
        :session_id,
        :label,
        :mode,
        :status,
        :expires_at,
        :created_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.CloudEventEndpointCreateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "CloudEventEndpointCreateRequest",
      type: :object,
      properties: %{
        label: %Schema{type: :string, minLength: 1, maxLength: 500},
        expires_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:label, :expires_at],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.CloudEventEndpointCreateResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointItem

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "CloudEventEndpointCreateResponse",
      type: :object,
      properties: %{
        webhook_endpoint: WebhookEndpointItem,
        token: %Schema{type: :string}
      },
      required: [:webhook_endpoint, :token],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "WebhookEndpointResponse",
      type: :object,
      properties: %{webhook_endpoint: WebhookEndpointItem},
      required: [:webhook_endpoint],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.WebhookEndpointItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "WebhookEndpointListResponse",
      type: :object,
      properties: %{
        webhook_endpoints: %Schema{type: :array, items: WebhookEndpointItem}
      },
      required: [:webhook_endpoints],
      additionalProperties: false
    },
    struct?: false
  )
end
