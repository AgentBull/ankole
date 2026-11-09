defmodule Ankole.Pod do
  @moduledoc """
  The Pod domain: the page tree, page content, and Base schemas.

  The Ash resources own the pages, page content and changes, personal page
  state, spreadsheet operations and file caches, and Base tables, fields, and
  views. `Ankole.Pod.Pages`, `Ankole.Pod.Documents`,
  `Ankole.Pod.Files`, `Ankole.Pod.Spreadsheets`, `Ankole.Pod.Applets`, and
  `Ankole.Pod.Bases` run their operations in top-level transactions.
  The Pod Base subsystem owns the `base_records` rows through the
  `Ankole.Pod.BaseRecord` Ecto schema, because users define their fields at
  runtime.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.Pod.Files.Content, as: NodeContents
  alias Ankole.Pod.Pages.Tree, as: Nodes

  defdelegate applet_action_package(page_id, contexts \\ [], timeout_ms \\ nil),
    to: Ankole.Pod.Applets,
    as: :action_package

  defdelegate authorize_applet(actor, page_id, permission), to: Ankole.Pod.Applets, as: :authorize

  defdelegate verify_applet_package_in_tx(package),
    to: Ankole.Pod.Applets,
    as: :verify_package_in_tx

  defdelegate invoke_applet_action(package, context, actor),
    to: Ankole.Pod.Applets,
    as: :invoke_action

  defdelegate transfer_applet_owner(actor, page_id, owner_uid),
    to: Ankole.Pod.Applets,
    as: :transfer_owner

  defdelegate release_applet_owners_for_tenant_deletion(), to: Ankole.Pod.Pages.Lifecycle

  defdelegate call_applet_function(actor, page_id, request, parent),
    to: Ankole.Pod.Applets,
    as: :call_function

  defdelegate node_committed(node), to: Nodes, as: :content_committed
  defdelegate fetch_node(id), to: Nodes, as: :fetch
  defdelegate lock_tree_in_tx(), to: Nodes, as: :lock_tree
  defdelegate lock_root_ids_in_tx(ids), to: Nodes, as: :lock_roots
  defdelegate root_ids_for_principal(uid), to: Nodes
  defdelegate root_ids_for_conversations(ids), to: Nodes
  defdelegate purge_root_jobs_in_tx(root_ids), to: Ankole.Pod.Pages.Lifecycle
  defdelegate delete_private_root_in_tx(uid), to: Nodes
  defdelegate delete_conversation_root_in_tx(id), to: Nodes
  defdelegate root(id), to: Nodes
  defdelegate root_ids(ids), to: Nodes
  defdelegate private_root(uid), to: Nodes
  defdelegate public_root(), to: Nodes
  defdelegate conversation_root(id), to: Nodes
  defdelegate ensure_private_root_in_tx(uid), to: Nodes
  defdelegate ensure_public_root_in_tx(), to: Nodes
  defdelegate ensure_conversation_root_in_tx(id), to: Nodes
  defdelegate visible_node_ids(reachable, ids \\ nil, bit \\ 1), to: Nodes, as: :visible_ids
  defdelegate page_live?(id), to: Nodes
  defdelegate ancestor_node_ids(ids), to: Nodes, as: :ancestor_ids
  defdelegate private_owners(ids), to: Nodes
  defdelegate descendant_node_ids(id), to: Nodes, as: :descendants
  defdelegate shared_root_node_ids(ids, reachable), to: Nodes, as: :shared_root_ids
  defdelegate acl_anchor_nodes(), to: Nodes, as: :anchor_nodes
  defdelegate hidden_trashed_node_ids(), to: Nodes, as: :hidden_trashed_ids
  defdelegate authorize_node(actor, id, action, opts \\ []), to: Nodes, as: :authorize
  defdelegate node_conversation_id(id), to: Nodes, as: :conversation_id
  defdelegate create_node(actor, attrs), to: Nodes, as: :create
  defdelegate move_node(actor, id, attrs), to: Nodes, as: :move
  def rename_node_in_tx(actor, id, name), do: Nodes.move_in_tx(actor, id, %{name: name})
  defdelegate write_node(actor, id, content), to: NodeContents, as: :write

  defdelegate authorize_node_write(actor, node), to: NodeContents, as: :authorize_write

  @doc """
  Writes a spreadsheet page's pending edits into its file before a reader takes
  the bytes. Runs outside a transaction; other nodes return `:ok` at once.
  """
  defdelegate flush_node(id), to: Ankole.Pod.Spreadsheets, as: :flush_if_dirty

  defdelegate commit_node_object_in_tx(actor, id, object, attrs \\ %{}),
    to: NodeContents,
    as: :commit_in_tx

  defdelegate create_conversation_file_in_tx(conversation_id, name, object, attrs \\ %{}),
    to: NodeContents

  defdelegate create_private_file_in_tx(agent_uid, name, object, attrs \\ %{}),
    to: NodeContents

  defdelegate vfs_properties(ids), to: Ankole.Pod.Pages
  defdelegate vfs_property_in_tx(node, property), to: Ankole.Pod.Pages
  defdelegate vfs_markdown(node), to: Ankole.Pod.Documents
  defdelegate write_vfs_markdown_in_tx(actor, id, markdown), to: Ankole.Pod.Documents

  defdelegate principal(uid), to: Ankole.Pod.Access

  defdelegate rename_principal_mentions_in_tx(old_uid, new_uid),
    to: Ankole.Pod.Documents.PrincipalMentions,
    as: :rename_in_tx

  defdelegate publish_principal_rename(page_ids),
    to: Ankole.Pod.Documents.PrincipalMentions,
    as: :publish

  defdelegate rename_inline_principal_in_tx(old_uid, new_uid), to: Ankole.Pod.Bases
  defdelegate repair_principal_references(tenant_id, old_uid, new_uid), to: Ankole.Pod.Bases

  defdelegate publish_base_principal_rename(changes),
    to: Ankole.Pod.Bases,
    as: :publish_principal_rename

  resources do
    resource(Ankole.AutomationJobs.Browser)
    resource(Ankole.Signals.EventBindingsBrowser)
    resource(Ankole.Principals.PodAdminOperations)
    resource(Ankole.AIAgent.Library.Browser)
    resource(Ankole.Principals.MetaBrowser)
    resource(Ankole.Brain.Browser)
    resource(Ankole.Pod.Pages.Browser)
    resource(Ankole.Pod.Applets.Browser)
    resource(Ankole.Pod.Bases.Browser)
    resource(Ankole.Pod.Files.Browser)
    resource(Ankole.Pod.Spreadsheets.Browser)
    resource(Ankole.Pod.Chat.Browser)

    resource Ankole.Pod.Page do
      define(:list_page_records, action: :read)
    end

    resource(Ankole.Pod.PodFile)
    resource(Ankole.Pod.AppletEnv)
    resource(Ankole.Pod.PageContent)
    resource(Ankole.Pod.PageChange)
    resource(Ankole.Pod.PageDailyActivity)
    resource(Ankole.Pod.PageSnapshot)
    resource(Ankole.Pod.PageComment)
    resource(Ankole.Pod.Comments.Browser)
    resource(Ankole.Pod.Documents.History.Browser)
    resource(Ankole.Pod.PageUserState)
    resource(Ankole.Pod.SpreadsheetOp)
    resource(Ankole.Pod.FileCache)
    resource(Ankole.Pod.PageSearchDocument)
    resource(Ankole.Pod.SearchQuery)

    resource(Ankole.Pod.BaseTable)
    resource(Ankole.Pod.Bases.ChangeOutbox)
    resource(Ankole.Pod.BaseField)
    resource(Ankole.Pod.BaseView)
  end

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/pages/:page_id", Ankole.AutomationJobs.Browser do
        route(:get, "/job-actions", :actions,
          name: "podAppletJobActions",
          wrap_in_result?: false
        )

        route(:get, "/jobs/:job_id/runs", :runs,
          name: "podAppletJobRuns",
          wrap_in_result?: false
        )

        route(:get, "/jobs/:job_id/schedules", :schedules_list,
          name: "podJobSchedulesList",
          wrap_in_result?: false
        )

        route(:put, "/jobs/:job_id/schedules", :schedules_put,
          name: "podJobSchedulesPut",
          wrap_in_result?: false
        )

        route(:post, "/jobs/:job_id/schedules/:id/pause", :schedules_pause,
          name: "podJobSchedulesPause",
          wrap_in_result?: false
        )

        route(:post, "/jobs/:job_id/schedules/:id/resume", :schedules_resume,
          name: "podJobSchedulesResume",
          wrap_in_result?: false
        )

        route(:post, "/jobs/:job_id/schedules/:id/run", :schedules_run,
          name: "podJobSchedulesRun",
          wrap_in_result?: false
        )

        route(:delete, "/jobs/:job_id/schedules/:id", :schedules_delete,
          name: "podJobSchedulesDelete",
          wrap_in_result?: false
        )

        route(:get, "/jobs/:job_id/schedules/:id/runs", :schedules_runs,
          name: "podJobSchedulesRuns",
          wrap_in_result?: false
        )

        route(:get, "/jobs/:job_id/webhooks", :webhooks_list,
          name: "podJobWebhooksList",
          wrap_in_result?: false
        )

        route(:post, "/jobs/:job_id/webhooks", :webhooks_create,
          name: "podJobWebhooksCreate",
          wrap_in_result?: false
        )

        route(:patch, "/jobs/:job_id/webhooks/:id", :webhooks_update,
          name: "podJobWebhooksUpdate",
          wrap_in_result?: false
        )

        route(:post, "/jobs/:job_id/webhooks/:id/pause", :webhooks_pause,
          name: "podJobWebhooksPause",
          wrap_in_result?: false
        )

        route(:post, "/jobs/:job_id/webhooks/:id/resume", :webhooks_resume,
          name: "podJobWebhooksResume",
          wrap_in_result?: false
        )

        route(:post, "/jobs/:job_id/webhooks/:id/cancel", :webhooks_cancel,
          name: "podJobWebhooksCancel",
          wrap_in_result?: false
        )

        route(:delete, "/jobs/:job_id/webhooks/:id", :webhooks_delete,
          name: "podJobWebhooksDelete",
          wrap_in_result?: false
        )

        route(:get, "/jobs", :list, name: "podAppletJobs", wrap_in_result?: false)
        route(:post, "/jobs", :create, name: "podAppletJobCreate", wrap_in_result?: false)

        route(:patch, "/jobs/:id", :configure,
          name: "podAppletJobConfigure",
          wrap_in_result?: false
        )

        route(:delete, "/jobs/:id", :delete, name: "podAppletJobDelete", wrap_in_result?: false)
        route(:get, "/runs/:id", :run, name: "podAppletRun", wrap_in_result?: false)
      end

      base_route "/pages/:page_id", Ankole.Pod.Pages.Browser do
        route(:put, "/applet-owner", :transfer_owner,
          name: "podAppletOwner",
          wrap_in_result?: false
        )
      end

      base_route "/pages/:page_id", Ankole.Pod.Applets.Browser do
        route(:get, "/functions", :functions,
          name: "podAppletFunctions",
          wrap_in_result?: false
        )

        route(:get, "/envs/status", :status,
          name: "podAppletEnvStatus",
          wrap_in_result?: false
        )

        route(:get, "/envs", :list,
          name: "podAppletEnvs",
          wrap_in_result?: false
        )

        route(:put, "/envs/:name", :put,
          name: "podAppletEnvPut",
          wrap_in_result?: false
        )

        route(:delete, "/envs/:name", :delete,
          name: "podAppletEnvDelete",
          wrap_in_result?: false
        )

        route(:post, "/envs/:name/decryptions", :decrypt,
          name: "podAppletEnvDecrypt",
          wrap_in_result?: false
        )
      end

      base_route "/signal-bindings", Ankole.Signals.EventBindingsBrowser do
        route(:get, "/", :list, name: "podEventBindings", wrap_in_result?: false)
        route(:put, "/", :put, name: "podEventBindingPut", wrap_in_result?: false)
      end

      base_route "/meta/agents", Ankole.Principals.MetaBrowser do
        route(:get, "/", :list, name: "metaAgents", wrap_in_result?: false)
        route(:post, "/", :create, name: "metaCreateAgent", wrap_in_result?: false)
        route(:get, "/:uid", :show, name: "metaAgent", wrap_in_result?: false)
        route(:patch, "/:uid", :update, name: "metaUpdateAgent", wrap_in_result?: false)
      end

      base_route "/meta/brain", Ankole.Brain.Browser do
        route(:get, "/", :graph, name: "metaBrain", wrap_in_result?: false)
      end

      base_route "/meta", Ankole.AIAgent.Library.Browser do
        route(:get, "/skills", :list, name: "metaSkills", wrap_in_result?: false)
        route(:post, "/skills", :create, name: "metaCreateSkill", wrap_in_result?: false)
        route(:post, "/skills/import", :import, name: "metaImportSkill", wrap_in_result?: false)
        route(:get, "/skills/:slug", :detail, name: "metaSkill", wrap_in_result?: false)
        route(:put, "/skills/:slug", :save, name: "metaSaveSkill", wrap_in_result?: false)

        route(:delete, "/skills/:slug", :delete,
          name: "metaDeleteSkill",
          query_params: [:base_revision],
          wrap_in_result?: false
        )

        route(:put, "/skills/:slug/all", :set_all,
          name: "metaSkillSetAll",
          wrap_in_result?: false
        )

        route(:put, "/skills/:slug/bindings", :set_binding,
          name: "metaSkillSetBinding",
          wrap_in_result?: false
        )

        route(:get, "/skills/:slug/file", :read_file,
          name: "metaSkillFile",
          query_params: [:path],
          wrap_in_result?: false
        )

        route(:put, "/skills/:slug/file", :put_file,
          name: "metaSkillPutFile",
          wrap_in_result?: false
        )

        route(:patch, "/skills/:slug/file", :change_file,
          name: "metaSkillChangeFile",
          wrap_in_result?: false
        )

        route(:get, "/agents/:uid/contracts", :contracts,
          name: "metaAgentContracts",
          wrap_in_result?: false
        )

        route(:put, "/agents/:uid/contracts/:slot", :save_contract,
          name: "metaSaveAgentContract",
          wrap_in_result?: false
        )

        route(:get, "/contracts", :global_contracts,
          name: "metaGlobalContracts",
          wrap_in_result?: false
        )

        route(:put, "/contracts/:slot", :save_global_contract,
          name: "metaSaveGlobalContract",
          wrap_in_result?: false
        )
      end

      base_route "/comments", Ankole.Pod.Comments.Browser do
        route(:get, "/attention", :attention, name: "podCommentAttention")
      end

      base_route "/pages/:id/comments", Ankole.Pod.Comments.Browser do
        route(:get, "/", :list, name: "podPageComments", query_params: [:status, :cursor, :limit])
        route(:get, "/summary", :summary, name: "podPageCommentSummary")
        route(:get, "/:comment_id", :show, name: "podCommentRead")
        route(:put, "/read", :acknowledge, name: "podPageCommentsRead")
        route(:post, "/", :create, name: "podPageCommentCreate")
        route(:patch, "/:comment_id", :update, name: "podPageCommentUpdate")

        route(:delete, "/:comment_id", :delete,
          name: "podPageCommentDelete",
          query_params: [:version]
        )

        route(:put, "/:comment_id/resolution", :resolve, name: "podPageCommentResolve")
        route(:put, "/:comment_id/anchor", :anchor, name: "podPageCommentAnchor")
      end

      base_route "/pages/:id/history", Ankole.Pod.Documents.History.Browser do
        route(:get, "/", :list, name: "podPageHistory", query_params: [:cursor, :limit])
        route(:get, "/:snapshot_id", :show, name: "podPageHistoryEntry")
        route(:post, "/:snapshot_id/restore", :restore, name: "podPageHistoryRestore")
      end

      base_route "/admin", Ankole.Principals.PodAdminOperations do
        route(:get, "/settings", :settings, name: "podAdminSettings")
        route(:put, "/settings", :update_settings, name: "updatePodAdminSettings")
        route(:get, "/members", :members, name: "podAdminMembers")
        route(:post, "/members", :create_member, name: "createPodMember")
        route(:patch, "/members/:uid", :change_membership, name: "changePodMembership")
        route(:post, "/members/:uid/rename", :rename_member, name: "renamePodMember")
        route(:get, "/agents", :agents, name: "podAdminAgents")
        route(:post, "/agents/:uid/disable", :disable_agent, name: "disablePodAgent")
        route(:post, "/agents/:uid/enable", :enable_agent, name: "enablePodAgent")
        route(:post, "/agents/:uid/rename", :rename_agent, name: "renamePodAgent")
        route(:put, "/members/:uid/administrator", :set_admin, name: "setPodAdministrator")
        route(:post, "/members/:uid/restrictions", :disable_member, name: "disablePodMember")
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

        route(:get, "/worker-envs", :worker_envs, name: "podAdminWorkerEnvs")
        route(:put, "/worker-envs/:name", :put_worker_env, name: "putPodAdminWorkerEnv")
        route(:delete, "/worker-envs/:name", :delete_worker_env, name: "deletePodAdminWorkerEnv")

        route(:post, "/worker-envs/:name/decryptions", :decrypt_worker_env,
          name: "decryptPodAdminWorkerEnv"
        )
      end

      base_route "/", Ankole.Pod.Chat.Browser do
        route(:get, "/agents", :agents, name: "podAgents")

        route(:post, "/personal-assistant", :ensure_personal_assistant,
          name: "ensurePodPersonalAssistant"
        )

        route(:get, "/teammates", :teammates, name: "podChatTeammates", query_params: [:query])

        route(:get, "/conversations/attention", :attention, name: "podConversationAttention")

        route(:post, "/next-steps", :next_steps, name: "podNextSteps")
        route(:post, "/next-steps/:id/choose", :choose_next_step, name: "choosePodNextStep")

        route(:post, "/conversations/:id/reply-suggestion", :reply_suggestion,
          name: "podReplySuggestion"
        )

        route(:get, "/conversations", :list,
          name: "podConversations",
          query_params: [:pageID, :query, :cursor, :limit, :order]
        )

        route(:post, "/conversations", :create, name: "createConversation")

        route(:get, "/conversations/:id/peer-exchanges/:exchange_id", :peer_exchange,
          name: "podPeerExchange",
          query_params: [:cursor]
        )

        route(:post, "/conversations/:id/peer-exchanges/:exchange_id/stop", :stop_peer_exchange,
          name: "stopPodPeerExchange"
        )

        route(:get, "/conversations/:id", :show,
          name: "conversationDetail",
          query_params: [:beforeSeq, :loadedFirstSeq]
        )

        route(:patch, "/conversations/:id", :update, name: "updateConversation")

        route(:get, "/conversations/:id/executions/:kind/:run_id", :execution,
          name: "conversationExecution",
          query_params: [:cursor]
        )

        route(:post, "/conversations/:id/executions/:kind/:run_id/stop", :stop_execution,
          name: "stopConversationExecution"
        )

        route(
          :post,
          "/conversations/:id/executions/background_agent_job/:run_id/messages",
          :message_execution,
          name: "messageConversationExecution"
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

        route(
          :post,
          "/conversations/:id/action-cards/:card_id/resolve",
          :resolve_action_card,
          name: "resolveConversationActionCard"
        )

        route(:get, "/action-cards/:card_id", :show_action_card, name: "getPodActionCard")

        route(:get, "/interactions/:interaction_id", :show_interaction, name: "getPodInteraction")

        route(
          :post,
          "/interactions/:interaction_id/answer",
          :answer_standalone_interaction,
          name: "answerPodInteraction"
        )

        route(
          :post,
          "/action-cards/:card_id/resolve",
          :resolve_standalone_action_card,
          name: "resolvePodActionCard"
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

      base_route "/", Ankole.Pod.Files.Browser do
        route(:get, "/pages/:id/files", :manifest, name: "podFiles")
        route(:post, "/pages/:id/copy-file", :copy, name: "podFileCopy")
      end

      base_route "/", Ankole.Pod.Spreadsheets.Browser do
        route(:post, "/spreadsheet-pages", :create, name: "podSpreadsheetCreate")
        route(:get, "/pages/:id/spreadsheet", :bootstrap, name: "podSpreadsheet")
        route(:get, "/pages/:id/spreadsheet/versions", :versions, name: "podSpreadsheetVersions")

        route(:post, "/pages/:id/spreadsheet/versions/:version_id/restore", :restore,
          name: "podSpreadsheetRestore"
        )
      end

      base_route "/", Ankole.Pod.Bases.Browser do
        route(:get, "/bases/:page_id", :tables, name: "podBaseTables")
        route(:post, "/bases/:page_id/tables", :create_table, name: "podBaseTableCreate")
        route(:delete, "/tables/:id", :delete_table, name: "podBaseTableDelete")
        route(:get, "/tables/:id", :show, name: "podBaseSchema")
        route(:patch, "/tables/:id", :rename_table, name: "podBaseTableRename")
        route(:put, "/tables/:id/settings", :configure_table, name: "podBaseTableConfigure")
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
          query_params([:scope, :domain, :query])
        end

        route(:get, "/pages/children", :children,
          name: "podPageChildren",
          query_params: [:parent_id, :scope, :cursor, :limit, :details]
        )

        route(:get, "/pages/navigation", :navigation,
          name: "podPageNavigation",
          query_params: [:active_page_id]
        )

        route(:get, "/pages/search", :search,
          name: "podPageSearch",
          query_params: [
            :query,
            :domain,
            :types,
            :scope,
            :ancestor_id,
            :created_by,
            :updated_after,
            :title_only,
            :sort,
            :limit,
            :exclude_subtree_of,
            :required_action,
            :embeddable
          ]
        )

        route(:get, "/pages/recent-searches", :list_recent_searches,
          name: "podRecentSearches",
          query_params: [:limit]
        )

        route(:post, "/pages/recent-searches", :record_recent_search,
          name: "podRecordRecentSearch"
        )

        route(:delete, "/pages/recent-searches/:id", :delete_recent_search,
          name: "podDeleteRecentSearch"
        )

        route(:delete, "/pages/recent-searches", :clear_recent_searches,
          name: "podClearRecentSearches"
        )

        route :post, "/pages", :create do
          name("podPageCreate")
        end

        route :get, "/pages/:id", :show do
          name("podPageRead")
        end

        route(:get, "/pages/:id/viewers", :viewers,
          name: "podPageViewers",
          query_params: [:cursor, :limit]
        )

        route :get, "/pages/:id/insights", :insights do
          name("podPageInsights")
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

        route :post, "/pages/:id/purge", :purge do
          name("podPagePurge")
        end

        route :post, "/pages/:id/embeds/delete", :delete_embeds do
          name("podEmbedsDelete")
        end

        route(:get, "/pages/:id/knowledge", :knowledge_panel, name: "podKnowledgePanel")

        route(:get, "/pages/:id/knowledge/export", :knowledge_export,
          name: "podKnowledgeExport",
          query_params: [:snapshot_id]
        )

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

        route :patch, "/pages/:id/sharing", :update_sharing do
          name("podPageSharingUpdate")
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

        route(:get, "/mentions/candidates", :mention_candidates,
          name: "podMentionCandidates",
          query_params: [:query, :category, :current_page_id, :limit]
        )

        route(:post, "/mentions/resolve", :resolve_mentions, name: "podMentionsResolve")
        route(:post, "/links/unfurl", :unfurl_link, name: "podLinkUnfurl")
      end
    end
  end
end
