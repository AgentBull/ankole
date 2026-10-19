defmodule AnkoleWeb.Schemas.PodContent do
  @moduledoc "Browser contracts for Pod pages, sharing, and files."
  alias OpenApiSpex.Schema

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodError",
        type: :object,
        properties: %{
          code: %Schema{type: :string},
          message: %Schema{type: :string},
          details: AnkoleWeb.Schemas.PodDatabase.Value
        },
        required: [:code, :message, :details],
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
        title: "PodErrorEnvelope",
        type: :object,
        properties: %{
          error: AnkoleWeb.Schemas.PodContent.Error,
          revision: %Schema{type: :integer}
        },
        required: [:error],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Page do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPage",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          parent_id: %Schema{type: :string, nullable: true},
          private_owner_uid: %Schema{type: :string, nullable: true},
          type: %Schema{type: :string, enum: ["doc", "database", "applet", "file"]},
          title: %Schema{type: :string},
          role: %Schema{type: :string, enum: ["view", "edit", "manage"], nullable: true},
          icon: %Schema{type: :string, nullable: true},
          position: %Schema{type: :string},
          inherit_permissions: %Schema{type: :boolean},
          revision: %Schema{type: :integer},
          saved_from_message_id: %Schema{type: :string, nullable: true},
          created_at: %Schema{type: :string},
          updated_at: %Schema{type: :string},
          deleted_at: %Schema{type: :string, nullable: true},
          purge_started_at: %Schema{type: :string, nullable: true}
        },
        required: [
          :id,
          :parent_id,
          :private_owner_uid,
          :type,
          :title,
          :role,
          :icon,
          :position,
          :inherit_permissions,
          :revision,
          :saved_from_message_id,
          :created_at,
          :updated_at,
          :deleted_at,
          :purge_started_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PageResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPageResult",
        type: :object,
        properties: %{page: AnkoleWeb.Schemas.PodContent.Page},
        required: [:page],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PageList do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPageList",
        type: :object,
        properties: %{
          pages: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.Page},
          principal_uid: %Schema{type: :string}
        },
        required: [:pages, :principal_uid],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Content do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodContent",
        type: :object,
        properties: %{xml: %Schema{type: :string}, plain_text: %Schema{type: :string}},
        required: [:xml, :plain_text],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PageDetail do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPageDetail",
        type: :object,
        properties: %{
          page: AnkoleWeb.Schemas.PodContent.Page,
          content: %Schema{allOf: [AnkoleWeb.Schemas.PodContent.Content], nullable: true},
          role: %Schema{type: :string, enum: ["view", "edit", "manage"]},
          source_conversation: %Schema{
            type: :object,
            nullable: true,
            properties: %{
              id: %Schema{type: :string},
              title: %Schema{type: :string},
              message_id: %Schema{type: :string},
              deleted: %Schema{type: :boolean}
            },
            additionalProperties: false
          }
        },
        required: [:page, :content, :role, :source_conversation],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DocumentResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodDocumentResult",
        type: :object,
        properties: %{
          page: AnkoleWeb.Schemas.PodContent.Page,
          content: AnkoleWeb.Schemas.PodContent.Content
        },
        required: [:page, :content],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PageCreate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPageCreate",
        type: :object,
        properties: %{
          type: %Schema{type: :string, enum: ["doc", "database", "applet", "file"]},
          title: %Schema{type: :string},
          icon: %Schema{type: :string, nullable: true},
          parent_id: %Schema{type: :string, nullable: true},
          private_owner_uid: %Schema{type: :string, nullable: true},
          position: %Schema{type: :string},
          saved_from_message_id: %Schema{type: :string, nullable: true}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PageUpdate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPageUpdate",
        type: :object,
        properties: %{title: %Schema{type: :string}, icon: %Schema{type: :string, nullable: true}},
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PageMove do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPageMove",
        type: :object,
        properties: %{
          parent_id: %Schema{type: :string, nullable: true},
          private_owner_uid: %Schema{type: :string, nullable: true},
          position: %Schema{type: :string}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DocumentWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodDocumentWrite",
        type: :object,
        properties: %{base_revision: %Schema{type: :integer}, xml: %Schema{type: :string}},
        required: [:base_revision, :xml],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule UserStateWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodUserStateWrite",
        type: :object,
        properties: %{favorite: %Schema{type: :boolean}, visited: %Schema{type: :boolean}},
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule UserState do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodUserState",
        type: :object,
        properties: %{
          page_id: %Schema{type: :string},
          favorited_at: %Schema{type: :string, nullable: true},
          visited_at: %Schema{type: :string, nullable: true}
        },
        required: [:page_id, :favorited_at, :visited_at],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule UserStateResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodUserStateResult",
        type: :object,
        properties: %{user_state: AnkoleWeb.Schemas.PodContent.UserState},
        required: [:user_state],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Subject do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSubject",
        type: :object,
        properties: %{
          principal_uid: %Schema{type: :string},
          group_id: %Schema{type: :string},
          name: %Schema{type: :string},
          kind: %Schema{type: :string, enum: ["human", "agent", "group"]}
        },
        required: [:name, :kind],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Subjects do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSubjects",
        type: :object,
        properties: %{
          subjects: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.Subject}
        },
        required: [:subjects],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Grant do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodGrant",
        type: :object,
        properties: %{
          principal_uid: %Schema{type: :string, nullable: true},
          group_id: %Schema{type: :string, nullable: true},
          name: %Schema{type: :string},
          kind: %Schema{type: :string, enum: ["human", "agent", "group"]},
          role: %Schema{type: :string, enum: ["view", "edit", "manage"]}
        },
        required: [:principal_uid, :group_id, :role],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule GrantWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodGrantWrite",
        type: :object,
        properties: %{
          principal_uid: %Schema{type: :string, nullable: true},
          group_id: %Schema{type: :string, nullable: true},
          role: %Schema{type: :string, enum: ["view", "edit", "manage"]}
        },
        required: [:role],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Sharing do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSharing",
        type: :object,
        properties: %{
          inherit_permissions: %Schema{type: :boolean},
          sharing_version: %Schema{type: :string},
          grants: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.Grant},
          subjects: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.Subject},
          members: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                uid: %Schema{type: :string},
                display_name: %Schema{type: :string},
                type: %Schema{type: :string, enum: ["human", "agent", "system"]}
              },
              required: [:uid, :display_name, :type],
              additionalProperties: false
            }
          },
          groups: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{id: %Schema{type: :string}, name: %Schema{type: :string}},
              required: [:id, :name],
              additionalProperties: false
            }
          }
        },
        required: [:inherit_permissions, :sharing_version, :grants, :subjects, :members, :groups],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SharingWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSharingWrite",
        type: :object,
        properties: %{
          inherit_permissions: %Schema{type: :boolean},
          sharing_version: %Schema{type: :string},
          grants: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.GrantWrite}
        },
        required: [:sharing_version],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SpaceAgent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSpaceAgent",
        type: :object,
        properties: %{
          principal_uid: %Schema{type: :string},
          name: %Schema{type: :string},
          role: %Schema{type: :string, enum: ["view", "edit", "manage"]},
          group_id: %Schema{type: :string, nullable: true},
          kind: %Schema{type: :string, enum: ["agent"]}
        },
        required: [:principal_uid, :name, :role, :group_id, :kind],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Space do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSpace",
        type: :object,
        properties: %{
          role: %Schema{type: :string, enum: ["view", "edit", "manage"]},
          can_manage: %Schema{type: :boolean},
          agents: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.SpaceAgent}
        },
        required: [:role, :can_manage, :agents],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SpaceWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSpaceWrite",
        type: :object,
        properties: %{role: %Schema{type: :string, enum: ["view", "edit", "manage"]}},
        required: [:role],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SpaceAgentWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSpaceAgentWrite",
        type: :object,
        properties: %{
          principal_uid: %Schema{type: :string},
          role: %Schema{type: :string, enum: ["view", "edit", "manage"]}
        },
        required: [:principal_uid, :role],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SpaceAgentResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSpaceAgentResult",
        type: :object,
        properties: %{
          principal_uid: %Schema{type: :string},
          role: %Schema{type: :string, enum: ["view", "edit", "manage"]}
        },
        required: [:principal_uid],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule RealtimeToken do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRealtimeToken",
        type: :object,
        properties: %{
          token: %Schema{type: :string},
          principal: %Schema{
            type: :object,
            properties: %{uid: %Schema{type: :string}, name: %Schema{type: :string}},
            required: [:uid, :name],
            additionalProperties: false
          }
        },
        required: [:token, :principal],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule VersionsRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodVersionsRequest",
        type: :object,
        properties: %{
          pages: %Schema{type: :array, items: %Schema{type: :string}},
          tables: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Versions do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodVersions",
        type: :object,
        properties: %{
          pages: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{id: %Schema{type: :string}, revision: %Schema{type: :integer}},
              required: [:id, :revision],
              additionalProperties: false
            }
          },
          tables: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{id: %Schema{type: :string}, data_version: %Schema{type: :integer}},
              required: [:id, :data_version],
              additionalProperties: false
            }
          }
        },
        required: [:pages, :tables],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PageVersions do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPageVersions",
        type: :object,
        properties: %{
          versions: %Schema{type: :object, additionalProperties: %Schema{type: :integer}}
        },
        required: [:versions],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FileEntry do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFileEntry",
        type: :object,
        properties: %{
          path: %Schema{type: :string},
          sha256: %Schema{type: :string},
          size: %Schema{type: :integer},
          content_type: %Schema{type: :string, nullable: true}
        },
        required: [:path, :sha256, :size, :content_type],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FileManifest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFileManifest",
        type: :object,
        properties: %{
          page_id: %Schema{type: :string},
          revision: %Schema{type: :integer},
          files: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.FileEntry},
          routes: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [:page_id, :revision, :files],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FileUpload do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFileUpload",
        type: :object,
        properties: %{
          file: %Schema{type: :string, format: :binary},
          role: %Schema{type: :string, enum: ["file", "asset", "attachment"]},
          base_revision: %Schema{type: :integer}
        },
        required: [:file],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FileWriteResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFileWriteResult",
        type: :object,
        properties: %{
          page_id: %Schema{type: :string},
          revision: %Schema{type: :integer},
          file: AnkoleWeb.Schemas.PodContent.FileEntry,
          src: %Schema{type: :string}
        },
        required: [:page_id, :revision, :file],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PublishEntry do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPublishEntry",
        type: :object,
        properties: %{
          path: %Schema{type: :string},
          sha256: %Schema{type: :string},
          content_type: %Schema{type: :string, nullable: true}
        },
        required: [:path, :sha256],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PublishRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodPublishRequest",
        type: :object,
        properties: %{
          base_revision: %Schema{type: :integer},
          files: %Schema{type: :array, items: AnkoleWeb.Schemas.PodContent.PublishEntry}
        },
        required: [:base_revision, :files],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FileCopyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFileCopyRequest",
        type: :object,
        properties: %{
          base_revision: %Schema{type: :integer},
          message_id: %Schema{type: :string},
          path: %Schema{type: :string}
        },
        required: [:base_revision, :message_id, :path],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Empty do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodEmpty",
        type: :object,
        properties: %{},
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
