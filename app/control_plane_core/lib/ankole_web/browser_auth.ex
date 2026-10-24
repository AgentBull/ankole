defmodule AnkoleWeb.BrowserAuth do
  @moduledoc "Browser authentication actions; credentials stay in trusted request context and cookie effects."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: AnkoleWeb.BrowserAPI,
    extensions: [AshJsonApi.Resource]

  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey}
  alias AnkoleWeb.BrowserAPI

  resource do
    require_primary_key?(false)
  end

  alias Ankole.{AuthZ, BrowserSessions}
  alias Ankole.IdentityProviders.{LocalPassword, Login}
  alias Ankole.OIDC.{LoginPolicy, RPLogout}
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  @tenant [
    type: :map,
    allow_nil?: false,
    constraints: [
      fields: [
        id: [type: UUIDv7, allow_nil?: false],
        slug: [type: :string, allow_nil?: false],
        displayName: [type: :string, allow_nil?: false]
      ]
    ]
  ]
  @identity [
    principalUID: [type: PrincipalKey, allow_nil?: false],
    displayName: [type: :string, allow_nil?: false],
    providerID: [type: :string, allow_nil?: false]
  ]
  @account @identity ++
             [
               authenticationRef: [type: :string, allow_nil?: false],
               tenant: @tenant,
               podURL: [type: :string, allow_nil?: false]
             ]
  @login [
    status: [type: :atom, allow_nil?: false, constraints: [one_of: [:ok]]],
    returnTo: [type: :string, allow_nil?: false]
  ]
  json_api do
    type("browser_authentication")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :session, :map do
      constraints(
        fields:
          @identity ++
            [
              authenticated: [type: :boolean, allow_nil?: false],
              tenant: @tenant,
              consoleURL: [type: :string],
              accounts: [
                type: {:array, :map},
                allow_nil?: false,
                constraints: [items: [fields: @account]]
              ]
            ]
      )

      run(fn input, _context ->
        perform_session(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :activate_account, :map do
      constraints(fields: [podURL: [type: :string, allow_nil?: false]])
      argument(:authenticationRef, :string, allow_nil?: false)

      run(fn input, _context ->
        perform_activate_account(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :delete_session, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])

      run(fn input, _context ->
        perform_delete_session(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :delete_authentication, :map do
      constraints(fields: [ok: [type: :boolean, allow_nil?: false]])

      run(fn input, _context ->
        perform_delete_authentication(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :select_identity, :map do
      constraints(fields: @login)
      argument(:flow, UUIDv7, allow_nil?: false)
      argument(:authenticationRef, :string, allow_nil?: false)

      run(fn input, _context ->
        perform_select_identity(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :identity_providers, :map do
      constraints(
        fields: [
          identity: [type: :map, constraints: [fields: @identity]],
          identities: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: @identity ++ [authenticationRef: [type: :string, allow_nil?: false]]
              ]
            ]
          ],
          selectAccount: [type: :boolean, allow_nil?: false],
          providers: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  providerID: [type: :string, allow_nil?: false],
                  adapterID: [type: :string, allow_nil?: false],
                  pluginID: [type: :string],
                  kind: [type: :string, allow_nil?: false],
                  loginPath: [type: :string, allow_nil?: false],
                  displayName: [type: Ankole.Ash.Types.StringMap, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      argument(:flow, UUIDv7)

      run(fn input, _context ->
        perform_identity_providers(
          login_context(input.context.conn, input.arguments[:flow]),
          Ankole.JSON.plain(input.arguments)
        )
      end)
    end

    action :local_password_login, AnkoleWeb.BrowserAuth.LoginResult do
      argument(:flow, UUIDv7, allow_nil?: false)
      argument(:email, :string, allow_nil?: false)

      argument(:password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [trim?: false]
      )

      run(fn input, _context ->
        perform_local_password_login(
          login_context(input.context.conn, input.arguments[:flow]),
          Ankole.JSON.plain(input.arguments)
        )
        |> AnkoleWeb.BrowserAuth.LoginResult.wrap()
      end)
    end

    action :local_password_change, :map do
      constraints(fields: @login)
      argument(:flow, UUIDv7, allow_nil?: false)

      argument(:newPassword, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [trim?: false]
      )

      run(fn input, _context ->
        perform_local_password_change(
          login_context(input.context.conn, input.arguments[:flow]),
          Ankole.JSON.plain(input.arguments)
        )
      end)
    end

    action :logout_confirmation, :map do
      constraints(
        fields: [
          identity: [type: :map, constraints: [fields: @identity]],
          clientName: [type: :string]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, _context ->
        perform_logout_confirmation(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end
  end

  def login_context(conn, flow) do
    transaction =
      if flow, do: WebSession.login_transaction(conn, flow), else: {:error, :login_expired}

    case transaction do
      {:ok, %{tenant_id: tenant_id}} when is_binary(tenant_id) ->
        Ankole.Repo.put_tenant_id(tenant_id)

      _ ->
        WebSession.put_privileged_tenant()
    end

    Plug.Conn.assign(conn, :login_transaction, transaction)
  end

  defp perform_logout_confirmation(conn, %{"id" => id}) do
    with {:ok, request} <-
           Ankole.Repo.across_tenants(fn ->
             RPLogout.confirmation(WebSession.browser_reference(conn), id)
           end),
         :ok <- Ankole.Repo.put_tenant_id(request.tenant_id) do
      auth = WebSession.oauth_session(conn) || WebSession.admin_session(conn)

      identity =
        case auth do
          %{"principal_uid" => uid} ->
            identity =
              with {:ok, tenant_id} <- Ankole.Principals.resolve_tenant(uid),
                   do:
                     Ankole.Repo.with_tenant(tenant_id, fn ->
                       Ankole.Principals.get_principal(uid)
                     end)

            case identity do
              {:ok, principal} ->
                %{
                  principalUID: uid,
                  displayName: principal.display_name || uid,
                  providerID: auth["provider_id"]
                }

              {:error, :not_found} ->
                nil
            end

          nil ->
            nil
        end

      client_name =
        if request.client_id do
          case Ankole.OIDC.get_active_client(request.client_id) do
            {:ok, client} -> client.name
            _ -> nil
          end
        end

      BrowserAPI.ok(conn, %{identity: identity, clientName: client_name})
    else
      {:error, _} -> BrowserAPI.error(401, "logout_request_expired")
    end
  end

  defp perform_session(conn, _params) do
    with %{"principal_uid" => uid, "tenant_id" => tenant_id} = authentication <-
           WebSession.current_authentication(conn),
         {:ok, account} <- browser_account(conn, authentication, tenant_id) do
      BrowserAPI.ok(conn, %{
        authenticated: true,
        principalUID: uid,
        providerID: authentication["provider_id"],
        displayName: account.displayName,
        tenant: account.tenant,
        consoleURL:
          if(AuthZ.site_admin?(uid),
            do: AnkoleWeb.PodURL.site_origin(conn) <> AnkoleWeb.SiteAdminConsole.path()
          ),
        accounts: browser_accounts(conn)
      })
    else
      _ -> BrowserAPI.error(401, "unauthenticated")
    end
  end

  defp perform_activate_account(conn, %{"authenticationRef" => encoded}) do
    with {:ok, reference} <- BrowserSessions.decode_reference(encoded),
         true <- WebSession.authentication_proven?(conn, reference),
         {:ok, %{tenant_id: tenant_id}} when is_binary(tenant_id) <-
           BrowserSessions.get_authentication(reference),
         {:ok, tenant} <- Ankole.Tenants.get(tenant_id),
         {:ok, _} <- BrowserSessions.activate(WebSession.browser_reference(conn), reference) do
      BrowserAPI.ok(conn, %{podURL: AnkoleWeb.PodURL.origin(conn, tenant) <> "/"})
    else
      _ -> error(conn, 401, "invalid_authentication")
    end
  end

  # Every proved Pod identity in this browser group, one per person and tenant.
  defp browser_accounts(conn) do
    current = WebSession.authentication_reference(conn)

    conn
    |> WebSession.authentication_references()
    |> Enum.sort_by(&(&1 != current))
    |> Enum.flat_map(fn reference ->
      with {:ok, %{tenant_id: tenant_id}} when is_binary(tenant_id) <-
             BrowserSessions.get_authentication(reference),
           %{} = identity <- BrowserSessions.identity(reference, tenant_id),
           {:ok, account} <- browser_account(conn, identity, tenant_id) do
        [Map.put(account, :authenticationRef, BrowserSessions.encode_reference(reference))]
      else
        _ -> []
      end
    end)
    |> Enum.uniq_by(&{&1.tenant.id, &1.principalUID})
  end

  defp browser_account(conn, %{"principal_uid" => uid} = identity, tenant_id) do
    with {:ok, tenant} <- Ankole.Tenants.get(tenant_id),
         {:ok, principal} <-
           Ankole.Repo.with_tenant(tenant_id, fn -> Ankole.Principals.get_principal(uid) end) do
      {:ok,
       %{
         principalUID: uid,
         displayName: principal.display_name || uid,
         providerID: identity["provider_id"],
         tenant: %{
           id: tenant.id,
           slug: tenant.slug,
           displayName: tenant.display_name || tenant.slug
         },
         podURL: AnkoleWeb.PodURL.origin(conn, tenant) <> "/"
       }}
    end
  end

  defp perform_delete_session(conn, _params),
    do: conn |> WebSession.clear_admin_session() |> BrowserAPI.ok(%{ok: true})

  defp perform_delete_authentication(conn, _params) do
    case WebSession.revoke_authentication(conn) do
      {:ok, conn} -> BrowserAPI.ok(conn, %{ok: true})
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp perform_select_identity(conn, %{"flow" => flow, "authenticationRef" => encoded}) do
    with {:ok, _transaction} <- WebSession.login_transaction(conn, flow),
         {:ok, reference} <- BrowserSessions.decode_reference(encoded),
         true <- WebSession.authentication_proven?(conn, reference),
         {:ok, transaction} <-
           BrowserSessions.select_authorization(
             WebSession.browser_reference(conn),
             flow,
             reference
           ) do
      BrowserAPI.ok(conn, %{status: "ok", returnTo: return_to(transaction)})
    else
      _ -> login_error(conn, :login_expired)
    end
  end

  defp perform_identity_providers(conn, params) do
    with {:ok, providers} <- providers_for_flow(conn, params["flow"]) do
      transaction =
        case login_transaction(conn) do
          {:ok, transaction} -> transaction
          _ -> nil
        end

      BrowserAPI.ok(conn, %{
        identity: current_identity(conn),
        identities: identity_choices(conn, transaction),
        selectAccount:
          transaction != nil and
            (transaction.purpose == :pod or LoginPolicy.selection_required?(transaction.request)),
        providers:
          Enum.map(providers, fn provider ->
            %{
              providerID: provider["provider_id"],
              adapterID: provider["adapter_id"],
              pluginID: provider["plugin_id"],
              kind: provider["kind"],
              loginPath: provider["login_path"],
              displayName: provider["display_name"]
            }
          end)
      })
    else
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp identity_choices(conn, %{purpose: purpose} = transaction) when purpose in [:oauth, :pod] do
    Enum.flat_map(WebSession.authentication_references(conn), fn reference ->
      with %{} = authentication <- BrowserSessions.identity(reference, transaction.tenant_id),
           :ok <- selection_source(transaction, authentication),
           {:ok, principal} <- Ankole.Principals.get_principal(authentication["principal_uid"]) do
        [
          %{
            authenticationRef: BrowserSessions.encode_reference(reference),
            principalUID: principal.uid,
            displayName: principal.display_name || principal.uid,
            providerID: authentication["provider_id"]
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp identity_choices(_, _), do: []

  defp selection_source(%{purpose: :pod}, _authentication), do: :ok

  defp selection_source(transaction, authentication),
    do:
      LoginPolicy.authorize_source(
        transaction.request["client_id"],
        authentication["provider_id"]
      )

  defp current_identity(conn) do
    with %{"principal_uid" => uid, "provider_id" => provider} <-
           WebSession.current_authentication(conn),
         {:ok, tenant_id} <- Ankole.Principals.resolve_tenant(uid),
         {:ok, principal} <-
           Ankole.Repo.with_tenant(tenant_id, fn -> Ankole.Principals.get_principal(uid) end) do
      %{displayName: principal.display_name || uid, providerID: provider}
    else
      _ -> nil
    end
  end

  defp providers_for_flow(_conn, flow) when flow in [nil, ""], do: Login.list_login_providers()

  defp providers_for_flow(conn, _flow) do
    with {:ok, transaction} <- login_transaction(conn) do
      case transaction.purpose do
        purpose when purpose in [:console, :pod] ->
          LoginPolicy.login_providers()

        :oauth ->
          with {:ok, client} <- Ankole.OIDC.get_active_client(transaction.request["client_id"]),
               do: LoginPolicy.providers(client, transaction.request)

        :site ->
          {:ok, Ankole.IdentityProviders.SiteSources.providers()}
      end
    end
  end

  defp perform_local_password_login(conn, params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, %{status: :pending} = transaction} <-
           login_transaction(conn),
         {:ok, provider} <- LocalPassword.fetch_enabled_provider(),
         :ok <- LoginPolicy.authorize_login(transaction, provider["provider_id"]),
         {:ok, _} <-
           BrowserSessions.bind_provider(
             WebSession.browser_reference(conn),
             transaction.id,
             provider["provider_id"]
           ),
         {:ok, email} <- required_param(params, "email"),
         {:ok, password} <- required_param(params, "password"),
         {:ok, login} <- LocalPassword.authenticate(email, password) do
      complete_local_login(conn, transaction, login)
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:ok, _} -> error(conn, 401, "login_expired")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp complete_local_login(conn, transaction, login) do
    auth = %{
      "principal_uid" => login.principal_uid,
      "provider_id" => login.provider_id,
      "external_id" => login.email,
      "access_version" => login.access_version,
      "auth_time" => login.auth_time
    }

    cond do
      transaction.purpose == :console and
          not AuthZ.site_admin?(login.principal_uid) ->
        error(conn, 403, "not_an_admin")

      login.must_change_password ->
        ticket = Map.put(auth, "credential_version", login.credential_version)

        case BrowserSessions.put_password_ticket(
               WebSession.browser_reference(conn),
               transaction.id,
               ticket
             ) do
          {:ok, _} -> BrowserAPI.ok(conn, %{status: "password_change_required"})
          {:error, reason} -> login_error(conn, reason)
        end

      true ->
        finish_json_login(conn, transaction.id, auth)
    end
  end

  defp perform_local_password_change(conn, params) do
    with {:ok, %{status: :pending, password_ticket: %{} = ticket} = transaction} <-
           login_transaction(conn),
         {:ok, password} <- required_param(params, "newPassword"),
         {:ok, uid, password_hash} <-
           LocalPassword.forced_password_hash(ticket["principal_uid"], password) do
      # The callback runs in the login transaction of BrowserSessions.
      finish_json_login(conn, transaction.id, ticket, fn ->
        case Ankole.Principals.complete_forced_password_change_in_tx(
               uid,
               password_hash,
               ticket["credential_version"]
             ) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end
      end)
    else
      {:ok, _} ->
        error(conn, 401, "change_ticket_expired")

      {:error, reason} when reason in [:login_expired, :browser_session_expired] ->
        error(conn, 401, "change_ticket_expired")

      {:error, reason} ->
        login_error(conn, reason)
    end
  end

  defp finish_json_login(conn, id, auth, before_commit \\ fn -> :ok end) do
    result =
      with {:ok, transaction} <- login_transaction(conn),
           :ok <- LoginPolicy.authorize_login(transaction, auth["provider_id"]),
           :ok <- LoginPolicy.completed_authentication_allowed?(auth, transaction.request),
           do: WebSession.complete_login(conn, id, auth, before_commit)

    case result do
      {:ok, conn, transaction} ->
        BrowserAPI.ok(conn, %{status: "ok", returnTo: return_to(transaction)})

      {:error, reason} ->
        login_error(conn, reason)
    end
  end

  defp required_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp login_transaction(conn), do: conn.assigns.login_transaction
  defp return_to(transaction), do: AnkoleWeb.AuthController.return_to(transaction)
  defp login_error(_conn, reason), do: AnkoleWeb.BrowserAPI.Error.login(reason)
  defp error(_conn, status, reason), do: BrowserAPI.error(status, reason)
end
