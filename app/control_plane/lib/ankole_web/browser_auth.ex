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

  alias Ankole.Ash.Types.{PrincipalKey, UUIDv7}
  alias AnkoleWeb.BrowserAuth.Targets
  alias AnkoleWeb.{BrowserAPI, PodURL}

  resource do
    require_primary_key?(false)
  end

  alias Ankole.{AuthZ, BrowserSessions}
  alias Ankole.OIDC.{AuthorizationRequests, LoginPolicy, RPLogout}
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
      argument(:authenticationRef, :string, allow_nil?: false)
      argument(:oauthRequest, UUIDv7)
      argument(:tenantID, UUIDv7)
      argument(:returnTo, :string)
      argument(:prompt, :string)
      argument(:reauth, :string)

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

      argument(:oauth_request, UUIDv7)
      argument(:purpose, :string)
      argument(:tenant_id, UUIDv7)
      argument(:prompt, :string)
      argument(:switch, :string)
      argument(:reauth, :string)
      argument(:invitation, :string)
      argument(:invitation_token, :string)

      run(fn input, _context ->
        perform_identity_providers(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :request_email_otp, :map do
      constraints(
        fields: [
          challengeID: [type: UUIDv7, allow_nil?: false],
          expiresAt: [type: :utc_datetime_usec, allow_nil?: false]
        ]
      )

      argument(:email, :string, allow_nil?: false)
      argument(:oauthRequest, UUIDv7)
      argument(:purpose, :string)
      argument(:tenantID, UUIDv7)
      argument(:returnTo, :string)
      argument(:prompt, :string)
      argument(:reauth, :string)
      argument(:invitation, :string)
      argument(:invitationToken, :string)
      transaction?(false)

      run(fn input, _context ->
        perform_request_email_otp(input.context.conn, Ankole.JSON.plain(input.arguments))
      end)
    end

    action :resolve_pod_login, :map do
      constraints(
        fields: [
          tenantID: [type: UUIDv7, allow_nil?: false],
          displayName: [type: :string, allow_nil?: false],
          providers: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  providerID: [type: :string, allow_nil?: false],
                  adapterID: [type: :string, allow_nil?: false],
                  pluginID: [type: :string],
                  displayName: [type: Ankole.Ash.Types.StringMap, allow_nil?: false],
                  authorizationURL: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      argument(:slug, :string, allow_nil?: false)
      transaction?(false)

      run(fn input, _ ->
        perform_resolve_pod_login(input.context.conn, input.arguments.slug)
      end)
    end

    action :verify_email_otp, :map do
      constraints(fields: @login)
      argument(:challengeID, UUIDv7, allow_nil?: false)
      argument(:code, :string, allow_nil?: false, sensitive?: true, constraints: [trim?: false])
      transaction?(false)

      run(fn input, _context ->
        perform_verify_email_otp(input.context.conn, Ankole.JSON.plain(input.arguments))
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

  defp perform_resolve_pod_login(conn, slug) do
    case Ankole.Tenants.active_by_slug(slug) do
      {:ok, tenant} ->
        {:ok, providers} =
          Ankole.Repo.with_tenant(tenant.id, fn ->
            Ankole.IdentityProviders.Login.list_login_providers()
          end)

        BrowserAPI.ok(conn, %{
          tenantID: tenant.id,
          displayName: tenant.display_name || tenant.slug,
          providers:
            Enum.map(providers, fn provider ->
              %{
                providerID: provider["provider_id"],
                adapterID: provider["adapter_id"],
                pluginID: provider["plugin_id"],
                displayName: provider["display_name"],
                authorizationURL:
                  PodURL.oidc_authorization_url(conn, tenant, provider["provider_id"])
              }
            end)
        })

      _ ->
        BrowserAPI.error(404, :pod_not_found)
    end
  end

  defp activate_or_login(conn, reference, tenant) do
    case activate_membership(reference, tenant.id) do
      :ok ->
        with {:ok, _} <-
               BrowserSessions.activate(WebSession.browser_reference(conn), reference, tenant.id),
             do: {:ok, conn, AnkoleWeb.PodURL.origin(conn, tenant) <> "/"}

      {:error, reason} when reason in [:login_policy_rejected, :reauthentication_required] ->
        begin_membership_login(conn, reference, tenant, reason)

      error ->
        error
    end
  end

  defp begin_membership_login(conn, reference, tenant, reason) do
    with {:ok, %{purpose: :site} = authentication} <-
           BrowserSessions.get_authentication(reference) do
      Ankole.Repo.with_tenant(tenant.id, fn ->
        invitation =
          authentication.verified_email
          |> Ankole.Principals.pending_invitations()
          |> Enum.find(&(&1.tenant_id == tenant.id))

        with {:ok, _} <- Ankole.Principals.invitation_for_login(invitation && invitation.id),
             {:ok, ticket} <- seal_optional_invitation(conn, invitation, tenant.id) do
          membership_login_destination(conn, tenant, reason, ticket)
        end
      end)
    else
      {:ok, _} -> {:error, :invalid_authentication}
      error -> error
    end
  end

  defp seal_optional_invitation(_conn, nil, _tenant_id), do: {:ok, nil}

  defp seal_optional_invitation(conn, invitation, tenant_id),
    do: WebSession.seal_membership_invitation(conn, invitation.id, tenant_id)

  defp membership_login_destination(conn, tenant, reason, ticket) do
    params = %{"switch" => "1", "prompt" => "login"}
    params = if ticket, do: Map.put(params, "invitation", ticket), else: params

    with {:ok, url} <- PodURL.membership_login_url(conn, tenant, reason, params),
         do: {:ok, conn, url}
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

  defp perform_select_identity(conn, %{"authenticationRef" => encoded} = params) do
    with {:ok, reference} <- BrowserSessions.decode_reference(encoded),
         true <- WebSession.authentication_proven?(conn, reference),
         {:ok, return_to} <- select_target_identity(conn, reference, params) do
      BrowserAPI.ok(conn, %{status: "ok", returnTo: return_to})
    else
      {:error, reason} -> login_error(conn, reason)
      _ -> login_error(conn, :login_expired)
    end
  end

  defp select_target_identity(conn, reference, params) do
    case params["oauthRequest"] do
      id when is_binary(id) ->
        with {:ok, request} <-
               AuthorizationRequests.select_identity(
                 WebSession.browser_reference(conn),
                 id,
                 reference
               ),
             :ok <- Targets.verify_pod_host(conn, request.tenant_id) do
          {:ok, PodURL.oauth_return_to(conn, request)}
        end

      nil ->
        with {:ok, tenant_id, return_to, request_params} <-
               select_identity_target(conn, params),
             false <- LoginPolicy.reauthentication_required?(request_params),
             %{} = auth <- BrowserSessions.identity(reference, tenant_id),
             true <- LoginPolicy.can_reuse?(auth, request_params),
             {:ok, _} <-
               BrowserSessions.activate(
                 WebSession.browser_reference(conn),
                 reference,
                 tenant_id
               ) do
          {:ok, return_to}
        else
          true -> {:error, :reauthentication_required}
          false -> {:error, :reauthentication_required}
          nil -> {:error, :invalid_authentication}
          error -> error
        end
    end
  end

  defp select_identity_target(conn, params) do
    case Targets.resolve(conn, params) do
      {:ok, %{purpose: :site, target_tenant: %Ankole.Tenants.Tenant{} = tenant} = target} ->
        {:ok, tenant.id, PodURL.origin(conn, tenant) <> target.return_to, target.request_params}

      {:ok, %{purpose: :pod} = target} ->
        {:ok, target.tenant_id, target.return_to, target.request_params}

      {:ok, _} ->
        {:error, :login_expired}

      error ->
        error
    end
  end

  defp perform_identity_providers(conn, params) do
    with {:ok, target} <- Targets.resolve(conn, params),
         {:ok, providers} <- providers_for_target(conn, target) do
      policy_tenant_id = target.tenant_id || Map.get(target, :target_tenant_id)

      require_sso? =
        if is_binary(policy_tenant_id) do
          Ankole.Repo.with_tenant(policy_tenant_id, fn ->
            elem(Ankole.Principals.PodLoginPolicy.get(), 1)["require_sso_for_members"]
          end)
        else
          false
        end

      BrowserAPI.ok(conn, %{
        identity: current_identity(conn),
        identities: identity_choices(conn, target),
        purpose: Atom.to_string(target.purpose),
        requireSSOForMembers: require_sso?,
        selectAccount:
          target.purpose == :pod or
            (target.purpose == :site and is_binary(Map.get(target, :target_tenant_id))) or
            (target.purpose == :oauth and LoginPolicy.selection_required?(target.request_params)),
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

  defp identity_choices(conn, %{purpose: :oauth, oauth_request: request} = target) do
    if LoginPolicy.reauthentication_required?(request.request) or
         not is_nil(request.expected_authentication_id) do
      []
    else
      list_tenant_identities(conn, target.tenant_id, fn authentication ->
        LoginPolicy.authorize_source(request.request["client_id"], authentication["provider_id"])
      end)
    end
  end

  defp identity_choices(conn, %{purpose: :pod} = target) do
    if LoginPolicy.reauthentication_required?(target.request_params) or
         not is_nil(target.invitation_id) do
      []
    else
      list_tenant_identities(conn, target.tenant_id, fn _ -> :ok end)
    end
  end

  defp identity_choices(
         conn,
         %{purpose: :site, target_tenant_id: tenant_id} = target
       )
       when is_binary(tenant_id) do
    if LoginPolicy.reauthentication_required?(target.request_params) or
         not is_nil(target.invitation_id) do
      []
    else
      Ankole.Repo.with_tenant(tenant_id, fn ->
        list_tenant_identities(conn, tenant_id, fn _ -> :ok end)
      end)
    end
  end

  defp identity_choices(_, _), do: []

  defp list_tenant_identities(conn, tenant_id, allow_source) do
    Enum.flat_map(WebSession.authentication_references(conn), fn reference ->
      with %{} = authentication <- BrowserSessions.identity(reference, tenant_id),
           :ok <- allow_source.(authentication),
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

  defp providers_for_target(_conn, %{purpose: :console}),
    do: LoginPolicy.login_providers()

  defp providers_for_target(conn, %{purpose: :pod}) do
    with {:ok, providers} <- LoginPolicy.login_providers() do
      if conn.assigns[:pod_email_otp_disabled] == true,
        do: {:ok, Enum.reject(providers, &(&1["provider_id"] == "email_otp"))},
        else: {:ok, providers}
    end
  end

  defp providers_for_target(conn, %{purpose: :oauth, oauth_request: request}) do
    with {:ok, client} <- Ankole.OIDC.get_active_client(request.request["client_id"]),
         {:ok, providers} <- LoginPolicy.providers(client, request.request) do
      {:ok, tenant} = Ankole.Tenants.get(request.tenant_id)

      {:ok,
       Enum.map(providers, &provider_login_path(conn, tenant, &1))
       |> Enum.reject(
         &(&1["provider_id"] == "email_otp" and conn.assigns[:pod_email_otp_disabled] == true)
       )}
    end
  end

  defp providers_for_target(
         conn,
         %{purpose: :site, target_tenant: %Ankole.Tenants.Tenant{} = tenant}
       ) do
    {:ok, oidc} =
      Ankole.Repo.with_tenant(tenant.id, fn ->
        Ankole.IdentityProviders.Login.list_login_providers()
      end)

    oidc_providers = Enum.map(oidc, &provider_login_path(conn, tenant, &1))

    {:ok, oidc_providers ++ Ankole.IdentityProviders.SiteSources.providers()}
  end

  defp providers_for_target(_conn, %{purpose: :site}),
    do: {:ok, Ankole.IdentityProviders.SiteSources.providers()}

  defp provider_login_path(conn, tenant, %{"kind" => "oidc"} = provider) do
    Map.put(
      provider,
      "login_path",
      PodURL.oidc_authorization_url(conn, tenant, provider["provider_id"])
    )
  end

  defp provider_login_path(_conn, _tenant, provider), do: provider

  defp perform_request_email_otp(conn, params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, target} <- Targets.resolve(conn, params),
         :ok <- ensure_otp_target_allowed(conn, target),
         conn = WebSession.ensure_browser(conn),
         {:ok, sent} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.SiteCredential,
             :email_otp,
             :request,
             %{
               browser: WebSession.browser_reference(conn),
               email: params["email"],
               source: to_string(:inet.ntoa(conn.remote_ip))
             },
             login_purpose: target.purpose,
             tenant_id: target.tenant_id,
             target_tenant_id: Map.get(target, :target_tenant_id),
             locale:
               Ankole.I18n.negotiate_locale(Plug.Conn.get_req_header(conn, "accept-language")),
             mode: target.mode,
             return_to: target.return_to,
             started_revision: target.started_revision,
             oauth_request_id: target.oauth_request_id,
             invitation_id: target.invitation_id,
             expected_authentication_id: target.expected_authentication_id,
             reauthentication_principal_uid: target.reauthentication_principal_uid
           ) do
      BrowserAPI.ok(conn, %{challengeID: sent.challenge_id, expiresAt: sent.expires_at})
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp ensure_otp_target_allowed(%{assigns: %{pod_email_otp_disabled: true}}, %{purpose: purpose})
       when purpose in [:pod, :oauth],
       do: {:error, :identity_provider_not_allowed}

  defp ensure_otp_target_allowed(_conn, %{purpose: :oauth, oauth_request: %{status: status}})
       when status != :pending,
       do: {:error, :login_expired}

  defp ensure_otp_target_allowed(_conn, _target), do: :ok

  defp perform_verify_email_otp(conn, params) do
    host_tenant_id =
      case conn.assigns[:host_context] do
        {:pod, id} -> id
        _ -> nil
      end

    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, completed} <-
           Ankole.Authn.Info.run(
             Ankole.Principals.SiteCredential,
             :email_otp,
             :verify,
             %{
               browser: WebSession.browser_reference(conn),
               challenge_id: params["challengeID"],
               code: params["code"],
               source: to_string(:inet.ntoa(conn.remote_ip))
             },
             host_tenant_id: host_tenant_id
           ) do
      conn = WebSession.put_authentication(conn, completed.browser, completed.authentication)
      BrowserAPI.ok(conn, %{status: "ok", returnTo: verified_return_to(conn, completed)})
    else
      {:ok, false} -> error(conn, 409, "setup is not complete")
      {:error, reason} -> login_error(conn, reason)
    end
  end

  defp verified_return_to(conn, %{purpose: :oauth, oauth_request: request}),
    do: PodURL.oauth_return_to(conn, request)

  defp verified_return_to(conn, %{purpose: :pod, tenant_id: tenant_id} = completed) do
    {:ok, tenant} = Ankole.Tenants.get(tenant_id)

    AnkoleWeb.PodURL.origin(conn, tenant) <>
      WebSession.safe_return_to(completed.ceremony_context["return_to"])
  end

  defp verified_return_to(conn, %{purpose: :site, tenant_id: tenant_id} = completed)
       when is_binary(tenant_id) do
    {:ok, tenant} = Ankole.Tenants.get(tenant_id)

    PodURL.origin(conn, tenant) <>
      WebSession.safe_return_to(completed.ceremony_context["return_to"])
  end

  defp verified_return_to(_conn, %{purpose: :site}), do: "/account"

  defp verified_return_to(_conn, completed),
    do: WebSession.safe_return_to(completed.ceremony_context["return_to"])

  defp login_error(_conn, reason), do: AnkoleWeb.BrowserAPI.Error.login(reason)
  defp error(_conn, status, reason), do: BrowserAPI.error(status, reason)
end
