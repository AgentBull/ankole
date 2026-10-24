defmodule AnkoleWeb.BrowserAPI do
  @moduledoc "The setup and authentication boundary shared by the browser applications."
  use Ash.Domain, validate_config_inclusion?: false, extensions: [AshJsonApi.Domain]

  resources do
    resource(AnkoleWeb.BrowserSetup)
    resource(AnkoleWeb.BrowserAuth)
  end

  json_api do
    authorize?(false)
    show_raised_errors?(false)
    log_errors?(true)

    routes do
      base_route "/", AnkoleWeb.BrowserSetup do
        route(:get, "/setup/state", :state, name: "setupState")

        route(:post, "/setup/sessions", :create_session,
          name: "createSetupSession",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(:delete, "/setup/sessions/current", :delete_session,
          name: "deleteSetupSession",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(
          :post,
          "/setup/bootstrap-activation-code/log-entries",
          :create_activation_code_log_entry,
          name: "logSetupActivationCode"
        )

        route(:get, "/setup/plugins", :plugins, name: "setupPlugins")

        route(:put, "/setup/plugins/enabled", :update_plugins, name: "updateSetupPlugins")

        route(:get, "/setup/brain-packs", :brain_packs, name: "setupBrainPacks")

        route(:put, "/setup/brain-packs", :put_brain_packs,
          name: "updateSetupBrainPacks",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(
          :get,
          "/setup/identity-provider-adapters",
          :identity_provider_adapters,
          name: "setupIdentityProviderAdapters"
        )

        route(
          :put,
          "/setup/identity-providers/:provider_id",
          :put_identity_provider,
          name: "putSetupIdentityProvider"
        )

        route(
          :post,
          "/setup/identity-providers/:provider_id/oidc/authorizations",
          :oidc_authorization,
          name: "setupOIDCAuthorization",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(:post, "/setup/local-admin", :create_local_admin,
          name: "createSetupLocalAdmin",
          modify_conn: &__MODULE__.apply_cookies/4
        )
      end

      base_route "/", AnkoleWeb.BrowserAuth do
        route(:get, "/session", :session, name: "browserSession")

        route(:delete, "/session", :delete_session,
          name: "deleteAuthSession",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(:put, "/sessions/active", :activate_account, name: "activateBrowserAccount")

        route(:get, "/identity-providers", :identity_providers,
          name: "loginProviders",
          query_params: [:flow]
        )

        route(:post, "/sessions/identity-selection", :select_identity,
          name: "selectLoginIdentity"
        )

        route(:delete, "/authentications/current", :delete_authentication,
          name: "deleteBrowserAuthentication",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(:post, "/sessions/local-password", :local_password_login,
          name: "localPasswordLogin",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(
          :post,
          "/sessions/local-password/change",
          :local_password_change,
          name: "localPasswordChange",
          modify_conn: &__MODULE__.apply_cookies/4
        )

        route(:get, "/oidc-logout/:id", :logout_confirmation, name: "logoutConfirmation")
      end
    end
  end

  # The constrained action return types expose only their declared fields. This
  # request-local value carries cookie/session changes to AshJsonApi.modify_conn;
  # it is never a public argument, serialized field, or persisted value.
  def ok(conn, payload), do: {:ok, Map.put(payload, :__conn__, conn)}

  def apply_cookies(conn, subject, %Ash.Union{value: value}, request),
    do: apply_cookies(conn, subject, value, request)

  def apply_cookies(_conn, _subject, result, _request), do: Map.fetch!(result, :__conn__)
  def error(status, reason), do: {:error, AnkoleWeb.BrowserAPI.Error.new(status, reason)}
end
