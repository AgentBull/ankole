defmodule AnkoleWeb.Schemas.ConsoleAPI do
  @moduledoc """
  Shared OpenAPI value and error schemas for the Console REST API.

  Domain declarations live in `schemas/console_api/`; their full module names
  remain under this namespace so controller references and wire schemas stay stable.
  """
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  defmodule JSONValue do
    @moduledoc """
    Any JSON-compatible value.
    """

    @behaviour OpenAPISpex.Schema

    # Deliberately untyped: each AppConfigure key has its own value schema, which
    # the context enforces. Constraining the type here would force a single shape
    # across every key, so the wire schema stays open and validation lives downstream.
    @impl OpenAPISpex.Schema
    def schema do
      %Schema{
        title: "JSONValue",
        nullable: true,
        description: "Any JSON-compatible value. AppConfigure validates the concrete key schema."
      }
    end
  end

  defmodule LocalizedText do
    @moduledoc """
    Locale-keyed operator-facing text with a required default fallback.
    """

    @behaviour OpenAPISpex.Schema

    @impl OpenAPISpex.Schema
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

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleApiErrorDetail",
        type: :object,
        properties: %{
          path: %Schema{type: :string, nullable: true},
          line: %Schema{type: :integer, nullable: true},
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

    require OpenAPISpex

    OpenAPISpex.schema(
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

  defmodule ActorRef do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleActorRef",
        type: :object,
        properties: %{
          tenant_id: %Schema{type: :string, format: :uuid},
          uid: %Schema{type: :string}
        },
        required: [:tenant_id, :uid],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ErrorEnvelope do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
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
end
