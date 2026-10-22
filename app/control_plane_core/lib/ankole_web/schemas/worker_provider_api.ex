defmodule AnkoleWeb.Schemas.WorkerProviderAPI do
  @moduledoc "Console contracts for Worker pools and their configuration."

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  defmodule Provider do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProvider",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          kind: %Schema{type: :string},
          display_name: %Schema{type: :string},
          config: %Schema{type: :string, description: "The original YAML, including comments."},
          credentials: %Schema{
            type: :object,
            additionalProperties: %Schema{type: :string},
            description: "Stored credentials are masked."
          },
          is_default: %Schema{type: :boolean},
          agent_count: %Schema{type: :integer, minimum: 0},
          selectable: %Schema{
            type: :boolean,
            description:
              "The kind is active and its Plugin is selected for the next start. This does not check cloud connectivity."
          }
        },
        required: [
          :provider_id,
          :kind,
          :display_name,
          :config,
          :credentials,
          :is_default,
          :agent_count,
          :selectable
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ProviderResponse do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderResponse",
        type: :object,
        properties: %{worker_provider: Provider},
        required: [:worker_provider],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ListResponse do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderListResponse",
        type: :object,
        properties: %{worker_providers: %Schema{type: :array, items: Provider}},
        required: [:worker_providers],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Kind do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderKind",
        type: :object,
        properties: %{
          kind: %Schema{type: :string},
          example: %Schema{type: :string},
          credentials: %Schema{
            type: :object,
            additionalProperties: %Schema{
              type: :object,
              properties: %{required: %Schema{type: :boolean}},
              required: [:required],
              additionalProperties: false
            }
          }
        },
        required: [:kind, :example, :credentials],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule KindsResponse do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderKindsResponse",
        type: :object,
        properties: %{worker_provider_kinds: %Schema{type: :array, items: Kind}},
        required: [:worker_provider_kinds],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule CredentialsInput do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderCredentialsInput",
        type: :object,
        additionalProperties: %Schema{type: :string, nullable: true},
        description:
          "Text replaces the stored credential. An empty string or an absent key keeps it. Null removes an optional credential."
      },
      struct?: false
    )
  end

  defmodule CreateRequest do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderCreateRequest",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          kind: %Schema{type: :string},
          display_name: %Schema{type: :string},
          config: %Schema{type: :string},
          credentials: CredentialsInput,
          is_default: %Schema{type: :boolean}
        },
        required: [:provider_id, :kind, :display_name, :config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule UpdateRequest do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderUpdateRequest",
        type: :object,
        properties: %{
          display_name: %Schema{type: :string},
          config: %Schema{type: :string},
          credentials: CredentialsInput,
          is_default: %Schema{type: :boolean}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule CheckResponse do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderCheckResponse",
        type: :object,
        properties: %{available: %Schema{type: :boolean}},
        required: [:available],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AssignRequest do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderAssignRequest",
        type: :object,
        properties: %{provider_id: %Schema{type: :string}},
        required: [:provider_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AssignResponse do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerProviderAssignResponse",
        type: :object,
        properties: %{agent_uid: %Schema{type: :string}, provider_id: %Schema{type: :string}},
        required: [:agent_uid, :provider_id],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
