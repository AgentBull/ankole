defmodule Ankole.Connectors do
  @moduledoc "Tenant-owned external credentials and connections shared by platform integrations."
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/connectors", Ankole.Connectors.Browser do
        route(:get, "/", :catalog, name: "podConnectorsCatalog", wrap_in_result?: false)

        route(:get, "/auth-configs", :connections,
          name: "podConnectorAuthConfigsList",
          wrap_in_result?: false
        )

        route(:post, "/auth-configs", :create_connection,
          name: "podConnectorAuthConfigsCreate",
          wrap_in_result?: false
        )

        route(:patch, "/auth-configs/:id", :update_connection,
          name: "podConnectorAuthConfigsUpdate",
          wrap_in_result?: false
        )

        route(:post, "/auth-configs/:id/refresh-catalog", :refresh_catalog,
          name: "podConnectorAuthConfigsRefreshCatalog",
          wrap_in_result?: false
        )

        route(:get, "/accounts", :accounts,
          name: "podConnectorAccountsList",
          wrap_in_result?: false
        )

        route(:post, "/accounts/connect-personal", :connect_personal_credentials,
          name: "podConnectorAccountsConnectPersonal",
          wrap_in_result?: false
        )

        route(:post, "/accounts/connect-team", :connect_team_credentials,
          name: "podConnectorAccountsConnectTeam",
          wrap_in_result?: false
        )

        route(:delete, "/accounts/:id", :disconnect,
          name: "podConnectorAccountsDisconnect",
          wrap_in_result?: false
        )

        route(:post, "/oauth", :oauth_begin,
          name: "podConnectorOAuthBegin",
          wrap_in_result?: false
        )

        route(:post, "/oauth/claim", :oauth_claim,
          name: "podConnectorOAuthClaim",
          wrap_in_result?: false
        )

        route(:get, "/triggers", :triggers,
          name: "podConnectorTriggersList",
          wrap_in_result?: false
        )

        route(:post, "/triggers", :create_trigger,
          name: "podConnectorTriggersCreate",
          wrap_in_result?: false
        )

        route(:delete, "/triggers/:id", :delete_trigger,
          name: "podConnectorTriggersDelete",
          wrap_in_result?: false
        )

        route(:post, "/triggers/:id/retry", :retry_trigger,
          name: "podConnectorTriggersRetry",
          wrap_in_result?: false
        )
      end
    end
  end

  resources do
    resource(Ankole.Connectors.Browser)
    resource(Ankole.Connectors.AuthConfig)
    resource(Ankole.Connectors.ConnectedAccount)
    resource(Ankole.Connectors.OAuthSession)
    resource(Ankole.Connectors.AuthWait)
    resource(Ankole.Connectors.Trigger)
    resource(Ankole.Connectors.DbCatalogTable)
    resource(Ankole.Connectors.DbCatalogColumn)
  end

  defdelegate receive_cloud_delivery(envelope), to: Ankole.Connectors.Ingress

  defdelegate event_connection_needed?(auth_config_id), to: Ankole.Connectors.Triggers
  defdelegate teardown_tenant(), to: Ankole.Connectors.Triggers
  defdelegate active_auth_configs(plugin_id), to: Ankole.Connectors.Store

  defdelegate list_event_triggers(auth_config_id, trigger_type, scope_key),
    to: Ankole.Connectors.Triggers

  defdelegate list_auth_configs(actor), to: Ankole.Connectors.Store
  defdelegate list_public_auth_configs(), to: Ankole.Connectors.Store
  defdelegate catalog(), to: Ankole.Connectors.Registry
  defdelegate create_auth_config(actor, attrs), to: Ankole.Connectors.Store
  defdelegate update_auth_config(actor, id, attrs), to: Ankole.Connectors.Store
  defdelegate get_auth_config(selector, plugin_id \\ nil), to: Ankole.Connectors.Store
  defdelegate get_auth_config_for_configuration(id), to: Ankole.Connectors.Store
  defdelegate resolve_credentials(auth_config_id), to: Ankole.Connectors.Credentials

  @doc """
  Runs one guarded read-only statement on a database connection after
  connection-level AuthZ and returns the adapter's evidence envelope. Brain
  metric execution and the `query` tool share this path.
  """
  defdelegate run_read_query(actor, connection, sql, params \\ [], opts \\ []),
    to: Ankole.Connectors.Databases

  defdelegate search_database_catalog(config, query, limit),
    to: Ankole.Connectors.Databases,
    as: :search_catalog

  defdelegate describe_database_table(config, schema, table),
    to: Ankole.Connectors.Databases,
    as: :describe_table

  defdelegate get_account(auth_config_id, subject_kind, account_key),
    to: Ankole.Connectors.Accounts

  defdelegate get_account_by_id(id), to: Ankole.Connectors.Accounts, as: :get_by_id
  defdelegate cloud_account_referenced?(id), to: Ankole.Connectors.Accounts
  defdelegate list_accounts(actor), to: Ankole.Connectors.Accounts
  defdelegate disconnect_account(actor, id), to: Ankole.Connectors.Accounts

  defdelegate resolve_call(spec, actor, connection, account, args \\ %{}),
    to: Ankole.Connectors.Resolver

  defdelegate begin_oauth(actor, attrs), to: Ankole.Connectors.OAuth, as: :begin
  defdelegate claim_oauth(actor, code), to: Ankole.Connectors.OAuth, as: :claim
  defdelegate revoke_human_accounts_in_tx(uid, version), to: Ankole.Connectors.Accounts
end
