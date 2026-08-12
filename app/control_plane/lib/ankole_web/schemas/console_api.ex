defmodule AnkoleWeb.Schemas.ConsoleAPI do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  OpenAPI schemas for the console REST API.
  """

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

  defmodule AuthSessionDeleteResponse do
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

  defmodule ConsoleTokenRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
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

    require OpenAPISpex

    OpenAPISpex.schema(
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

    require OpenAPISpex

    OpenAPISpex.schema(
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

  defmodule AgentItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentItem",
        type: :object,
        properties: %{
          uid: %Schema{type: :string},
          status: %Schema{type: :string, enum: ["active", "disabled"]},
          display_name: %Schema{type: :string, nullable: true},
          avatar_url: %Schema{type: :string, nullable: true},
          type: %Schema{type: :string, enum: ["ai_colleague"]},
          role: %Schema{type: :string},
          options: %Schema{type: :object, additionalProperties: true},
          created_by_principal_uid: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [
          :uid,
          :status,
          :type,
          :role,
          :options,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PrincipalItem do
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
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [:uid, :type, :status, :inserted_at, :updated_at],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PrincipalListResponse do
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

  defmodule PrincipalGroupItem do
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

  defmodule PrincipalGroupListResponse do
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

  defmodule PrincipalGroupResponse do
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

  defmodule PrincipalGroupCreateRequest do
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

  defmodule PrincipalGroupUpdateRequest do
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

  defmodule PrincipalGroupMemberItem do
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

  defmodule PrincipalGroupMemberListResponse do
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

  defmodule ComputedMemberPreviewRequest do
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

  defmodule PermissionGrantItem do
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

  defmodule PermissionGrantListResponse do
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

  defmodule PermissionGrantResponse do
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

  defmodule PermissionGrantCreateRequest do
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

  defmodule PermissionGrantUpdateRequest do
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

  defmodule PrincipalResponse do
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

  defmodule AgentListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentListResponse",
        type: :object,
        properties: %{
          agents: %Schema{type: :array, items: AgentItem}
        },
        required: [:agents],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentResponse",
        type: :object,
        properties: %{
          agent: AgentItem
        },
        required: [:agent],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentCreateRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentCreateRequest",
        type: :object,
        properties: %{
          uid: %Schema{type: :string},
          display_name: %Schema{type: :string},
          avatar_url: %Schema{type: :string, nullable: true},
          role: %Schema{type: :string},
          options: %Schema{type: :object, additionalProperties: true}
        },
        required: [:uid, :display_name, :role],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentUpdateRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentUpdateRequest",
        type: :object,
        properties: %{
          display_name: %Schema{type: :string},
          avatar_url: %Schema{type: :string, nullable: true},
          role: %Schema{type: :string},
          options: %Schema{type: :object, additionalProperties: true}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryDocumentItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryDocumentItem",
        type: :object,
        properties: %{
          kind: %Schema{type: :string, enum: ~w(mission soul design)},
          content: %Schema{type: :string},
          content_hash: %Schema{type: :string}
        },
        required: [:kind, :content, :content_hash],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryDocuments do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryDocuments",
        type: :object,
        properties: %{
          mission: AgentLibraryDocumentItem,
          soul: AgentLibraryDocumentItem,
          design: AgentLibraryDocumentItem
        },
        required: [:mission, :soul, :design],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryDocumentsResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryDocumentsResponse",
        type: :object,
        properties: %{
          library_documents: AgentLibraryDocuments
        },
        required: [:library_documents],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryDocumentResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryDocumentResponse",
        type: :object,
        properties: %{
          library_document: AgentLibraryDocumentItem
        },
        required: [:library_document],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryDocumentWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryDocumentWriteRequest",
        type: :object,
        properties: %{
          content: %Schema{type: :string},
          expected_content_hash: %Schema{type: :string}
        },
        required: [:content, :expected_content_hash],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibrarySkillOverlayItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibrarySkillOverlayItem",
        type: :object,
        properties: %{
          skill_name: %Schema{type: :string},
          skill_id: %Schema{type: :string, nullable: true},
          agent_plugin_id: %Schema{type: :string, nullable: true},
          description: %Schema{type: :string, nullable: true},
          effective_enabled: %Schema{type: :boolean},
          text: %Schema{type: :string},
          content_hash: %Schema{type: :string},
          updated_at: %Schema{type: :string, format: :"date-time"}
        },
        required: [
          :skill_name,
          :skill_id,
          :agent_plugin_id,
          :description,
          :effective_enabled,
          :text,
          :content_hash,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibrarySkillOverlaysResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibrarySkillOverlaysResponse",
        type: :object,
        properties: %{
          skill_overlays: %Schema{type: :array, items: AgentLibrarySkillOverlayItem}
        },
        required: [:skill_overlays],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibrarySkillOverlayWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibrarySkillOverlayWriteRequest",
        type: :object,
        properties: %{
          text: %Schema{type: :string},
          expected_content_hash: %Schema{type: :string}
        },
        required: [:text, :expected_content_hash],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibrarySkillCapabilityItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibrarySkillCapabilityItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          name: %Schema{type: :string},
          description: %Schema{type: :string},
          source_kind: %Schema{type: :string, enum: ~w(builtin installed)},
          agent_plugin_id: %Schema{type: :string, nullable: true},
          global_default_enabled: %Schema{type: :boolean},
          override_enabled: %Schema{type: :boolean, nullable: true},
          effective_enabled: %Schema{type: :boolean}
        },
        required: [
          :id,
          :name,
          :description,
          :source_kind,
          :agent_plugin_id,
          :global_default_enabled,
          :override_enabled,
          :effective_enabled
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentPluginCapabilityItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentPluginCapabilityItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          description: %Schema{type: :string},
          version: %Schema{type: :string},
          global_default_enabled: %Schema{type: :boolean},
          override_enabled: %Schema{type: :boolean, nullable: true},
          effective_enabled: %Schema{type: :boolean},
          skills: %Schema{type: :array, items: AgentLibrarySkillCapabilityItem}
        },
        required: [
          :id,
          :description,
          :version,
          :global_default_enabled,
          :override_enabled,
          :effective_enabled,
          :skills
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryCapabilitiesResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryCapabilitiesResponse",
        type: :object,
        properties: %{
          agent_plugins: %Schema{type: :array, items: AgentPluginCapabilityItem},
          skills: %Schema{type: :array, items: AgentLibrarySkillCapabilityItem}
        },
        required: [:agent_plugins, :skills],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryGlobalDefaultWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryGlobalDefaultWriteRequest",
        type: :object,
        properties: %{enabled: %Schema{type: :boolean}},
        required: [:enabled],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentLibraryAgentOverrideWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentLibraryAgentOverrideWriteRequest",
        type: :object,
        properties: %{enabled: %Schema{type: :boolean, nullable: true}},
        required: [:enabled],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ControlPlanePluginItem do
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

  defmodule ControlPlanePluginListResponse do
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

  defmodule ControlPlanePluginWriteRequest do
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

  defmodule AppConfigurationItem do
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
          scope: %Schema{type: :string, enum: ["scoped", "global"]},
          editable: %Schema{type: :boolean},
          default_present: %Schema{type: :boolean},
          overridden: %Schema{type: :boolean},
          present: %Schema{type: :boolean},
          source: %Schema{
            type: :string,
            enum: ["default", "global", "missing", "pattern", "error"]
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

  defmodule AppConfigurationListResponse do
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

  defmodule AppConfigurationResponse do
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

  defmodule AppConfigurationUpdateRequest do
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

  defmodule AppConfigurationDecryptionValue do
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

  defmodule AppConfigurationDecryptionResponse do
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

  defmodule WorkerEnvItem do
    @moduledoc false

    require OpenAPISpex

    # One Agent Computer shell variable as the console sees it. `kind` says
    # which track owns the name: a `declared` AppConfigure definition (with
    # `declared_key` pointing at the configuration key) or a `custom` operator
    # row. `source` names the tier the effective value comes from, and secret
    # values omit `value` — the decryption endpoint reveals them.
    OpenAPISpex.schema(
      %{
        title: "WorkerEnvItem",
        type: :object,
        properties: %{
          name: %Schema{type: :string},
          kind: %Schema{type: :string, enum: ["declared", "custom"]},
          secret: %Schema{type: :boolean},
          description: %Schema{type: :string, nullable: true},
          declared_key: %Schema{type: :string, nullable: true},
          present: %Schema{type: :boolean},
          source: %Schema{
            type: :string,
            enum: ["default", "global", "agent", "missing", "error"]
          },
          editable: %Schema{type: :boolean},
          value: JSONValue,
          error: %Schema{type: :string, nullable: true}
        },
        required: [:name, :kind, :secret, :present, :source, :editable],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerEnvListResponse do
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

  defmodule WorkerEnvResponse do
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

  defmodule WorkerEnvUpdateRequest do
    @moduledoc false

    require OpenAPISpex

    # `value` must be a string for custom variables; declared variables accept
    # whatever JSON their AppConfigure schema validates. Existing encrypted
    # values may omit `value` to preserve the stored secret. `secret` only
    # applies to custom variables and keeps its stored state when omitted.
    OpenAPISpex.schema(
      %{
        title: "WorkerEnvUpdateRequest",
        type: :object,
        properties: %{
          value: JSONValue,
          secret: %Schema{type: :boolean},
          description: %Schema{type: :string, nullable: true}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerEnvDecryptionValue do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerEnvDecryptionValue",
        type: :object,
        properties: %{
          name: %Schema{type: :string},
          value: JSONValue
        },
        required: [:name, :value],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerEnvDecryptionResponse do
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

  defmodule SignalAdapterFieldOption do
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

  defmodule SignalAdapterField do
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
          required: %Schema{type: :boolean, nullable: true},
          encrypted: %Schema{type: :boolean, nullable: true},
          min: %Schema{type: :integer, nullable: true},
          max: %Schema{type: :integer, nullable: true},
          options: %Schema{type: :array, items: SignalAdapterFieldOption, nullable: true}
        },
        required: [:path, :type],
        additionalProperties: true
      },
      struct?: false
    )
  end

  defmodule SignalAdapterItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalAdapterItem",
        type: :object,
        properties: %{
          adapter_id: %Schema{type: :string},
          plugin_id: %Schema{type: :string, nullable: true},
          display_name: LocalizedText,
          fields: %Schema{type: :array, items: SignalAdapterField},
          group_message_mode_field: SignalAdapterField
        },
        required: [:adapter_id, :fields, :group_message_mode_field],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalAdapterListResponse do
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

  defmodule IdentityProviderAdapterItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderAdapterItem",
        type: :object,
        properties: %{
          adapter_id: %Schema{type: :string},
          plugin_id: %Schema{type: :string, nullable: true},
          display_name: LocalizedText,
          capabilities: %Schema{type: :array, items: %Schema{type: :string}},
          fields: %Schema{type: :array, items: SignalAdapterField},
          default_provider_id: %Schema{type: :string}
        },
        required: [:adapter_id, :capabilities, :fields, :default_provider_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderAdapterListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderAdapterListResponse",
        type: :object,
        properties: %{
          identity_provider_adapters: %Schema{type: :array, items: IdentityProviderAdapterItem}
        },
        required: [:identity_provider_adapters],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderItem",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          adapter_id: %Schema{type: :string},
          plugin_id: %Schema{type: :string},
          config_key: %Schema{type: :string},
          enabled: %Schema{type: :boolean},
          config: JSONValue,
          stored_secret_paths: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [
          :provider_id,
          :adapter_id,
          :plugin_id,
          :config_key,
          :enabled,
          :config,
          :stored_secret_paths
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderListResponse",
        type: :object,
        properties: %{
          identity_providers: %Schema{type: :array, items: IdentityProviderItem}
        },
        required: [:identity_providers],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderResponse",
        type: :object,
        properties: %{
          identity_provider: IdentityProviderItem
        },
        required: [:identity_provider],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderWriteRequest",
        type: :object,
        properties: %{
          adapter_id: %Schema{type: :string},
          config: JSONValue,
          enabled: %Schema{type: :boolean}
        },
        required: [:adapter_id, :config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderSyncRunItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderSyncRunItem",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          status: %Schema{type: :string, enum: ["enqueued"]},
          job_id: %Schema{type: :integer, nullable: true}
        },
        required: [:provider_id, :status],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule IdentityProviderSyncRunResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "IdentityProviderSyncRunResponse",
        type: :object,
        properties: %{
          sync_run: IdentityProviderSyncRunItem
        },
        required: [:sync_run],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalBindingWriteRequest",
        type: :object,
        properties: %{
          config: JSONValue,
          group_message_mode: %Schema{
            type: :string,
            enum: ["addressed_only", "observe_all", "may_intervene"],
            nullable: true
          },
          confidential_memory: %Schema{type: :boolean, default: false}
        },
        required: [:config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingUpdateRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalBindingUpdateRequest",
        type: :object,
        properties: %{
          target_agent_uid: %Schema{type: :string},
          config: JSONValue,
          group_message_mode: %Schema{
            type: :string,
            enum: ["addressed_only", "observe_all", "may_intervene"],
            nullable: true
          },
          confidential_memory: %Schema{type: :boolean, nullable: true}
        },
        required: [:target_agent_uid, :config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalDeliveryRequeueRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalDeliveryRequeueRequest",
        type: :object,
        properties: %{
          binding_name: %Schema{type: :string, minLength: 1},
          outbound_key: %Schema{type: :string, minLength: 1}
        },
        required: [:binding_name, :outbound_key],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalDeliveryFailureItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalDeliveryFailureItem",
        type: :object,
        properties: %{
          binding_name: %Schema{type: :string},
          outbound_key: %Schema{type: :string},
          status: %Schema{type: :string, enum: ["failed", "unknown_after_send"]},
          state: %Schema{
            type: :string,
            enum: ["blocked", "permanent", "exhausted"]
          },
          attempt_count: %Schema{type: :integer, minimum: 0},
          max_attempts: %Schema{type: :integer, minimum: 1},
          possible_duplicate: %Schema{type: :boolean},
          can_retry: %Schema{type: :boolean},
          updated_at: %Schema{type: :string, format: :"date-time"}
        },
        required: [
          :binding_name,
          :outbound_key,
          :status,
          :state,
          :attempt_count,
          :max_attempts,
          :possible_duplicate,
          :can_retry,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalDeliveryRequeueResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalDeliveryRequeueResponse",
        type: :object,
        properties: %{requeued: %Schema{type: :boolean}},
        required: [:requeued],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingItem do
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
          config_key: %Schema{type: :string},
          unaddressed_group_message_policy: %Schema{
            type: :string,
            enum: ["ignore", "record_only", "may_intervene"]
          },
          confidential_memory: %Schema{type: :boolean},
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
          :confidential_memory,
          :enabled
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalBindingResponse do
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

  defmodule SignalBindingDetailResponse do
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

  defmodule SignalBindingListResponse do
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

  defmodule SignalChannelStandingOrdersWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalChannelStandingOrdersWriteRequest",
        type: :object,
        properties: %{
          orders: %Schema{
            type: :string,
            maxLength: 4000,
            description: "Full replacement standing-orders text; empty clears them."
          }
        },
        required: [:orders],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalChannelStandingOrdersItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalChannelStandingOrdersItem",
        type: :object,
        properties: %{
          channel_id: %Schema{type: :string},
          channel_name: %Schema{type: :string, nullable: true},
          orders: %Schema{type: :string, nullable: true},
          set_by: %Schema{type: :string, nullable: true},
          updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
        },
        required: [:channel_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalChannelStandingOrdersResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalChannelStandingOrdersResponse",
        type: :object,
        properties: %{
          standing_orders: SignalChannelStandingOrdersItem
        },
        required: [:standing_orders],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ScheduleCronWriteRequest",
        type: :object,
        properties: %{
          owner_session_id: %Schema{
            type: :string,
            minLength: 1,
            description:
              "Conversation session that manages this schedule. Fires run in the derived execution session `cron:<schedule_id>`."
          },
          binding_name: %Schema{type: :string},
          name: %Schema{type: :string, minLength: 1},
          status: %Schema{type: :string, enum: ["active", "paused"], nullable: true},
          schedule: JSONValue,
          timezone: %Schema{type: :string, nullable: true},
          payload: JSONValue,
          delivery: JSONValue,
          idempotency_key: %Schema{type: :string}
        },
        required: [
          :owner_session_id,
          :binding_name,
          :name,
          :schedule,
          :delivery,
          :idempotency_key
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronUpdateRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ScheduleCronUpdateRequest",
        type: :object,
        minProperties: 1,
        properties: %{
          name: %Schema{type: :string, minLength: 1},
          schedule: JSONValue,
          timezone: %Schema{type: :string, nullable: true},
          payload: JSONValue,
          delivery: JSONValue
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronScheduleResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ScheduleCronScheduleResponse",
        type: :object,
        properties: %{cron_schedule: JSONValue},
        required: [:cron_schedule],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleCronScheduleListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ScheduleCronScheduleListResponse",
        type: :object,
        properties: %{cron_schedules: %Schema{type: :array, items: JSONValue}},
        required: [:cron_schedules],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleEventResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ScheduleEventResponse",
        type: :object,
        properties: %{schedule_event: JSONValue},
        required: [:schedule_event],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleEventListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ScheduleEventListResponse",
        type: :object,
        properties: %{schedule_events: %Schema{type: :array, items: JSONValue}},
        required: [:schedule_events],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ScheduleRunListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ScheduleRunListResponse",
        type: :object,
        properties: %{schedule_runs: %Schema{type: :array, items: JSONValue}},
        required: [:schedule_runs],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WebhookEndpointItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WebhookEndpointItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          agent_uid: %Schema{type: :string},
          binding_name: %Schema{type: :string},
          session_id: %Schema{type: :string},
          signal_channel_id: %Schema{type: :string, nullable: true},
          provider_thread_id: %Schema{type: :string, nullable: true},
          source_actor_event_id: %Schema{type: :string, format: :uuid, nullable: true},
          source_entry_id: %Schema{type: :string, nullable: true},
          source_provenance: JSONValue,
          automation_job_id: %Schema{
            type: :integer,
            minimum: 1000,
            maximum: 9_007_199_254_740_991,
            nullable: true
          },
          label: %Schema{type: :string},
          mode: %Schema{type: :string, enum: ["one_shot", "standing"]},
          status: %Schema{
            type: :string,
            enum: ["armed", "active", "fired", "expired", "cancelled"]
          },
          expires_at: %Schema{type: :string, format: :"date-time"},
          fired_at: %Schema{type: :string, format: :"date-time", nullable: true},
          cancelled_at: %Schema{type: :string, format: :"date-time", nullable: true},
          created_at: %Schema{type: :string, format: :"date-time"},
          updated_at: %Schema{type: :string, format: :"date-time"}
        },
        required: [
          :id,
          :agent_uid,
          :binding_name,
          :session_id,
          :label,
          :mode,
          :status,
          :expires_at,
          :created_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WebhookEndpointResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WebhookEndpointResponse",
        type: :object,
        properties: %{webhook_endpoint: WebhookEndpointItem},
        required: [:webhook_endpoint],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WebhookEndpointListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WebhookEndpointListResponse",
        type: :object,
        properties: %{
          webhook_endpoints: %Schema{type: :array, items: WebhookEndpointItem}
        },
        required: [:webhook_endpoints],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AutomationJobRunItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AutomationJobRunItem",
        type: :object,
        properties: %{
          id: %Schema{type: :integer, minimum: 1000, maximum: 9_007_199_254_740_991},
          status: %Schema{
            type: :string,
            enum: ["queued", "running", "succeeded", "failed", "cancelled"]
          },
          attempts: %Schema{type: :integer, minimum: 0},
          started_at: %Schema{type: :string, format: :"date-time", nullable: true},
          finished_at: %Schema{type: :string, format: :"date-time", nullable: true},
          exit_code: %Schema{type: :integer, nullable: true},
          error: %Schema{type: :string, nullable: true},
          stdout: %Schema{type: :string},
          stderr: %Schema{type: :string}
        },
        required: [:id, :status, :attempts, :stdout, :stderr],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AutomationJobItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AutomationJobItem",
        type: :object,
        properties: %{
          id: %Schema{type: :integer, minimum: 1000, maximum: 9_007_199_254_740_991},
          agent_uid: %Schema{type: :string},
          owner_session_id: %Schema{type: :string},
          source_actor_event_id: %Schema{type: :string, format: :uuid, nullable: true},
          source_entry_id: %Schema{type: :string, nullable: true},
          source_provenance: JSONValue,
          reply_route: JSONValue,
          directory_path: %Schema{type: :string},
          label: %Schema{type: :string},
          wake_on_failure: %Schema{type: :boolean},
          status: %Schema{type: :string, enum: ["active", "cancelled", "expired"]},
          expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
          cancelled_at: %Schema{type: :string, format: :"date-time", nullable: true},
          created_at: %Schema{type: :string, format: :"date-time"},
          updated_at: %Schema{type: :string, format: :"date-time"},
          runs: %Schema{type: :array, items: AutomationJobRunItem}
        },
        required: [
          :id,
          :agent_uid,
          :owner_session_id,
          :source_provenance,
          :reply_route,
          :directory_path,
          :label,
          :wake_on_failure,
          :status,
          :created_at,
          :updated_at,
          :runs
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AutomationJobResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AutomationJobResponse",
        type: :object,
        properties: %{automation_job: AutomationJobItem},
        required: [:automation_job],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AutomationJobListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AutomationJobListResponse",
        type: :object,
        properties: %{
          automation_jobs: %Schema{type: :array, items: AutomationJobItem}
        },
        required: [:automation_jobs],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentSession do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentSession",
        type: :object,
        description: "One actor session surfaced from durable schedule, event, or job rows.",
        properties: %{
          session_id: %Schema{type: :string},
          kind: %Schema{
            type: :string,
            enum: ["job", "session"],
            description: "`job` marks a background-agent-job session (id `\"job:<id>\"`)."
          },
          title: %Schema{type: :string, nullable: true},
          status: %Schema{type: :string, nullable: true},
          last_activity_at: %Schema{type: :string, nullable: true}
        },
        required: [:session_id, :kind],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentSessionListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentSessionListResponse",
        type: :object,
        properties: %{sessions: %Schema{type: :array, items: AgentSession}},
        required: [:sessions],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayCredentialPoolEntry do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayCredentialPoolEntry",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          label: %Schema{type: :string},
          source: %Schema{type: :string},
          priority: %Schema{type: :integer},
          disabled_at: %Schema{type: :string, nullable: true},
          credential_present: %Schema{type: :boolean},
          status: %Schema{type: :string, enum: ~w(ok exhausted dead disabled)},
          retry_at: %Schema{type: :string, nullable: true},
          request_count: %Schema{type: :integer},
          rate_limits: %Schema{type: :object, additionalProperties: true},
          usage: %Schema{type: :object, additionalProperties: true},
          last_selected_at: %Schema{type: :string, nullable: true},
          last_error_code: %Schema{type: :string, nullable: true},
          last_error_reason: %Schema{type: :string, nullable: true},
          last_error_message: %Schema{type: :string, nullable: true},
          provider_status: %Schema{type: :integer, nullable: true},
          reauth_required: %Schema{type: :boolean},
          account_id: %Schema{type: :string, nullable: true},
          plan_type: %Schema{type: :string, nullable: true},
          email: %Schema{type: :string, nullable: true},
          last_refresh: %Schema{type: :string, nullable: true},
          auth_type: %Schema{type: :string, nullable: true}
        },
        required: [
          :id,
          :label,
          :source,
          :priority,
          :disabled_at,
          :credential_present,
          :status,
          :request_count,
          :rate_limits,
          :usage,
          :last_selected_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayCredentialPool do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayCredentialPool",
        type: :object,
        properties: %{
          strategy: %Schema{
            type: :string,
            enum: ~w(fill_first round_robin least_used random)
          },
          entries: %Schema{type: :array, items: AIGatewayCredentialPoolEntry}
        },
        required: [:strategy, :entries],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayProviderItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          provider_id: %Schema{type: :string},
          provider_kind: %Schema{type: :string},
          base_url: %Schema{type: :string, nullable: true},
          connection_options: %Schema{type: :object, additionalProperties: true},
          credential_pool: AIGatewayCredentialPool,
          disabled_at: %Schema{type: :string, nullable: true},
          provider_metadata: %Schema{type: :object, additionalProperties: true}
        },
        required: [
          :id,
          :provider_id,
          :provider_kind,
          :connection_options,
          :credential_pool,
          :provider_metadata
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayProviderListResponse",
        type: :object,
        properties: %{
          ai_gateway_providers: %Schema{type: :array, items: AIGatewayProviderItem}
        },
        required: [:ai_gateway_providers],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayProviderResponse",
        type: :object,
        properties: %{
          ai_gateway_provider: AIGatewayProviderItem
        },
        required: [:ai_gateway_provider],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayProviderWriteRequest",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          provider_kind: %Schema{type: :string},
          base_url: %Schema{type: :string, nullable: true},
          connection_options: %Schema{type: :object, additionalProperties: true},
          credential_pool: %Schema{type: :object, additionalProperties: true}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayCredentialWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayCredentialWriteRequest",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          label: %Schema{type: :string},
          priority: %Schema{type: :integer},
          disabled_at: %Schema{type: :string, nullable: true}
        },
        additionalProperties: true
      },
      struct?: false
    )
  end

  defmodule AIGatewayCredentialStrategyWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayCredentialStrategyWriteRequest",
        type: :object,
        properties: %{
          strategy: %Schema{
            type: :string,
            enum: ~w(fill_first round_robin least_used random)
          }
        },
        required: [:strategy],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayChatGPTLoginStartRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayChatGPTLoginStartRequest",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          label: %Schema{type: :string},
          priority: %Schema{type: :integer}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayChatGPTLoginPollRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayChatGPTLoginPollRequest",
        type: :object,
        properties: %{
          login_context: %Schema{type: :object, additionalProperties: true}
        },
        required: [:login_context],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayChatGPTBrowserLoginRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayChatGPTBrowserLoginRequest",
        type: :object,
        properties: %{
          login_context: %Schema{type: :object, additionalProperties: true},
          callback_url: %Schema{type: :string}
        },
        required: [:login_context, :callback_url],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayChatGPTEnterpriseCredentialRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayChatGPTEnterpriseCredentialRequest",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          label: %Schema{type: :string},
          priority: %Schema{type: :integer},
          access_token: %Schema{type: :string},
          account_id: %Schema{type: :string},
          plan_type: %Schema{type: :string},
          email: %Schema{type: :string},
          fedramp: %Schema{type: :boolean}
        },
        required: [:access_token, :account_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayChatGPTLoginResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayChatGPTLoginResponse",
        type: :object,
        additionalProperties: true
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderKindItem do
    @moduledoc false

    require OpenAPISpex

    defmodule Setting do
      @moduledoc false

      require OpenAPISpex

      OpenAPISpex.schema(
        %{
          title: "AIGatewayProviderSetting",
          type: :object,
          properties: %{
            key: %Schema{type: :string},
            type: %Schema{
              type: :string,
              enum: ["boolean", "float", "integer", "map", "select", "string"]
            },
            default: JSONValue,
            options: %Schema{type: :array, items: %Schema{type: :string}},
            required: %Schema{type: :boolean},
            encrypted: %Schema{type: :boolean},
            advanced: %Schema{type: :boolean},
            scope: %Schema{type: :string, enum: ["connection", "credential", "request"]}
          },
          required: [:key, :type, :default, :options, :required, :encrypted, :advanced, :scope],
          additionalProperties: false
        },
        struct?: false
      )
    end

    OpenAPISpex.schema(
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
            items: Setting
          },
          capability_specs: %Schema{
            type: :array,
            items: %Schema{type: :object, additionalProperties: true}
          },
          connection_options: %Schema{type: :array, items: %Schema{type: :string}},
          credential_options: %Schema{type: :array, items: %Schema{type: :string}},
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
          :credential_options,
          :runtime_provider_options
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayProviderKindListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayProviderKindListResponse",
        type: :object,
        properties: %{
          provider_kinds: %Schema{type: :array, items: AIGatewayProviderKindItem}
        },
        required: [:provider_kinds],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ModelProfilesResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ModelProfilesResponse",
        type: :object,
        properties: %{
          model_profiles: %Schema{type: :object, additionalProperties: true}
        },
        required: [:model_profiles],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ModelProfileResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ModelProfileResponse",
        type: :object,
        properties: %{
          model_profile: %Schema{type: :object, additionalProperties: true}
        },
        required: [:model_profile],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ModelProfileWriteRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ModelProfileWriteRequest",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          model: %Schema{type: :string},
          description: %Schema{type: :string, maxLength: 200},
          context_length: %Schema{type: :integer, minimum: 1},
          provider_options: %Schema{type: :object, additionalProperties: true}
        },
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentComputerWorkerItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentComputerWorkerItem",
        type: :object,
        properties: %{
          worker_id: %Schema{type: :string},
          status: %Schema{
            type: :string,
            enum: ["ready", "stale", "draining", "stopped"]
          },
          version: %Schema{type: :string},
          capacity: %Schema{type: :object, additionalProperties: true},
          load: %Schema{type: :object, additionalProperties: true},
          last_worker_heartbeat_at: %Schema{type: :string, nullable: true},
          started_at: %Schema{type: :string, nullable: true},
          stopped_at: %Schema{type: :string, nullable: true},
          stop_reason: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [
          :worker_id,
          :status,
          :version,
          :capacity,
          :load,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleReadinessProvider do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleReadinessProvider",
        type: :object,
        properties: %{
          complete: %Schema{type: :boolean},
          provider_id: %Schema{type: :string, nullable: true}
        },
        required: [:complete, :provider_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleReadinessAgent do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleReadinessAgent",
        type: :object,
        properties: %{
          complete: %Schema{type: :boolean},
          uid: %Schema{type: :string, nullable: true},
          display_name: %Schema{type: :string, nullable: true}
        },
        required: [:complete, :uid, :display_name],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleReadinessModelProfiles do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleReadinessModelProfiles",
        type: :object,
        properties: %{
          complete: %Schema{type: :boolean},
          agent_uid: %Schema{type: :string, nullable: true},
          missing_profiles: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [:complete, :agent_uid, :missing_profiles],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleReadinessWorker do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleReadinessWorker",
        type: :object,
        properties: %{
          complete: %Schema{type: :boolean},
          ready_count: %Schema{type: :integer, minimum: 0}
        },
        required: [:complete, :ready_count],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleReadinessSignalRoute do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleReadinessSignalRoute",
        type: :object,
        properties: %{
          complete: %Schema{type: :boolean},
          agent_uid: %Schema{type: :string, nullable: true}
        },
        required: [:complete, :agent_uid],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConsoleReadinessResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "ConsoleReadinessResponse",
        type: :object,
        properties: %{
          ready: %Schema{type: :boolean},
          completed_core_steps: %Schema{type: :integer, minimum: 0},
          total_core_steps: %Schema{type: :integer, minimum: 1},
          provider: ConsoleReadinessProvider,
          agent: ConsoleReadinessAgent,
          model_profiles: ConsoleReadinessModelProfiles,
          worker: ConsoleReadinessWorker,
          signal_route: ConsoleReadinessSignalRoute
        },
        required: [
          :ready,
          :completed_core_steps,
          :total_core_steps,
          :provider,
          :agent,
          :model_profiles,
          :worker,
          :signal_route
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AgentComputerWorkerListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AgentComputerWorkerListResponse",
        type: :object,
        properties: %{
          workers: %Schema{type: :array, items: AgentComputerWorkerItem}
        },
        required: [:workers],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileEntry do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileEntry",
        type: :object,
        properties: %{
          relative_path: %Schema{type: :string},
          kind: %Schema{type: :string, enum: ["file", "directory", "other"]},
          size: %Schema{type: :integer},
          modified_unix_ms: %Schema{type: :integer}
        },
        required: [:relative_path, :kind, :size, :modified_unix_ms],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileListData do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileListData",
        type: :object,
        properties: %{
          root: %Schema{
            type: :string,
            enum: Ankole.WorkerFiles.roots()
          },
          path: %Schema{type: :string},
          entries: %Schema{type: :array, items: WorkerFileEntry},
          truncated: %Schema{type: :boolean}
        },
        required: [:root, :path, :entries, :truncated],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileListResponse",
        type: :object,
        properties: %{
          file_listing: WorkerFileListData
        },
        required: [:file_listing],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileUploadRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileUploadRequest",
        type: :object,
        properties: %{
          root: %Schema{
            type: :string,
            enum: Ankole.WorkerFiles.roots()
          },
          path: %Schema{type: :string},
          file: %Schema{type: :string, format: :binary}
        },
        required: [:root, :path, :file],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileUploadResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileUploadResponse",
        type: :object,
        properties: %{
          uploaded_file: %Schema{
            type: :object,
            properties: %{
              root: %Schema{
                type: :string,
                enum: Ankole.WorkerFiles.roots()
              },
              relative_path: %Schema{type: :string},
              size: %Schema{type: :integer},
              xxh3_128: %Schema{type: :string, nullable: true}
            },
            required: [:root, :relative_path, :size],
            additionalProperties: false
          }
        },
        required: [:uploaded_file],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileMoveRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileMoveRequest",
        type: :object,
        properties: %{
          root: %Schema{
            type: :string,
            enum: Ankole.WorkerFiles.roots()
          },
          from_path: %Schema{type: :string},
          to_path: %Schema{type: :string},
          overwrite: %Schema{type: :boolean}
        },
        required: [:root, :from_path, :to_path],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileMoveResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileMoveResponse",
        type: :object,
        properties: %{
          moved_file: %Schema{
            type: :object,
            properties: %{
              root: %Schema{
                type: :string,
                enum: Ankole.WorkerFiles.roots()
              },
              from_relative_path: %Schema{type: :string},
              to_relative_path: %Schema{type: :string},
              moved: %Schema{type: :boolean}
            },
            required: [:root, :from_relative_path, :to_relative_path, :moved],
            additionalProperties: false
          }
        },
        required: [:moved_file],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkerFileDeleteResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "WorkerFileDeleteResponse",
        type: :object,
        properties: %{
          deleted_file: %Schema{
            type: :object,
            properties: %{
              root: %Schema{
                type: :string,
                enum: Ankole.WorkerFiles.roots()
              },
              relative_path: %Schema{type: :string},
              deleted: %Schema{type: :boolean}
            },
            required: [:root, :relative_path, :deleted],
            additionalProperties: false
          }
        },
        required: [:deleted_file],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnUsageBreakdown do
    @moduledoc false
    require OpenAPISpex

    @token_count %Schema{type: :integer, minimum: 0}

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnUsageBreakdown",
        type: :object,
        properties: %{
          total_tokens: @token_count,
          input_tokens: @token_count,
          cached_input_tokens: @token_count,
          output_tokens: @token_count,
          reasoning_output_tokens: @token_count
        },
        required: [
          :total_tokens,
          :input_tokens,
          :cached_input_tokens,
          :output_tokens,
          :reasoning_output_tokens
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnUsage do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnUsage",
        type: :object,
        properties: %{
          thread_total: BackgroundAgentJobTurnUsageBreakdown,
          last_model_call: BackgroundAgentJobTurnUsageBreakdown,
          model_context_window: %Schema{type: :integer, minimum: 0}
        },
        required: [:thread_total, :last_model_call],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnToolUsage do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnToolUsage",
        type: :object,
        properties: %{
          name: %Schema{type: :string, minLength: 1},
          calls: %Schema{type: :integer, minimum: 0}
        },
        required: [:name, :calls],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnPlanStep do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnPlanStep",
        type: :object,
        properties: %{
          step: %Schema{type: :string, minLength: 1},
          status: %Schema{type: :string, enum: ["pending", "in_progress", "completed"]}
        },
        required: [:step, :status],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnPlan do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnPlan",
        type: :object,
        properties: %{
          explanation: %Schema{type: :string},
          steps: %Schema{type: :array, items: BackgroundAgentJobTurnPlanStep, maxItems: 100}
        },
        required: [:steps],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnActiveItem do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnActiveItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string, minLength: 1},
          name: %Schema{type: :string, minLength: 1}
        },
        required: [:id, :name],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnProgress do
    @moduledoc false
    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnProgress",
        type: :object,
        properties: %{
          completed_items: %Schema{type: :integer, minimum: 0},
          tool_calls: %Schema{type: :integer, minimum: 0},
          tools_used: %Schema{type: :array, items: BackgroundAgentJobTurnToolUsage, maxItems: 128},
          files_changed: %Schema{type: :array, items: %Schema{type: :string}, maxItems: 1024},
          plan: BackgroundAgentJobTurnPlan,
          active_item: BackgroundAgentJobTurnActiveItem
        },
        required: [:completed_items, :tool_calls, :tools_used, :files_changed],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobTurnItem do
    @moduledoc false

    require OpenAPISpex

    @kinds Ankole.BackgroundAgentJobs.Schemas.Turn.kinds()
    @statuses Ankole.BackgroundAgentJobs.Schemas.Turn.statuses()

    @content_part %Schema{
      type: :object,
      properties: %{type: %Schema{type: :string}},
      required: [:type],
      additionalProperties: true
    }
    @user_content %Schema{
      oneOf: [
        %Schema{type: :string},
        %Schema{type: :array, items: @content_part}
      ]
    }
    @tool_call %Schema{
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        type: %Schema{type: :string, enum: ["function"]},
        function: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string},
            arguments: %Schema{type: :string}
          },
          required: [:name, :arguments],
          additionalProperties: true
        }
      },
      required: [:id, :type, :function],
      additionalProperties: true
    }
    @message_metadata %Schema{type: :object, additionalProperties: true}
    @message %Schema{
      oneOf: [
        %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string},
            role: %Schema{type: :string, enum: ["user", "developer"]},
            content: @user_content,
            metadata: @message_metadata
          },
          required: [:role, :content],
          additionalProperties: true
        },
        %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string},
            role: %Schema{type: :string, enum: ["assistant"]},
            content: %Schema{type: :string},
            tool_calls: %Schema{type: :array, items: @tool_call},
            metadata: @message_metadata
          },
          required: [:role, :content],
          additionalProperties: true
        },
        %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string},
            role: %Schema{type: :string, enum: ["tool"]},
            tool_call_id: %Schema{type: :string},
            name: %Schema{type: :string},
            content: %Schema{type: :string},
            metadata: @message_metadata
          },
          required: [:role, :tool_call_id, :name, :content],
          additionalProperties: true
        }
      ]
    }

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobTurnItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          attempt: %Schema{type: :integer},
          runtime_thread_id: %Schema{type: :string},
          runtime_turn_id: %Schema{type: :string},
          kind: %Schema{type: :string, enum: @kinds},
          status: %Schema{type: :string, enum: @statuses},
          revision: %Schema{type: :integer},
          trajectory: %Schema{
            type: :object,
            additionalProperties: false,
            properties: %{
              format: %Schema{type: :string, enum: ["ankole_chatml"]},
              version: %Schema{type: :integer, enum: [1]},
              messages: %Schema{
                type: :array,
                items: @message
              },
              metadata: %Schema{
                type: :object,
                properties: %{
                  redacted: %Schema{type: :boolean},
                  content_truncated: %Schema{type: :boolean},
                  max_bytes: %Schema{type: :integer},
                  omitted_items: %Schema{type: :integer},
                  omitted_messages: %Schema{type: :integer}
                },
                additionalProperties: false
              }
            },
            required: [:format, :version, :messages]
          },
          progress: BackgroundAgentJobTurnProgress,
          usage: %Schema{allOf: [BackgroundAgentJobTurnUsage], nullable: true},
          error: %Schema{type: :object, additionalProperties: true},
          started_at: %Schema{type: :string},
          completed_at: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [
          :id,
          :attempt,
          :runtime_thread_id,
          :runtime_turn_id,
          :kind,
          :status,
          :revision,
          :trajectory,
          :progress,
          :usage,
          :error,
          :started_at,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobItem do
    @moduledoc false

    require OpenAPISpex

    @statuses Ankole.BackgroundAgentJobs.Schemas.Job.statuses()

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobItem",
        type: :object,
        properties: %{
          id: %Schema{
            type: :integer,
            minimum: 1000,
            maximum: 9_007_199_254_740_991
          },
          agent_uid: %Schema{type: :string},
          owner_session_id: %Schema{type: :string},
          source_actor_event_id: %Schema{type: :string, nullable: true},
          source_tool_call_id: %Schema{type: :string},
          runtime_thread_id: %Schema{type: :string, nullable: true},
          title: %Schema{type: :string},
          task: %Schema{type: :string},
          status: %Schema{
            type: :string,
            enum: @statuses
          },
          attempts: %Schema{type: :integer},
          execution_failures: %Schema{type: :integer},
          workspace_template_id: %Schema{type: :string, nullable: true},
          model_profile: %Schema{type: :string},
          reply_route: %Schema{type: :object, additionalProperties: true},
          result: %Schema{type: :object, additionalProperties: true},
          error: %Schema{type: :object, additionalProperties: true},
          metadata: %Schema{type: :object, additionalProperties: true},
          duration_seconds: %Schema{type: :integer},
          queued_at: %Schema{type: :string, nullable: true},
          started_at: %Schema{type: :string, nullable: true},
          completed_at: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string},
          turns: %Schema{type: :array, items: BackgroundAgentJobTurnItem}
        },
        required: [
          :id,
          :agent_uid,
          :owner_session_id,
          :source_tool_call_id,
          :title,
          :task,
          :status,
          :attempts,
          :execution_failures,
          :workspace_template_id,
          :model_profile,
          :reply_route,
          :result,
          :error,
          :metadata,
          :duration_seconds,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobListItem do
    @moduledoc false

    require OpenAPISpex

    @statuses Ankole.BackgroundAgentJobs.Schemas.Job.statuses()

    # One board row. A list page carries up to 100 of these and reloads on a
    # timer, so it stays at what the board and the home panel draw. The queued
    # prompt, the result, the error, and the metadata grow with the work the job
    # did and belong to the single-job read.
    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobListItem",
        type: :object,
        properties: %{
          id: %Schema{
            type: :integer,
            minimum: 1000,
            maximum: 9_007_199_254_740_991
          },
          agent_uid: %Schema{type: :string},
          title: %Schema{type: :string},
          status: %Schema{
            type: :string,
            enum: @statuses
          },
          attempts: %Schema{type: :integer},
          execution_failures: %Schema{type: :integer},
          workspace_template_id: %Schema{type: :string, nullable: true},
          duration_seconds: %Schema{type: :integer},
          inserted_at: %Schema{type: :string}
        },
        required: [
          :id,
          :agent_uid,
          :title,
          :status,
          :attempts,
          :execution_failures,
          :workspace_template_id,
          :duration_seconds,
          :inserted_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobListResponse",
        type: :object,
        properties: %{
          jobs: %Schema{type: :array, items: BackgroundAgentJobListItem},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:jobs, :next_cursor],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobHealthResponse do
    @moduledoc false

    require OpenAPISpex

    # Reliability trend signals, not exact ledgers: the 24-hour sums read
    # recently updated Job rows. `claims_24h` counts every worker-attempt
    # claim; `execution_failures_24h` counts only failures charged to the
    # execution budget, so the gap between them is infrastructure churn.
    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobHealthResponse",
        type: :object,
        properties: %{
          oldest_queued_seconds: %Schema{type: :integer, nullable: true},
          queued_count: %Schema{type: :integer},
          running_count: %Schema{type: :integer},
          claims_24h: %Schema{type: :integer},
          execution_failures_24h: %Schema{type: :integer},
          succeeded_24h: %Schema{type: :integer},
          successor_seeded_24h: %Schema{type: :integer},
          wakeups_24h: %Schema{type: :integer},
          dead_letter_notices_24h: %Schema{type: :integer},
          window_seconds: %Schema{type: :integer}
        },
        required: [
          :oldest_queued_seconds,
          :queued_count,
          :running_count,
          :claims_24h,
          :execution_failures_24h,
          :succeeded_24h,
          :successor_seeded_24h,
          :wakeups_24h,
          :dead_letter_notices_24h,
          :window_seconds
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundAgentJobResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BackgroundAgentJobResponse",
        type: :object,
        properties: %{
          job: BackgroundAgentJobItem
        },
        required: [:job],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayConversationItem do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayConversationItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          subject_uid: %Schema{type: :string},
          conversation_key: %Schema{type: :string},
          kind: %Schema{
            type: :string,
            enum: ["signal", "dreaming", "job", "responses_api", "custom"]
          },
          display_name: %Schema{type: :string, nullable: true},
          channel_kind: %Schema{
            type: :string,
            enum: ["im_dm", "im_group", "webhook_endpoint", "issue", "alert_stream", "unknown"],
            nullable: true
          },
          signal_adapter: %Schema{type: :string, nullable: true},
          message_count: %Schema{type: :integer},
          ended_at: %Schema{type: :string, nullable: true},
          metadata: %Schema{type: :object, additionalProperties: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [
          :id,
          :subject_uid,
          :conversation_key,
          :kind,
          :display_name,
          :channel_kind,
          :signal_adapter,
          :message_count,
          :metadata,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayConversationListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayConversationListResponse",
        type: :object,
        properties: %{
          conversations: %Schema{type: :array, items: AIGatewayConversationItem},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:conversations, :next_cursor],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayConversationResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayConversationResponse",
        type: :object,
        properties: %{
          conversation: AIGatewayConversationItem
        },
        required: [:conversation],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayMessageItem do
    @moduledoc false

    require OpenAPISpex

    @types ~w(message checkpoint)
    @roles ~w(user assistant tool im_ambient)
    @statuses ~w(generating complete error retracted)

    OpenAPISpex.schema(
      %{
        title: "AIGatewayMessageItem",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          subject_uid: %Schema{type: :string},
          conversation_id: %Schema{type: :string},
          type: %Schema{type: :string, enum: @types},
          role: %Schema{type: :string, enum: @roles, nullable: true},
          status: %Schema{type: :string, enum: @statuses},
          previous_message_id: %Schema{type: :string, nullable: true},
          content: %Schema{
            type: :array,
            items: %Schema{type: :object, additionalProperties: true}
          },
          metadata: %Schema{type: :object, additionalProperties: true},
          inserted_at: %Schema{type: :string},
          updated_at: %Schema{type: :string}
        },
        required: [
          :id,
          :subject_uid,
          :conversation_id,
          :type,
          :status,
          :content,
          :metadata,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AIGatewayMessageListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "AIGatewayMessageListResponse",
        type: :object,
        properties: %{
          messages: %Schema{type: :array, items: AIGatewayMessageItem},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:messages, :next_cursor],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
