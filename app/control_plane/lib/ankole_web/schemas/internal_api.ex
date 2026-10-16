defmodule AnkoleWeb.Schemas.InternalAPI do
  @moduledoc "Build-time HTTP contracts for the browser applications."
  alias OpenApiSpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI

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
          providerID: %Schema{type: :string, nullable: true}
        },
        required: [:authenticated],
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
          displayName: ConsoleAPI.LocalizedText,
          description: %Schema{allOf: [ConsoleAPI.LocalizedText], nullable: true}
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
          displayName: ConsoleAPI.LocalizedText,
          fields: %Schema{type: :array, items: ConsoleAPI.SignalAdapterField},
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
          agent: ConversationAgent,
          lastActivityAt: %Schema{type: :string}
        },
        required: [:id, :title, :agent, :lastActivityAt],
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
          replyToMessageID: %Schema{type: :string, nullable: true}
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
          :replyToMessageID
        ],
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
          status: ConversationStatus
        },
        required: [:conversation, :messages, :status],
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
          text: %Schema{type: :string}
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
        properties: %{messageID: %Schema{type: :string}, text: %Schema{type: :string}},
        required: [:messageID, :text],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
