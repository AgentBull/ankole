defmodule Ankole.Pod do
  @moduledoc """
  The Pod domain: the page tree, page content, and Base schemas.

  The Ash resources own the pages, page content and changes, personal page
  state, and Base tables, fields, and views. `Ankole.Pod.Pages`,
  `Ankole.Pod.Documents`, `Ankole.Pod.Files`, `Ankole.Pod.Applets`, and
  `Ankole.Pod.Bases` run their operations in top-level transactions.
  The Pod Base subsystem owns the `base_records` rows through the
  `Ankole.Pod.BaseRecord` Ecto schema, because users define their fields at
  runtime.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  defdelegate principal(uid), to: Ankole.Pod.Access

  resources do
    resource(Ankole.Principals.PodAdminOperations)
    resource(Ankole.Pod.Pages.Browser)
    resource(Ankole.Pod.Bases.Browser)
    resource(Ankole.Pod.Files.Browser)
    resource(Ankole.Pod.Chat.Browser)
    resource(AnkoleWeb.JSONAPI.PodRealtime)
    resource(Ankole.Pod.Page)
    resource(Ankole.Pod.PageContent)
    resource(Ankole.Pod.PageChange)
    resource(Ankole.Pod.PageUserState)

    resource(Ankole.Pod.BaseTable)
    resource(Ankole.Pod.BaseField)
    resource(Ankole.Pod.BaseView)
  end

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/admin", Ankole.Principals.PodAdminOperations do
        route(:get, "/settings", :settings, name: "podAdminSettings")
        route(:put, "/settings", :update_settings, name: "updatePodAdminSettings")
        route(:get, "/members", :members, name: "podAdminMembers")
        route(:post, "/members", :create_member, name: "createPodMember")
        route(:patch, "/members/:uid", :change_membership, name: "changePodMembership")
        route(:put, "/members/:uid/administrator", :set_admin, name: "setPodAdministrator")
        route(:post, "/members/:uid/restrictions", :disable_member, name: "disablePodMember")
        route(:get, "/members/:uid/access", :access_review, name: "podMemberAccessReview")
        route(:post, "/members/:uid/restorations", :restore_member, name: "restorePodMember")

        route(:delete, "/members/:uid/credentials/:credential_id", :unbind_credential,
          name: "unbindPodMemberCredential"
        )

        route(:get, "/invitations", :invitations, name: "podAdminInvitations")
        route(:post, "/invitations", :create_invitation, name: "createPodInvitation")
        route(:delete, "/invitations/:id", :revoke_invitation, name: "revokePodInvitation")
        route(:get, "/identity-providers", :providers, name: "podAdminIdentityProviders")

        route(:post, "/identity-providers/:provider_id", :create_provider,
          name: "createPodIdentityProvider"
        )

        route(:put, "/identity-providers/:provider_id", :save_provider,
          name: "savePodIdentityProvider"
        )

        route(:post, "/identity-providers/:provider_id/syncs", :sync_directory,
          name: "syncPodDirectory"
        )
      end

      base_route "/", Ankole.Pod.Chat.Browser do
        route(:get, "/agents", :agents, name: "podAgents")
        route(:get, "/teammates", :teammates, name: "podChatTeammates", query_params: [:query])

        route(:get, "/conversations", :list,
          name: "podConversations",
          query_params: [:pageID, :query, :cursor, :limit, :order]
        )

        route(:post, "/conversations", :create, name: "createConversation")

        route(:get, "/conversations/:id", :show,
          name: "conversationDetail",
          query_params: [:beforeSeq, :loadedFirstSeq]
        )

        route(:patch, "/conversations/:id", :update, name: "updateConversation")

        route(:get, "/conversations/:id/executions/:kind/:run_id", :execution,
          name: "conversationExecution",
          query_params: [:cursor]
        )

        route(:post, "/conversations/:id/participants", :manage_participants,
          name: "updateConversationParticipants"
        )

        route(
          :post,
          "/conversations/:id/interactions/:interaction_id/answer",
          :answer_interaction,
          name: "answerConversationInteraction"
        )

        route(:delete, "/conversations/:id", :delete,
          name: "deleteConversation",
          query_params: [:forceStop]
        )

        route(:post, "/conversations/:id/messages", :post_message,
          name: "postConversationMessage"
        )

        route(:post, "/conversations/:id/queue", :update_queue, name: "updateConversationQueue")
        route(:get, "/agents/:uid/model-profiles", :model_profiles, name: "podModelProfiles")

        route(:get, "/conversations/:id/model-profile", :model_selection,
          name: "podModelSelection",
          query_params: [:agentUID]
        )

        route(:put, "/conversations/:id/model-profile", :set_model_selection,
          name: "setPodModelSelection"
        )
      end

      base_route "/", AnkoleWeb.JSONAPI.PodRealtime do
        route(:get, "/realtime-token", :token, name: "podRealtimeToken")
      end

      base_route "/", Ankole.Pod.Files.Browser do
        route(:get, "/pages/:id/files", :manifest, name: "podFiles")
        route(:post, "/pages/:id/copy-file", :copy, name: "podFileCopy")
      end

      base_route "/", Ankole.Pod.Bases.Browser do
        route(:get, "/bases/:page_id", :tables, name: "podBaseTables")
        route(:post, "/bases/:page_id/tables", :create_table, name: "podBaseTableCreate")
        route(:delete, "/tables/:id", :delete_table, name: "podBaseTableDelete")
        route(:get, "/tables/:id", :show, name: "podBaseSchema")
        route(:patch, "/tables/:id", :rename_table, name: "podBaseTableRename")
        route(:post, "/tables/:id/query", :query, name: "podBaseQuery")
        route(:post, "/tables/:id/aggregate", :aggregate, name: "podBaseAggregate")
        route(:post, "/tables/:id/records", :write, name: "podBaseWrite")
        route(:post, "/tables/:id/fields", :create_field, name: "podBaseFieldCreate")
        route(:patch, "/fields/:id", :update_field, name: "podBaseFieldUpdate")

        route(:delete, "/fields/:id", :delete_field,
          name: "podBaseFieldDelete",
          query_params: [:version]
        )

        route(:post, "/tables/:id/views", :create_view, name: "podBaseViewCreate")
        route(:patch, "/views/:id", :update_view, name: "podBaseViewUpdate")

        route(:delete, "/views/:id", :delete_view,
          name: "podBaseViewDelete",
          query_params: [:version]
        )

        route(:post, "/tables/:id/copy", :copy, name: "podBaseCopy")
      end

      base_route "/", Ankole.Pod.Pages.Browser do
        route :get, "/pages", :list do
          name("podPageList")
          query_params([:scope, :query])
        end

        route(:get, "/pages/children", :children,
          name: "podPageChildren",
          query_params: [:parent_id, :scope, :cursor, :limit]
        )

        route(:get, "/pages/search", :search,
          name: "podPageSearch",
          query_params: [:query, :exclude_subtree_of, :required_action]
        )

        route :post, "/pages", :create do
          name("podPageCreate")
        end

        route :get, "/pages/:id", :show do
          name("podPageRead")
        end

        route :patch, "/pages/:id", :update do
          name("podPageUpdate")
        end

        route :delete, "/pages/:id", :delete do
          name("podPageDelete")
        end

        route :post, "/pages/:id/move", :move do
          name("podPageMove")
        end

        route :post, "/pages/:id/restore", :restore do
          name("podPageRestore")
        end

        route :post, "/pages/:id/embeds/:ref/delete", :delete_embed do
          name("podEmbedDelete")
        end

        route :put, "/pages/:id/content", :write do
          name("podDocumentWrite")
        end

        route :put, "/pages/:id/user-state", :user_state do
          name("podPageUserState")
        end

        route :get, "/pages/:id/sharing", :sharing do
          name("podPageSharing")
        end

        route :put, "/pages/:id/sharing", :set_sharing do
          name("podPageSharingWrite")
        end

        route :get, "/subjects", :subjects do
          name("podSubjects")
        end

        route :post, "/versions", :reconcile_versions do
          name("podVersions")
        end

        route :get, "/space", :space do
          name("podSpace")
        end

        route :put, "/space", :set_space do
          name("podSpaceWrite")
        end

        route :post, "/space/agents", :space_agent do
          name("podSpaceAgentWrite")
        end

        route :delete, "/space/agents/:uid", :remove_space_agent do
          name("podSpaceAgentDelete")
        end
      end
    end
  end
end
