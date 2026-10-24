defmodule Ankole.Pod do
  @moduledoc """
  The Pod domain: the page tree, page content, and Database schemas.

  The Ash resources own the pages, page content and changes, personal page
  state, and Database tables, fields, and views. `Ankole.Pod.Pages`,
  `Ankole.Pod.Documents`, `Ankole.Pod.Files`, `Ankole.Pod.Applets`, and
  `Ankole.Pod.Database` run their operations in top-level transactions.
  The Pod Database subsystem owns the `db_records` rows through the
  `Ankole.Pod.DbRecord` Ecto schema, because users define their fields at
  runtime.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(Ankole.Pod.Pages.Browser)
    resource(Ankole.Pod.Database.Browser)
    resource(Ankole.Pod.Files.Browser)
    resource(Ankole.Pod.Chat.Browser)
    resource(AnkoleWeb.JSONAPI.PodRealtime)
    resource(Ankole.Pod.Page)
    resource(Ankole.Pod.PageContent)
    resource(Ankole.Pod.PageChange)
    resource(Ankole.Pod.PageUserState)

    resource Ankole.Pod.DbTable do
      define(:get_db_table, action: :read, get_by: [:id], not_found_error?: false)
    end

    resource(Ankole.Pod.DbField)
    resource(Ankole.Pod.DbView)
  end

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/", Ankole.Pod.Chat.Browser do
        route(:get, "/agents", :agents, name: "podAgents")
        route(:get, "/conversations", :list, name: "podConversations", query_params: [:pageID])
        route(:post, "/conversations", :create, name: "createConversation")

        route(:get, "/conversations/:id", :show,
          name: "conversationDetail",
          query_params: [:beforeSeq, :loadedFirstSeq]
        )

        route(:delete, "/conversations/:id", :delete, name: "deleteConversation")

        route(:post, "/conversations/:id/messages", :post_message,
          name: "postConversationMessage"
        )

        route(:post, "/conversations/:id/queue", :update_queue, name: "updateConversationQueue")
        route(:get, "/agents/:uid/model-profiles", :model_profiles, name: "podModelProfiles")

        route(:get, "/conversations/:id/model-profile", :model_selection,
          name: "podModelSelection"
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
        route(:post, "/pages/:id/publish", :publish, name: "podPublish")
        route(:post, "/pages/:id/copy-file", :copy, name: "podFileCopy")
      end

      base_route "/", Ankole.Pod.Database.Browser do
        route(:get, "/databases/:page_id", :tables, name: "podDatabaseTables")
        route(:post, "/databases/:page_id/tables", :create_table, name: "podDatabaseTableCreate")
        route(:get, "/tables/:id", :show, name: "podDatabaseSchema")
        route(:post, "/tables/:id/query", :query, name: "podDatabaseQuery")
        route(:post, "/tables/:id/aggregate", :aggregate, name: "podDatabaseAggregate")
        route(:post, "/tables/:id/records", :write, name: "podDatabaseWrite")
        route(:post, "/tables/:id/fields", :create_field, name: "podDatabaseFieldCreate")
        route(:patch, "/fields/:id", :update_field, name: "podDatabaseFieldUpdate")

        route(:delete, "/fields/:id", :delete_field,
          name: "podDatabaseFieldDelete",
          query_params: [:version]
        )

        route(:post, "/tables/:id/views", :create_view, name: "podDatabaseViewCreate")
        route(:patch, "/views/:id", :update_view, name: "podDatabaseViewUpdate")

        route(:delete, "/views/:id", :delete_view,
          name: "podDatabaseViewDelete",
          query_params: [:version]
        )

        route(:post, "/tables/:id/copy", :copy, name: "podDatabaseCopy")
      end

      base_route "/", Ankole.Pod.Pages.Browser do
        route :get, "/pages", :list do
          name("podPageList")
          query_params([:scope, :query])
        end

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
