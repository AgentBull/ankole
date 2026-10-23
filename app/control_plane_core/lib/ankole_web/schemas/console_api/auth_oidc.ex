defmodule AnkoleWeb.Schemas.ConsoleAPI.AuthSessionDeleteResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
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

defmodule AnkoleWeb.Schemas.ConsoleAPI.OIDCClientItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "OIDCClientItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        enabled: %Schema{type: :boolean},
        type: %Schema{type: :string, enum: ["public", "confidential"]},
        redirect_uris: %Schema{type: :array, items: %Schema{type: :string}},
        scopes: %Schema{type: :array, items: %Schema{type: :string}},
        allowed_identity_provider_ids: %Schema{type: :array, items: %Schema{type: :string}},
        backchannel_logout_uri: %Schema{type: :string, nullable: true},
        backchannel_logout_session_required: %Schema{type: :boolean},
        post_logout_redirect_uris: %Schema{type: :array, items: %Schema{type: :string}},
        allow_insecure_local_logout: %Schema{type: :boolean},
        allowed_group_ids: %Schema{type: :array, items: %Schema{type: :string, format: :uuid}},
        allowed_models: %Schema{
          type: :object,
          additionalProperties: AnkoleWeb.Schemas.ConsoleAPI.ModelProfileWriteRequest
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :name,
        :enabled,
        :type,
        :redirect_uris,
        :scopes,
        :allowed_identity_provider_ids,
        :backchannel_logout_uri,
        :backchannel_logout_session_required,
        :post_logout_redirect_uris,
        :allow_insecure_local_logout,
        :allowed_group_ids,
        :allowed_models,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.OIDCClientSecretResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.OIDCClientItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "OIDCClientSecretResponse",
      type: :object,
      properties: %{
        oidc_client: OIDCClientItem,
        client_secret: %Schema{type: :string, nullable: true}
      },
      required: [:oidc_client, :client_secret],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.OIDCLoginSources do
  @moduledoc false
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "OIDCLoginSources",
      type: :object,
      properties: %{
        sources: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{provider_id: %Schema{type: :string}, enabled: %Schema{type: :boolean}},
            required: [:provider_id, :enabled],
            additionalProperties: false
          }
        }
      },
      required: [:sources],
      additionalProperties: false
    },
    struct?: false
  )
end
