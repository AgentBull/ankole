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
          provider_options: %Schema{type: :object, additionalProperties: true}
        },
        required: [:provider_id, :model],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
