defmodule AnkoleWeb.Schemas.InternalAPI do
  @moduledoc "Build-time HTTP contracts for the browser applications."
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenApiSpex.Schema
  alias AnkoleWeb.Schemas.InternalAPI

  defmodule JSONValue do
    @moduledoc """
    Any JSON-compatible value.
    """

    @behaviour OpenAPISpex.Schema

    # Adapter defaults can have any JSON-compatible shape.
    @impl OpenAPISpex.Schema
    def schema do
      %Schema{
        title: "JSONValue",
        nullable: true,
        description: "Any JSON-compatible value."
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
        title: "BrowserErrorDetail",
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
        title: "BrowserError",
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
        title: "BrowserErrorEnvelope",
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

  defmodule SignalAdapterFieldOption do
    alias OpenApiSpex, as: OpenAPISpex
    alias OpenAPISpex.Schema
    alias AnkoleWeb.Schemas.InternalAPI.LocalizedText

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

  defmodule SignalAdapterFieldRequirement do
    alias OpenApiSpex, as: OpenAPISpex
    alias OpenAPISpex.Schema
    alias AnkoleWeb.Schemas.InternalAPI.JSONValue

    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalAdapterFieldRequirement",
        type: :object,
        properties: %{
          path: %Schema{type: :string},
          value: JSONValue
        },
        required: [:path, :value],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalAdapterPatternValidation do
    alias OpenApiSpex, as: OpenAPISpex
    alias OpenAPISpex.Schema
    alias AnkoleWeb.Schemas.InternalAPI.LocalizedText

    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalAdapterPatternValidation",
        type: :object,
        properties: %{
          kind: %Schema{type: :string, enum: ["pattern"]},
          message: LocalizedText,
          pattern: %Schema{type: :string}
        },
        required: [:kind, :message, :pattern],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalAdapterJSONObjectValidation do
    alias OpenApiSpex, as: OpenAPISpex
    alias OpenAPISpex.Schema
    alias AnkoleWeb.Schemas.InternalAPI.LocalizedText

    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "SignalAdapterJSONObjectValidation",
        type: :object,
        properties: %{
          kind: %Schema{type: :string, enum: ["json_object"]},
          message: LocalizedText,
          requiredStringProperties: %Schema{type: :array, items: %Schema{type: :string}},
          stringPrefixes: %Schema{type: :object, additionalProperties: %Schema{type: :string}}
        },
        required: [:kind, :message],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SignalAdapterField do
    alias OpenApiSpex, as: OpenAPISpex
    alias OpenAPISpex.Schema
    alias AnkoleWeb.Schemas.InternalAPI.JSONValue
    alias AnkoleWeb.Schemas.InternalAPI.LocalizedText
    alias AnkoleWeb.Schemas.InternalAPI.SignalAdapterFieldOption
    alias AnkoleWeb.Schemas.InternalAPI.SignalAdapterFieldRequirement
    alias AnkoleWeb.Schemas.InternalAPI.SignalAdapterJSONObjectValidation
    alias AnkoleWeb.Schemas.InternalAPI.SignalAdapterPatternValidation

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
          required: %Schema{type: :boolean},
          requiredWhen: %Schema{type: :array, items: SignalAdapterFieldRequirement},
          encrypted: %Schema{type: :boolean},
          min: %Schema{type: :integer},
          max: %Schema{type: :integer},
          options: %Schema{type: :array, items: SignalAdapterFieldOption},
          validation: %Schema{
            oneOf: [SignalAdapterPatternValidation, SignalAdapterJSONObjectValidation]
          }
        },
        required: [:path, :type],
        additionalProperties: true
      },
      struct?: false
    )
  end

  defmodule AuthSessionDeleteResponse do
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

  defmodule InternalError do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "InternalError",
        type: :object,
        properties: %{error: %Schema{type: :string}, retryAfterSeconds: %Schema{type: :integer}},
        required: [:error],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule InternalOK do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "InternalOK",
        type: :object,
        properties: %{ok: %Schema{type: :boolean, enum: [true]}},
        required: [:ok],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrowserIdentity do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BrowserIdentity",
        type: :object,
        properties: %{
          displayName: %Schema{type: :string},
          providerID: %Schema{type: :string},
          principalUID: %Schema{type: :string}
        },
        required: [:displayName, :providerID],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LoginProvider do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LoginProvider",
        type: :object,
        properties: %{
          providerID: %Schema{type: :string},
          adapterID: %Schema{type: :string},
          pluginID: %Schema{type: :string, nullable: true},
          kind: %Schema{type: :string, enum: ["password", "oidc", "site"]},
          loginPath: %Schema{type: :string, nullable: true},
          displayName: %Schema{type: :string, nullable: true}
        },
        required: [:providerID, :adapterID, :pluginID, :kind],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LoginIdentity do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LoginIdentity",
        type: :object,
        properties: %{
          authenticationRef: %Schema{type: :string},
          principalUID: %Schema{type: :string},
          displayName: %Schema{type: :string},
          providerID: %Schema{type: :string}
        },
        required: [:authenticationRef, :principalUID, :displayName, :providerID],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LoginIdentitySelection do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LoginIdentitySelection",
        type: :object,
        properties: %{flow: %Schema{type: :string}, authenticationRef: %Schema{type: :string}},
        required: [:flow, :authenticationRef],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LoginProviders do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LoginProviders",
        type: :object,
        properties: %{
          providers: %Schema{type: :array, items: LoginProvider},
          identities: %Schema{type: :array, items: LoginIdentity},
          selectAccount: %Schema{type: :boolean},
          identity: %Schema{allOf: [BrowserIdentity], nullable: true}
        },
        required: [:providers, :identity, :identities, :selectAccount],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrowserTenant do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BrowserTenant",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          slug: %Schema{type: :string},
          displayName: %Schema{type: :string}
        },
        required: [:id, :slug, :displayName],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrowserAccount do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BrowserAccount",
        description: "A Pod identity that this browser has proved.",
        type: :object,
        properties: %{
          authenticationRef: %Schema{type: :string},
          principalUID: %Schema{type: :string},
          displayName: %Schema{type: :string},
          providerID: %Schema{type: :string, nullable: true},
          tenant: BrowserTenant,
          podURL: %Schema{type: :string}
        },
        required: [
          :authenticationRef,
          :principalUID,
          :displayName,
          :providerID,
          :tenant,
          :podURL
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrowserSession do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BrowserSession",
        type: :object,
        properties: %{
          authenticated: %Schema{type: :boolean},
          principalUID: %Schema{type: :string},
          providerID: %Schema{type: :string, nullable: true},
          displayName: %Schema{type: :string},
          tenant: BrowserTenant,
          consoleURL: %Schema{
            type: :string,
            nullable: true,
            description: "Present only for a site administrator."
          },
          accounts: %Schema{type: :array, items: BrowserAccount}
        },
        required: [:authenticated],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrowserAccountActivation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BrowserAccountActivation",
        type: :object,
        properties: %{authenticationRef: %Schema{type: :string}},
        required: [:authenticationRef],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BrowserAccountActivated do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BrowserAccountActivated",
        type: :object,
        properties: %{podURL: %Schema{type: :string}},
        required: [:podURL],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LocalPasswordLoginRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LocalPasswordLoginRequest",
        type: :object,
        properties: %{
          email: %Schema{type: :string},
          password: %Schema{type: :string},
          flow: %Schema{type: :string, nullable: true}
        },
        required: [:email, :password],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LocalPasswordChangeRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LocalPasswordChangeRequest",
        type: :object,
        properties: %{
          newPassword: %Schema{type: :string},
          flow: %Schema{type: :string, nullable: true}
        },
        required: [:newPassword],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LoginComplete do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LoginComplete",
        type: :object,
        properties: %{
          status: %Schema{type: :string, enum: ["ok"]},
          returnTo: %Schema{type: :string}
        },
        required: [:status, :returnTo],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PasswordChangeRequired do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PasswordChangeRequired",
        type: :object,
        properties: %{status: %Schema{type: :string, enum: ["password_change_required"]}},
        required: [:status],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule LoginResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{title: "LoginResult", oneOf: [LoginComplete, PasswordChangeRequired]},
      struct?: false
    )
  end

  defmodule LogoutConfirmation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "LogoutConfirmation",
        type: :object,
        properties: %{
          clientName: %Schema{type: :string, nullable: true},
          identity: %Schema{allOf: [BrowserIdentity], nullable: true}
        },
        required: [:clientName, :identity],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupState do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupState",
        type: :object,
        properties: %{
          completed: %Schema{type: :boolean},
          authenticated: %Schema{type: :boolean},
          currentLocale: %Schema{type: :string},
          availableLocales: %Schema{type: :array, items: %Schema{type: :string}},
          publicBaseURL: %Schema{type: :string}
        },
        required: [:completed, :authenticated, :currentLocale, :availableLocales, :publicBaseURL],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupSessionRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupSessionRequest",
        type: :object,
        properties: %{
          activationCode: %Schema{type: :string},
          activation_code: %Schema{type: :string},
          locale: %Schema{type: :string}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupPlugin do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupPlugin",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          displayName: InternalAPI.LocalizedText,
          description: %Schema{allOf: [InternalAPI.LocalizedText], nullable: true}
        },
        required: [:id, :displayName, :description],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupPlugins do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupPlugins",
        type: :object,
        properties: %{
          plugins: %Schema{type: :array, items: SetupPlugin},
          enabledPluginIDs: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [:plugins, :enabledPluginIDs],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupPluginsRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupPluginsRequest",
        type: :object,
        properties: %{pluginIDs: %Schema{type: :array, items: %Schema{type: :string}}},
        required: [:pluginIDs],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupPluginsSelection do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupPluginsSelection",
        type: :object,
        properties: %{enabledPluginIDs: %Schema{type: :array, items: %Schema{type: :string}}},
        required: [:enabledPluginIDs],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupBrainPack do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupBrainPack",
        type: :object,
        properties: %{
          name: %Schema{type: :string},
          description: %Schema{type: :string, nullable: true},
          version: %Schema{type: :string, nullable: true},
          required: %Schema{type: :boolean}
        },
        required: [:name, :description, :version, :required],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupBrainPacks do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupBrainPacks",
        type: :object,
        properties: %{
          packs: %Schema{type: :array, items: SetupBrainPack},
          selected: %Schema{type: :array, items: %Schema{type: :string}}
        },
        required: [:packs, :selected],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupBrainPackSelection do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupBrainPackSelection",
        type: :object,
        properties: %{packs: %Schema{type: :array, items: %Schema{type: :string}}},
        required: [:packs],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupIdentityAdapter do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupIdentityAdapter",
        type: :object,
        properties: %{
          adapterID: %Schema{type: :string},
          pluginID: %Schema{type: :string},
          displayName: InternalAPI.LocalizedText,
          fields: %Schema{type: :array, items: InternalAPI.SignalAdapterField},
          defaultProviderID: %Schema{type: :string}
        },
        required: [:adapterID, :pluginID, :displayName, :fields, :defaultProviderID],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupIdentityAdapters do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupIdentityAdapters",
        type: :object,
        properties: %{adapters: %Schema{type: :array, items: SetupIdentityAdapter}},
        required: [:adapters],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupIdentityProviderRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupIdentityProviderRequest",
        type: :object,
        properties: %{
          adapterID: %Schema{type: :string},
          config: %Schema{type: :object, additionalProperties: true},
          enabled: %Schema{type: :boolean}
        },
        required: [:adapterID],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupIdentityProvider do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupIdentityProvider",
        type: :object,
        properties: %{
          provider_id: %Schema{type: :string},
          adapter_id: %Schema{type: :string},
          plugin_id: %Schema{type: :string},
          config_key: %Schema{type: :string},
          enabled: %Schema{type: :boolean},
          config: %Schema{type: :object, additionalProperties: true}
        },
        required: [:provider_id, :adapter_id, :plugin_id, :config_key, :enabled, :config],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupAuthorization do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupAuthorization",
        type: :object,
        properties: %{authorizationURL: %Schema{type: :string}},
        required: [:authorizationURL],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupLocalAdminRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupLocalAdminRequest",
        type: :object,
        properties: %{
          email: %Schema{type: :string},
          password: %Schema{type: :string},
          display_name: %Schema{type: :string, nullable: true}
        },
        required: [:email, :password],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SetupComplete do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "SetupComplete",
        type: :object,
        properties: %{returnTo: %Schema{type: :string}},
        required: [:returnTo],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PodAgent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodAgent",
        type: :object,
        properties: %{uid: %Schema{type: :string}, displayName: %Schema{type: :string}},
        required: [:uid, :displayName],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PodAgents do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodAgents",
        type: :object,
        properties: %{agents: %Schema{type: :array, items: PodAgent}},
        required: [:agents],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationAgent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationAgent",
        type: :object,
        properties: %{
          uid: %Schema{type: :string},
          displayName: %Schema{type: :string},
          active: %Schema{type: :boolean}
        },
        required: [:uid, :displayName, :active],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Conversation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "Conversation",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          title: %Schema{type: :string},
          pageID: %Schema{type: :string, nullable: true},
          agent: ConversationAgent,
          lastActivityAt: %Schema{type: :string}
        },
        required: [:id, :title, :pageID, :agent, :lastActivityAt],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Conversations do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "Conversations",
        type: :object,
        properties: %{conversations: %Schema{type: :array, items: Conversation}},
        required: [:conversations],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationLink do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationLink",
        type: :object,
        properties: %{kind: %Schema{type: :string, enum: ["page"]}, id: %Schema{type: :string}},
        required: [:kind, :id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationAttachment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationAttachment",
        type: :object,
        properties: %{
          path: %Schema{type: :string},
          blob_ref: %Schema{type: :string},
          name: %Schema{type: :string},
          size: %Schema{type: :integer},
          mime_type: %Schema{type: :string},
          content_type: %Schema{type: :string},
          attachment_id: %Schema{type: :integer},
          upload_id: %Schema{type: :string},
          resource_type: %Schema{type: :string}
        },
        required: [:path, :blob_ref, :name, :size],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationMessage do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationMessage",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          seq: %Schema{type: :integer},
          authorType: %Schema{type: :string, enum: ["human", "agent", "system"]},
          authorUID: %Schema{type: :string, nullable: true},
          kind: %Schema{type: :string, enum: ["message", "notice"]},
          text: %Schema{type: :string},
          createdAt: %Schema{type: :string},
          signalID: %Schema{type: :string, nullable: true},
          replyToMessageID: %Schema{type: :string, nullable: true},
          links: %Schema{type: :array, items: ConversationLink},
          attachments: %Schema{type: :array, items: ConversationAttachment}
        },
        required: [
          :id,
          :seq,
          :authorType,
          :authorUID,
          :kind,
          :text,
          :createdAt,
          :signalID,
          :replyToMessageID,
          :links,
          :attachments
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationAttachmentUpload do
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationAttachmentUpload",
        type: :object,
        properties: %{
          file: %Schema{type: :string, format: :binary},
          fileID: %Schema{type: :string}
        },
        required: [:file, :fileID],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationAttachmentReceipt do
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationAttachmentReceipt",
        type: :object,
        properties: %{
          receipt: %Schema{type: :string},
          name: %Schema{type: :string},
          size: %Schema{type: :integer},
          content_type: %Schema{type: :string, nullable: true}
        },
        required: [:receipt, :name, :size, :content_type],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule PodActivityItem do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PodActivityItem",
      type: :object,
      required: [:operation_id],
      properties: %{
        operation_id: %Schema{type: :string},
        phase: %Schema{type: :string},
        state: %Schema{type: :string},
        consequential: %Schema{type: :boolean},
        label_key: %Schema{type: :string},
        label: %Schema{type: :string},
        label_bindings: %Schema{type: :object, additionalProperties: %Schema{type: :string}}
      }
    })
  end

  defmodule PodActivity do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PodActivity",
      type: :object,
      required: [
        :conversationID,
        :agentUID,
        :sessionID,
        :signalID,
        :responseID,
        :epoch,
        :revision,
        :state,
        :phase,
        :tools
      ],
      properties: %{
        conversationID: %Schema{type: :string},
        agentUID: %Schema{type: :string},
        sessionID: %Schema{type: :string},
        signalID: %Schema{type: :string, nullable: true},
        responseID: %Schema{type: :string, nullable: true},
        epoch: %Schema{type: :integer},
        revision: %Schema{type: :integer},
        state: %Schema{type: :string, enum: ["active", "unavailable", "settled"]},
        phase: %Schema{
          allOf: [AnkoleWeb.Schemas.InternalAPI.PodActivityItem],
          nullable: true
        },
        tools: %Schema{
          type: :array,
          maxItems: 4,
          items: AnkoleWeb.Schemas.InternalAPI.PodActivityItem
        }
      }
    })
  end

  defmodule ConversationStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationStatus",
        type: :object,
        properties: %{
          activity: AnkoleWeb.Schemas.InternalAPI.PodActivity,
          state: %Schema{type: :string, enum: ["idle", "queued", "running", "retrying"]},
          retryAt: %Schema{type: :string, nullable: true}
        },
        required: [:state, :retryAt, :activity],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationDetail do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationDetail",
        type: :object,
        properties: %{
          conversation: Conversation,
          messages: %Schema{type: :array, items: ConversationMessage},
          removedMessageIDs: %Schema{type: :array, items: %Schema{type: :string}},
          olderMessagesBeforeSeq: %Schema{type: :integer, nullable: true, minimum: 1},
          messageRange: %Schema{
            type: :object,
            properties: %{
              firstSeq: %Schema{type: :integer, minimum: 1},
              lastSeq: %Schema{type: :integer, minimum: 0}
            },
            required: [:firstSeq, :lastSeq],
            additionalProperties: false
          },
          pendingInputs: %Schema{
            type: :array,
            items: AnkoleWeb.Schemas.InternalAPI.ConversationPendingInput
          },
          queuePaused: %Schema{type: :boolean},
          queueVersion: %Schema{type: :string},
          retryableMessageID: %Schema{type: :string, nullable: true},
          status: ConversationStatus
        },
        required: [
          :conversation,
          :messages,
          :removedMessageIDs,
          :olderMessagesBeforeSeq,
          :messageRange,
          :pendingInputs,
          :queuePaused,
          :queueVersion,
          :retryableMessageID,
          :status
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationCreateRequest",
        type: :object,
        properties: %{
          conversationID: %Schema{type: :string},
          messageID: %Schema{type: :string},
          agentUID: %Schema{type: :string},
          pageID: %Schema{type: :string, nullable: true},
          modelProfile: %Schema{type: :string, nullable: true},
          text: %Schema{type: :string},
          attachments: %Schema{type: :array, items: %Schema{type: :string}},
          deliveryMode: %Schema{type: :string, enum: ["steer", "queue"]}
        },
        required: [:conversationID, :messageID, :agentUID, :text],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationMessageRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationMessageRequest",
        type: :object,
        properties: %{
          messageID: %Schema{type: :string},
          text: %Schema{type: :string},
          attachments: %Schema{type: :array, items: %Schema{type: :string}},
          deliveryMode: %Schema{type: :string, enum: ["steer", "queue"]}
        },
        required: [:messageID, :text],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationPendingInput do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationPendingInput",
        type: :object,
        properties: %{
          messageID: %Schema{type: :string},
          text: %Schema{type: :string},
          deliveryMode: %Schema{type: :string, enum: ["steer", "queue"]},
          modelProfile: %Schema{type: :string},
          attachments: %Schema{type: :array, items: ConversationAttachment}
        },
        required: [:messageID, :text, :deliveryMode, :modelProfile, :attachments],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ConversationQueueRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "ConversationQueueRequest",
        type: :object,
        properties: %{
          action: %Schema{
            type: :string,
            enum: [
              "edit",
              "send_now",
              "remove",
              "reorder",
              "stop",
              "resume",
              "regenerate",
              "edit_last"
            ]
          },
          messageID: %Schema{type: :string},
          text: %Schema{type: :string},
          messageIDs: %Schema{type: :array, items: %Schema{type: :string}},
          commandID: %Schema{type: :string},
          expectedVersion: %Schema{type: :string},
          expectedText: %Schema{type: :string, nullable: true}
        },
        required: [:action],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
