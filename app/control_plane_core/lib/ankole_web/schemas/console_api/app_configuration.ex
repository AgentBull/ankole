defmodule AnkoleWeb.Schemas.ConsoleAPI.ControlPlanePluginItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ControlPlanePluginItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        display_name: JSONValue,
        description: JSONValue,
        configured_enabled: %Schema{type: :boolean},
        active: %Schema{type: :boolean},
        restart_required: %Schema{type: :boolean}
      },
      required: [
        :id,
        :display_name,
        :description,
        :configured_enabled,
        :active,
        :restart_required
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ControlPlanePluginListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ControlPlanePluginItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ControlPlanePluginListResponse",
      type: :object,
      properties: %{
        control_plane_plugins: %Schema{type: :array, items: ControlPlanePluginItem}
      },
      required: [:control_plane_plugins],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ControlPlanePluginWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ControlPlanePluginWriteRequest",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        enabled: %Schema{type: :boolean}
      },
      required: [:id, :enabled],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  # One AppConfigure entry as the console sees it. The shape reflects the
  # registry model: `kind` distinguishes exact keys from pattern keys and their
  # materialized instances; `source`/`overridden`/`default_present` describe
  # whether the effective value comes from the compiled default or a global
  # override; `encrypted`/`editable` drive what the UI may show or change.
  OpenAPISpex.schema(
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
        scope: %Schema{type: :string, enum: ["global", "tenant"]},
        editable: %Schema{type: :boolean},
        default_present: %Schema{type: :boolean},
        overridden: %Schema{type: :boolean},
        present: %Schema{type: :boolean},
        source: %Schema{
          type: :string,
          enum: ["tenant", "global", "default", "pattern", "missing", "error"]
        },
        value: JSONValue,
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

defmodule AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AppConfigurationListResponse",
      type: :object,
      properties: %{
        app_configurations: %Schema{type: :array, items: AppConfigurationItem}
      },
      required: [:app_configurations],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AppConfigurationResponse",
      type: :object,
      properties: %{
        app_configuration: AppConfigurationItem
      },
      required: [:app_configuration],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  # Existing encrypted values may omit `value` to preserve the stored secret.
  # Plaintext and unset values still require a value in the owning context.
  OpenAPISpex.schema(
    %{
      title: "AppConfigurationUpdateRequest",
      type: :object,
      properties: %{
        value: JSONValue
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationDecryptionValue do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AppConfigurationDecryptionValue",
      type: :object,
      properties: %{
        key: %Schema{type: :string},
        value: JSONValue
      },
      required: [:key, :value],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationDecryptionResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AppConfigurationDecryptionValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AppConfigurationDecryptionResponse",
      type: :object,
      properties: %{
        decrypted_value: AppConfigurationDecryptionValue
      },
      required: [:decrypted_value],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  # Secret values omit `value`; the decryption endpoint reveals them.
  OpenAPISpex.schema(
    %{
      title: "WorkerEnvItem",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        secret: %Schema{type: :boolean},
        description: %Schema{type: :string, nullable: true},
        present: %Schema{type: :boolean},
        source: %Schema{
          type: :string,
          enum: ["global", "tenant", "agent", "missing"]
        },
        value: %Schema{type: :string}
      },
      required: [:name, :secret, :present, :source],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "WorkerEnvListResponse",
      type: :object,
      properties: %{
        worker_envs: %Schema{type: :array, items: WorkerEnvItem}
      },
      required: [:worker_envs],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "WorkerEnvResponse",
      type: :object,
      properties: %{
        worker_env: WorkerEnvItem
      },
      required: [:worker_env],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  # Existing encrypted values may omit `value` to preserve the stored secret.
  OpenAPISpex.schema(
    %{
      title: "WorkerEnvUpdateRequest",
      type: :object,
      properties: %{
        value: %Schema{type: :string},
        secret: %Schema{type: :boolean},
        description: %Schema{type: :string, nullable: true}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvDecryptionValue do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "WorkerEnvDecryptionValue",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        value: %Schema{type: :string}
      },
      required: [:name, :value],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvDecryptionResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.WorkerEnvDecryptionValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "WorkerEnvDecryptionResponse",
      type: :object,
      properties: %{
        decrypted_value: WorkerEnvDecryptionValue
      },
      required: [:decrypted_value],
      additionalProperties: false
    },
    struct?: false
  )
end
