defmodule AnkoleWeb.Schemas.TenantAPI do
  @moduledoc "Site administration contracts for tenant lifecycle."
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  defmodule Tenant do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "Tenant",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          slug: %Schema{type: :string},
          display_name: %Schema{type: :string},
          suspended_at: %Schema{type: :string, format: :"date-time", nullable: true},
          deleting_at: %Schema{type: :string, format: :"date-time", nullable: true},
          inserted_at: %Schema{type: :string, format: :"date-time"},
          updated_at: %Schema{type: :string, format: :"date-time"}
        },
        required: [
          :id,
          :slug,
          :display_name,
          :suspended_at,
          :deleting_at,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Response do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "TenantResponse",
        type: :object,
        properties: %{tenant: Tenant},
        required: [:tenant],
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
        title: "TenantListResponse",
        type: :object,
        properties: %{
          tenants: %Schema{type: :array, items: Tenant},
          brain_packs: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [:tenants, :brain_packs],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule CreateRequest do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "TenantCreateRequest",
        type: :object,
        properties: %{
          slug: %Schema{type: :string, pattern: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"},
          display_name: %Schema{type: :string, minLength: 1},
          brain_packs: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [:slug, :display_name],
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
        title: "TenantUpdateRequest",
        type: :object,
        properties: %{
          slug: %Schema{type: :string, pattern: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"},
          display_name: %Schema{type: :string, minLength: 1}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule TransferRequest do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SiteAdministrationTransferRequest",
        type: :object,
        properties: %{
          tenant_id: %Schema{type: :string, format: :uuid},
          site_admin_uid: %Schema{type: :string}
        },
        required: [:tenant_id, :site_admin_uid],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
