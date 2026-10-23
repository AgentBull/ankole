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
