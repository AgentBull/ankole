defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalLocalCredential do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalLocalCredential",
      type: :object,
      nullable: true,
      properties: %{
        status: %Schema{type: :string, enum: ["active", "must_change"]}
      },
      required: [:status],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalLocalCredential

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalItem",
      type: :object,
      properties: %{
        uid: %Schema{type: :string},
        type: %Schema{type: :string, enum: ["human", "agent", "system"]},
        status: %Schema{type: :string, enum: ["active", "disabled"]},
        display_name: %Schema{type: :string, nullable: true},
        avatar_url: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string, nullable: true},
        handle: %Schema{type: :string, nullable: true},
        has_external_identity: %Schema{type: :boolean},
        local_credential: PrincipalLocalCredential,
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string}
      },
      required: [
        :uid,
        :type,
        :status,
        :has_external_identity,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalCreateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalCreateRequest",
      type: :object,
      properties: %{
        email: %Schema{type: :string},
        display_name: %Schema{type: :string, nullable: true},
        must_change_password: %Schema{type: :boolean, default: true}
      },
      required: [:email],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalCreateResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalCreateResponse",
      type: :object,
      properties: %{
        principal: PrincipalItem,
        initial_password: %Schema{type: :string}
      },
      required: [:principal, :initial_password],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalUpdateRequest",
      type: :object,
      properties: %{
        display_name: %Schema{type: :string, nullable: true},
        email: %Schema{type: :string}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "LocalPasswordResetRequest",
      type: :object,
      properties: %{
        must_change_password: %Schema{type: :boolean, default: true}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "LocalPasswordResetResponse",
      type: :object,
      properties: %{
        initial_password: %Schema{type: :string}
      },
      required: [:initial_password],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalListResponse",
      type: :object,
      properties: %{
        principals: %Schema{type: :array, items: PrincipalItem}
      },
      required: [:principals],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalGroupItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        display_name: %Schema{type: :string},
        domain: %Schema{type: :string, enum: ["operator", "directory", "im_group"]},
        kind: %Schema{type: :string, enum: ["static", "computed"]},
        built_in: %Schema{type: :boolean},
        computed_condition: %Schema{type: :string, nullable: true},
        description: %Schema{type: :string, nullable: true},
        member_count: %Schema{type: :integer},
        grant_count: %Schema{type: :integer},
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string}
      },
      required: [
        :id,
        :name,
        :display_name,
        :domain,
        :kind,
        :built_in,
        :member_count,
        :grant_count,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalGroupListResponse",
      type: :object,
      properties: %{
        principal_groups: %Schema{type: :array, items: PrincipalGroupItem}
      },
      required: [:principal_groups],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalGroupResponse",
      type: :object,
      properties: %{
        principal_group: PrincipalGroupItem
      },
      required: [:principal_group],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupCreateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalGroupCreateRequest",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Lowercase stable policy key"},
        display_name: %Schema{type: :string},
        kind: %Schema{type: :string, enum: ["static", "computed"], default: "static"},
        computed_condition: %Schema{
          type: :string,
          nullable: true,
          description: "CEL condition required when kind is computed"
        },
        description: %Schema{type: :string, nullable: true}
      },
      required: [:name, :display_name],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalGroupUpdateRequest",
      type: :object,
      properties: %{
        display_name: %Schema{type: :string, nullable: true},
        computed_condition: %Schema{type: :string, nullable: true},
        description: %Schema{type: :string, nullable: true}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupMemberItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalGroupMemberItem",
      type: :object,
      properties: %{
        uid: %Schema{type: :string},
        type: %Schema{type: :string, enum: ["human", "agent", "system"]},
        status: %Schema{type: :string, enum: ["active", "disabled"]},
        display_name: %Schema{type: :string, nullable: true},
        avatar_url: %Schema{type: :string, nullable: true},
        member_since: %Schema{
          type: :string,
          nullable: true,
          description: "Stored membership timestamp; null for evaluated computed members"
        }
      },
      required: [:uid, :type, :status, :member_since],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupMemberListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupMemberItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalGroupMemberListResponse",
      type: :object,
      properties: %{
        principal_group_members: %Schema{type: :array, items: PrincipalGroupMemberItem}
      },
      required: [:principal_group_members],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ComputedMemberPreviewRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ComputedMemberPreviewRequest",
      type: :object,
      properties: %{
        condition: %Schema{
          type: :string,
          description: "CEL condition over the principal object"
        }
      },
      required: [:condition],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PermissionGrantItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        principal_uid: %Schema{type: :string, nullable: true},
        group_id: %Schema{type: :string, nullable: true},
        resource_pattern: %Schema{type: :string},
        action: %Schema{type: :string},
        condition: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string}
      },
      required: [
        :id,
        :principal_uid,
        :group_id,
        :resource_pattern,
        :action,
        :condition,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PermissionGrantListResponse",
      type: :object,
      properties: %{
        permission_grants: %Schema{type: :array, items: PermissionGrantItem}
      },
      required: [:permission_grants],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PermissionGrantResponse",
      type: :object,
      properties: %{
        permission_grant: PermissionGrantItem
      },
      required: [:permission_grant],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantCreateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PermissionGrantCreateRequest",
      type: :object,
      description: "Exactly one owner: principal_uid or group_name.",
      properties: %{
        principal_uid: %Schema{type: :string, nullable: true},
        group_name: %Schema{type: :string, nullable: true},
        resource_pattern: %Schema{
          type: :string,
          description: "AuthZ resource glob pattern, for example workspace:**"
        },
        action: %Schema{type: :string, description: "Exact action token without colons"},
        condition: %Schema{type: :string, default: "true"},
        description: %Schema{type: :string, nullable: true}
      },
      required: [:resource_pattern, :action],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PermissionGrantUpdateRequest",
      type: :object,
      properties: %{
        resource_pattern: %Schema{type: :string, nullable: true},
        action: %Schema{type: :string, nullable: true},
        condition: %Schema{type: :string, nullable: true},
        description: %Schema{type: :string, nullable: true}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.PrincipalResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "PrincipalResponse",
      type: :object,
      properties: %{
        principal: PrincipalItem
      },
      required: [:principal],
      additionalProperties: false
    },
    struct?: false
  )
end
