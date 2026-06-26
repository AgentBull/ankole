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

  defmodule LlmProviderCredentialProjection do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LlmProviderCredentialProjection",
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

  defmodule LlmProviderItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LlmProviderItem",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          provider_source: %Schema{type: :string},
          base_url: %Schema{type: :string, nullable: true},
          connection_options: %Schema{type: :object, additionalProperties: true},
          credential_mode: %Schema{type: :string},
          disabled_at: %Schema{type: :string, nullable: true},
          credential: LlmProviderCredentialProjection,
          source_metadata: %Schema{type: :object, additionalProperties: true}
        },
        required: [
          :provider_id,
          :provider_source,
          :connection_options,
          :credential_mode,
          :credential,
          :source_metadata
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LlmProviderListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LlmProviderListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: LlmProviderItem}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LlmProviderResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LlmProviderResponse",
        type: :object,
        properties: %{
          data: LlmProviderItem
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LlmProviderWriteRequest do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LlmProviderWriteRequest",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          provider_source: %Schema{type: :string},
          base_url: %Schema{type: :string, nullable: true},
          credential: %Schema{type: :string, nullable: true},
          credential_mode: %Schema{type: :string},
          connection_options: %Schema{type: :object, additionalProperties: true}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LlmProviderSourceItem do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LlmProviderSourceItem",
        type: :object,
        properties: %{
          provider_source: %Schema{type: :string},
          label: %Schema{type: :string},
          codex_compatible: %Schema{type: :boolean},
          adapter_strategy: %Schema{type: :string},
          default_base_url: %Schema{type: :string},
          credential_modes: %Schema{type: :array, items: %Schema{type: :string}},
          connection_options: %Schema{type: :array, items: %Schema{type: :string}},
          runtime_provider_options: %Schema{type: :array, items: %Schema{type: :string}},
          model_catalog_policy: %Schema{type: :string}
        },
        required: [
          :provider_source,
          :label,
          :codex_compatible,
          :adapter_strategy,
          :default_base_url,
          :credential_modes,
          :connection_options,
          :runtime_provider_options,
          :model_catalog_policy
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LlmProviderSourceListResponse do
    @moduledoc false

    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LlmProviderSourceListResponse",
        type: :object,
        properties: %{
          data: %Schema{type: :array, items: LlmProviderSourceItem}
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
