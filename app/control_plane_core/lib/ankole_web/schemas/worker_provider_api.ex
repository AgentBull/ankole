defmodule AnkoleWeb.Schemas.WorkerProviderAPI do
  @moduledoc "Console contracts for Worker provider kinds, checks, and Agent assignment."

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

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
