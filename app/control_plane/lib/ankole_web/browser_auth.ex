defmodule AnkoleWeb.BrowserAuth do
  @moduledoc "Browser authentication actions; credentials stay in trusted request context and cookie effects."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: AnkoleWeb.BrowserAPI,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:public)
    allow(:session, check: :public)
    allow(:activate_account, check: :public)
    allow(:delete_session, check: :public)
    allow(:delete_authentication, check: :public)
    allow(:select_identity, check: :public)
    allow(:identity_providers, check: :public)
    allow(:request_email_otp, check: :public)
    allow(:resolve_pod_login, check: :public)
    allow(:verify_email_otp, check: :public)
    allow(:logout_confirmation, check: :public)
  end

  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey}
  alias AnkoleWeb.BrowserAPI

  resource do
    require_primary_key?(false)
  end

  alias Ankole.{AuthZ, BrowserSessions}
  alias Ankole.IdentityProviders.Login
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
  @pending [
    authenticationRef: [type: :string, allow_nil?: false],
    tenant: @tenant,
    principalUID: [type: PrincipalKey],
    invitationID: [type: UUIDv7],
    displayName: [type: :string, allow_nil?: false],
    providerID: [type: :string, allow_nil?: false],
    podURL: [type: :string, allow_nil?: false],
    requiresSSO: [type: :boolean, allow_nil?: false]
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
        fields: [
          principalUID: [type: PrincipalKey],
          displayName: [type: :string],
          providerID: [type: :string],
          authenticated: [type: :boolean, allow_nil?: false],
          tenant: Keyword.put(@tenant, :allow_nil?, true),
          consoleURL: [type: :string],
          canManagePod: [type: :boolean, allow_nil?: false],
          pendingAccounts: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @pending]]
          ],
          siteAuthentications: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  authenticationRef: [type: :string, allow_nil?: false],
                  providerID: [type: :string, allow_nil?: false],
                  identifier: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ],
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
      argument(:tenantID, UUIDv7, allow_nil?: false)

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
          purpose: [type: :string],
          requireSSOForMembers: [type: :boolean, allow_nil?: false],
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

    action :request_email_otp, :map do
      constraints(
        fields: [
          challengeID: [type: UUIDv7, allow_nil?: false],
          expiresAt: [type: :utc_datetime_usec, allow_nil?: false]
        ]
      )

      argument(:flow, UUIDv7, allow_nil?: false)
      argument(:email, :string, allow_nil?: false)
      transaction?(false)

      run(fn input, _context ->
        perform_request_email_otp(
          login_context(input.context.conn, input.arguments[:flow]),
          Ankole.JSON.plain(input.arguments)
        )
      end)
    end

    action :resolve_pod_login, :map do
      constraints(fields: [loginURL: [type: :string, allow_nil?: false]])
      argument(:slug, :string, allow_nil?: false)
      transaction?(false)

      run(fn input, _ ->
        case Ankole.Tenants.active_by_slug(input.arguments.slug) do
          {:ok, tenant} ->
            BrowserAPI.ok(input.context.conn, %{
              loginURL: AnkoleWeb.PodURL.origin(input.context.conn, tenant) <> "/sessions/new"
            })

          _ ->
            BrowserAPI.error(404, :pod_not_found)
        end
      end)
    end

    action :verify_email_otp, :map do
      constraints(fields: @login)
      argument(:flow, UUIDv7, allow_nil?: false)
      argument(:challengeID, UUIDv7, allow_nil?: false)
      argument(:code, :string, allow_nil?: false, sensitive?: true, constraints: [trim?: false])
      transaction?(false)

      run(fn input, _context ->
        perform_verify_email_otp(
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
    references = WebSession.authentication_references(conn)

    if references != [] and not WebSession.invalid_authentication_selection?(conn) do
      account =
        with %{"tenant_id" => tenant_id} = authentication <-
               WebSession.current_authentication(conn),
             {:ok, account} <- browser_account(conn, authentication, tenant_id),
             do: account,
             else: (_ -> nil)

      uid = account && account.principalUID

      BrowserAPI.ok(conn, %{
        authenticated: true,
        principalUID: uid,
        providerID: account && account.providerID,
        displayName: account && account.displayName,
        tenant: account && account.tenant,
        canManagePod:
          is_binary(uid) and
            Ankole.Repo.with_tenant(account.tenant.id, fn -> AuthZ.pod_admin?(uid) end),
        consoleURL:
          if(is_binary(uid) and AuthZ.site_admin?(uid),
            do: AnkoleWeb.PodURL.site_origin(conn) <> AnkoleWeb.SiteAdminConsole.path()
          ),
        accounts: browser_accounts(conn),
        pendingAccounts: pending_accounts(conn, references),
        siteAuthentications: site_authentications(references)
      })
    else
      BrowserAPI.error(401, "unauthenticated")
    end
  end

  defp site_authentications(references) do
    Enum.flat_map(references, fn reference ->
      case BrowserSessions.get_authentication(reference) do
        {:ok, %{purpose: :site} = authentication} ->
          [
            %{
              authenticationRef: BrowserSessions.encode_reference(reference),
              providerID: authentication.provider_id,
              identifier: authentication.subject_id
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp pending_accounts(conn, references) do
    Enum.flat_map(references, fn reference ->
      case BrowserSessions.get_authentication(reference) do
        {:ok, %{purpose: :site} = authentication} ->
          proof = Map.from_struct(authentication)

          members =
            Enum.map(Ankole.Principals.pending_site_memberships(proof), fn principal ->
              {:ok, tenant} = Ankole.Tenants.get(principal.tenant_id)

              allowed? =
                Ankole.Repo.with_tenant(tenant.id, fn ->
                  Ankole.Principals.PodLoginPolicy.authentication_allowed?(
                    principal,
                    authentication.provider_id,
                    proof
                  )
                end)

              %{
                authenticationRef: BrowserSessions.encode_reference(reference),
                principalUID: principal.uid,
                displayName: principal.display_name || authentication.subject_id,
                providerID: authentication.provider_id,
                requiresSSO: not allowed?,
                tenant: %{id: tenant.id, slug: tenant.slug, displayName: tenant.display_name},
                podURL: AnkoleWeb.PodURL.origin(conn, tenant) <> "/"
              }
            end)

          invitations =
            Ankole.Principals.pending_invitations(authentication.verified_email)
            |> Enum.reject(fn invitation ->
              Enum.any?(
                Ankole.Principals.list_site_credentials(
                  authentication.provider_id,
                  authentication.subject_id
                ),
                &(&1.tenant_id == invitation.tenant_id)
              )
            end)
            |> Enum.uniq_by(& &1.tenant_id)
            |> Enum.map(fn invitation ->
              {:ok, tenant} = Ankole.Tenants.get(invitation.tenant_id)

              allowed? =
                Ankole.Repo.with_tenant(tenant.id, fn ->
                  Ankole.Principals.PodLoginPolicy.authentication_allowed?(
                    %{status: :active, membership: invitation.membership},
                    authentication.provider_id,
                    proof
                  )
                end)

              %{
                authenticationRef: BrowserSessions.encode_reference(reference),
                invitationID: invitation.id,
                displayName: authentication.subject_id,
                providerID: authentication.provider_id,
                requiresSSO: not allowed?,
                tenant: %{id: tenant.id, slug: tenant.slug, displayName: tenant.display_name},
                podURL: AnkoleWeb.PodURL.origin(conn, tenant) <> "/"
              }
            end)

          invitations ++
            Enum.reject(members, fn member ->
              Enum.any?(invitations, &(&1.tenant.id == member.tenant.id))
            end)

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(&{&1.tenant.id, Map.get(&1, :principalUID) || &1.invitationID})
  end

  defp perform_activate_account(conn, %{"authenticationRef" => encoded, "tenantID" => tenant_id}) do
    with {:ok, reference} <- BrowserSessions.decode_reference(encoded),
         true <- WebSession.authentication_proven?(conn, reference),
         {:ok, tenant} <- Ankole.Tenants.get(tenant_id),
         {:ok, conn, url} <- activate_or_login(conn, reference, tenant) do
      BrowserAPI.ok(conn, %{podURL: url})
    else
      {:error, reason} -> login_error(conn, reason)
      _ -> error(conn, 401, "invalid_authentication")
    end
  end

  defp activate_or_login(conn, reference, tenant) do
    case activate_membership(reference, tenant.id) do
      :ok ->
        with {:ok, _} <-
               BrowserSessions.activate(WebSession.browser_reference(conn), reference, tenant.id),
             do: {:ok, conn, AnkoleWeb.PodURL.origin(conn, tenant) <> "/"}

      {:error, reason} when reason in [:login_policy_rejected, :reauthentication_required] ->
        begin_membership_login(conn, reference, tenant)

      error ->
        error
    end
  end

  defp begin_membership_login(conn, reference, tenant) do
    with {:ok, %{purpose: :site} = authentication} <-
           BrowserSessions.get_authentication(reference) do
      Ankole.Repo.with_tenant(tenant.id, fn ->
        invitation =
          authentication.verified_email
          |> Ankole.Principals.pending_invitations()
          |> Enum.find(&(&1.tenant_id == tenant.id))

        request =
          if invitation,
            do: %{"return_to" => "/", "invitation_id" => invitation.id},
            else: %{"return_to" => "/"}

        with {:ok, _} <- Ankole.Principals.invitation_for_login(invitation && invitation.id),
             {:ok, conn, transaction} <-
               WebSession.begin_login(
                 conn,
                 :pod,
                 request,
                 mode: :add
               ) do
          {:ok, conn,
           AnkoleWeb.PodURL.origin(conn, tenant) <> "/sessions/new?flow=" <> transaction.id}
        end
      end)
    else
      {:ok, _} -> {:error, :invalid_authentication}
      error -> error
    end
  end

  defp activate_membership(reference, tenant_id) do
    if BrowserSessions.identity(reference, tenant_id) do
      :ok
    else
      case BrowserSessions.claim_membership(reference, tenant_id) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp browser_accounts(conn) do
    conn
    |> WebSession.authentication_references()
    |> Enum.flat_map(fn reference ->
      Enum.flat_map(BrowserSessions.identities(reference), fn identity ->
        case browser_account(conn, identity, identity["tenant_id"]) do
          {:ok, account} ->
            [Map.put(account, :authenticationRef, BrowserSessions.encode_reference(reference))]

          _ ->
            []
        end
      end)
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
        purpose: transaction && Atom.to_string(transaction.purpose),
        requireSSOForMembers:
          transaction != nil and transaction.tenant_id != nil and
            elem(Ankole.Principals.PodLoginPolicy.get(), 1)["require_sso_for_members"],
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
    references =
      if LoginPolicy.reauthentication_required?(transaction.request),
        do: [],
        else: WebSession.authentication_references(conn)

    Enum.flat_map(references, fn reference ->
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
      %{principalUID: uid, displayName: principal.display_name || uid, providerID: provider}
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

  defp perform_request_email_otp(conn, params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, transaction} <- login_transaction(conn),
         {:ok, sent} <-
           Ankole.Authn.Info.run(Ankole.Principals.SiteCredential, :email_otp, :request, %{
             browser: WebSession.browser_reference(conn),
             flow: transaction.id,
             email: params["email"],
             source: to_string(:inet.ntoa(conn.remote_ip))
           }) do
      BrowserAPI.ok(conn, %{challengeID: sent.challenge_id, expiresAt: sent.expires_at})
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp perform_verify_email_otp(conn, params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, transaction} <- login_transaction(conn),
         {:ok, completed} <-
           Ankole.Authn.Info.run(Ankole.Principals.SiteCredential, :email_otp, :verify, %{
             browser: WebSession.browser_reference(conn),
             flow: transaction.id,
             challenge_id: params["challengeID"],
             code: params["code"],
             source: to_string(:inet.ntoa(conn.remote_ip))
           }),
         {:ok, transaction} <- select_completed_site_login(conn, completed) do
      conn = WebSession.put_authentication(conn, completed.browser, completed.authentication)
      BrowserAPI.ok(conn, %{status: "ok", returnTo: browser_return_to(conn, transaction)})
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp select_completed_site_login(
         conn,
         %{transaction: %{purpose: :oauth} = transaction} = completed
       ),
       do:
         BrowserSessions.select_authorization(
           WebSession.browser_reference(conn),
           transaction.id,
           BrowserSessions.reference(completed.authentication)
         )

  defp select_completed_site_login(_conn, completed), do: {:ok, completed.transaction}

  defp login_transaction(conn), do: conn.assigns.login_transaction

  defp browser_return_to(conn, %{purpose: :pod, tenant_id: tenant_id} = transaction) do
    {:ok, tenant} = Ankole.Tenants.get(tenant_id)
    AnkoleWeb.PodURL.origin(conn, tenant) <> return_to(transaction)
  end

  defp browser_return_to(_conn, transaction), do: return_to(transaction)
  defp return_to(transaction), do: AnkoleWeb.AuthController.return_to(transaction)
  defp login_error(_conn, reason), do: AnkoleWeb.BrowserAPI.Error.login(reason)
  defp error(_conn, status, reason), do: BrowserAPI.error(status, reason)
end
