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
  alias AnkoleWeb.BrowserAPI

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

  def login_context(conn, params) when is_map(params) do
    case resolve_login_target(conn, params) do
      {:ok, target} ->
        if is_nil(target.tenant_id), do: WebSession.put_privileged_tenant()
        Plug.Conn.assign(conn, :login_target, {:ok, target})

      {:error, _} = error ->
        _ = WebSession.put_privileged_tenant()
        Plug.Conn.assign(conn, :login_target, error)
    end
  end

  def resolve_login_target(conn, params) when is_map(params) do
    oauth_request = non_empty(params["oauthRequest"] || params["oauth_request"])
    purpose = non_empty(params["purpose"])

    cond do
      not is_nil(oauth_request) ->
        resolve_oauth_target(conn, oauth_request)

      purpose == "console" ->
        resolve_console_target(conn, params)

      purpose == "site" or
          (is_nil(purpose) and conn.assigns[:default_login_purpose] == :site and
             not match?({:pod, _}, conn.assigns[:host_context])) ->
        resolve_site_target(conn, params)

      purpose in [nil, "pod"] ->
        resolve_pod_target(conn, params)

      true ->
        {:error, :login_expired}
    end
  end

  defp resolve_oauth_target(conn, id) do
    with {:ok, request} <- AuthorizationRequests.get(WebSession.browser_reference(conn), id),
         :ok <- verify_pod_host(conn, request.tenant_id),
         :ok <- Ankole.Repo.put_tenant_id(request.tenant_id) do
      {:ok,
       %{
         purpose: :oauth,
         tenant_id: request.tenant_id,
         mode: Map.get(conn.assigns, :browser_login_mode, :replace),
         oauth_request: request,
         oauth_request_id: request.id,
         request_params: request.request,
         return_to: AnkoleWeb.AuthController.oauth_return_to(request),
         started_revision: request.started_revision,
         expected_authentication_id: request.expected_authentication_id,
         reauthentication_principal_uid: nil,
         invitation_id: nil
       }}
    end
  end

  defp resolve_console_target(conn, params) do
    if match?({:pod, _}, conn.assigns[:host_context]) do
      {:error, :login_expired}
    else
      with :ok <- WebSession.put_privileged_tenant() do
        prompt = if params["prompt"] == "login", do: ["login"], else: []

        {:ok,
         %{
           purpose: :console,
           tenant_id: Ankole.Repo.tenant_id!(),
           mode: Map.get(conn.assigns, :browser_login_mode, :replace),
           oauth_request: nil,
           oauth_request_id: nil,
           request_params: %{"prompt" => prompt},
           return_to: default_return_to(:console, params["returnTo"] || params["return_to"]),
           started_revision: nil,
           expected_authentication_id: nil,
           reauthentication_principal_uid: nil,
           invitation_id: nil
         }}
      end
    end
  end

  defp resolve_site_target(conn, params) do
    if match?({:pod, _}, conn.assigns[:host_context]) do
      {:error, :login_expired}
    else
      with :ok <- WebSession.put_privileged_tenant() do
        {:ok,
         %{
           purpose: :site,
           tenant_id: nil,
           mode: :add,
           oauth_request: nil,
           oauth_request_id: nil,
           request_params: %{},
           return_to: default_return_to(:site, params["returnTo"] || params["return_to"]),
           started_revision: nil,
           expected_authentication_id: nil,
           reauthentication_principal_uid: nil,
           invitation_id: nil
         }}
      end
    end
  end

  defp resolve_pod_target(conn, params) do
    with {:ok, tenant_id} <- pod_target_tenant(conn),
         :ok <- Ankole.Repo.put_tenant_id(tenant_id),
         {:ok, reauth} <- resolve_reauth(conn, params, tenant_id),
         {:ok, invitation_id} <- resolve_invitation(conn, params, tenant_id) do
      reauthenticate? = not is_nil(reauth)
      prompt = if params["prompt"] == "login", do: ["login"], else: []

      {:ok,
       %{
         purpose: :pod,
         tenant_id: tenant_id,
         mode: :add,
         oauth_request: nil,
         oauth_request_id: nil,
         request_params: %{"prompt" => prompt, "reauthenticate" => reauthenticate?},
         return_to: default_return_to(:pod, params["returnTo"] || params["return_to"]),
         started_revision: reauth && reauth.started_revision,
         expected_authentication_id: reauth && reauth.authentication_id,
         reauthentication_principal_uid: reauth && reauth.uid,
         invitation_id: invitation_id
       }}
    end
  end

  defp pod_target_tenant(conn) do
    case AnkoleWeb.Plugs.RequirePodSession.target_tenant(conn) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      _ -> {:error, :login_expired}
    end
  end

  defp verify_pod_host(%{assigns: %{host_context: {:pod, host_tenant_id}}}, tenant_id)
       when host_tenant_id != tenant_id,
       do: {:error, :login_expired}

  defp verify_pod_host(_conn, _tenant_id), do: :ok

  defp resolve_reauth(conn, params, tenant_id) do
    case non_empty(params["reauth"]) do
      nil -> {:ok, nil}
      ticket -> WebSession.unseal_reauthentication(conn, ticket, tenant_id)
    end
  end

  defp resolve_invitation(conn, params, tenant_id) do
    sealed = non_empty(params["invitation"])
    token = non_empty(params["invitationToken"] || params["invitation_token"])

    cond do
      not is_nil(sealed) ->
        with {:ok, id} <- WebSession.unseal_membership_invitation(conn, sealed, tenant_id),
             {:ok, _} <- Ankole.Principals.invitation_for_login(id),
             do: {:ok, id}

      not is_nil(token) ->
        with {:ok, %{id: id, tenant_id: ^tenant_id}} <- Ankole.Principals.locate_invitation(token),
             {:ok, _} <- Ankole.Principals.invitation_for_login(id) do
          {:ok, id}
        else
          _ -> {:error, :login_expired}
        end

      true ->
        {:ok, nil}
    end
  end

  defp default_return_to(:console, nil), do: AnkoleWeb.SiteAdminConsole.path()
  defp default_return_to(:site, nil), do: "/account"
  defp default_return_to(:pod, nil), do: "/"
  defp default_return_to(_, value), do: WebSession.safe_return_to(value)

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_), do: nil

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

        with {:ok, _} <- Ankole.Principals.invitation_for_login(invitation && invitation.id),
             {:ok, query} <- membership_login_query(conn, invitation, tenant.id) do
          {:ok, conn, AnkoleWeb.PodURL.origin(conn, tenant) <> "/sessions/new?" <> query}
        end
      end)
    else
      {:ok, _} -> {:error, :invalid_authentication}
      error -> error
    end
  end

  defp membership_login_query(_conn, nil, _tenant_id),
    do: {:ok, URI.encode_query(%{"switch" => "1", "prompt" => "login"})}

  defp membership_login_query(conn, invitation, tenant_id) do
    with {:ok, ticket} <-
           WebSession.seal_membership_invitation(conn, invitation.id, tenant_id) do
      {:ok,
       URI.encode_query(%{
         "switch" => "1",
         "prompt" => "login",
         "invitation" => ticket
       })}
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
    case non_empty(params["oauthRequest"]) do
      id when is_binary(id) ->
        with {:ok, request} <-
               AuthorizationRequests.select_identity(
                 WebSession.browser_reference(conn),
                 id,
                 reference
               ),
             :ok <- verify_pod_host(conn, request.tenant_id) do
          {:ok, AnkoleWeb.AuthController.oauth_return_to(request)}
        end

      nil ->
        with {:ok, target} <- resolve_pod_target(conn, params),
             false <- LoginPolicy.reauthentication_required?(target.request_params),
             %{} = auth <- BrowserSessions.identity(reference, target.tenant_id),
             true <- LoginPolicy.can_reuse?(auth, target.request_params),
             {:ok, _} <-
               BrowserSessions.activate(
                 WebSession.browser_reference(conn),
                 reference,
                 target.tenant_id
               ) do
          {:ok, target.return_to}
        else
          true -> {:error, :reauthentication_required}
          false -> {:error, :reauthentication_required}
          nil -> {:error, :invalid_authentication}
          error -> error
        end
    end
  end

  defp perform_identity_providers(conn, params) do
    with {:ok, target} <- resolve_login_target(conn, params),
         {:ok, providers} <- providers_for_target(target) do
      BrowserAPI.ok(conn, %{
        identity: current_identity(conn),
        identities: identity_choices(conn, target),
        purpose: Atom.to_string(target.purpose),
        requireSSOForMembers:
          not is_nil(target.tenant_id) and
            elem(Ankole.Principals.PodLoginPolicy.get(), 1)["require_sso_for_members"],
        selectAccount:
          target.purpose == :pod or
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

  defp providers_for_target(%{purpose: purpose}) when purpose in [:console, :pod],
    do: LoginPolicy.login_providers()

  defp providers_for_target(%{purpose: :oauth, oauth_request: request}) do
    with {:ok, client} <- Ankole.OIDC.get_active_client(request.request["client_id"]),
         do: LoginPolicy.providers(client, request.request)
  end

  defp providers_for_target(%{purpose: :site}),
    do: {:ok, Ankole.IdentityProviders.SiteSources.providers()}

  defp perform_request_email_otp(conn, params) do
    with {:ok, true} <- SetupConfig.completed?(),
         {:ok, target} <- resolve_login_target(conn, params),
         :ok <- ensure_otp_target_pending(target),
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

  defp ensure_otp_target_pending(%{purpose: :oauth, oauth_request: %{status: status}})
       when status != :pending,
       do: {:error, :login_expired}

  defp ensure_otp_target_pending(_target), do: :ok

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

  defp verified_return_to(_conn, %{purpose: :oauth, oauth_request: request}),
    do: AnkoleWeb.AuthController.oauth_return_to(request)

  defp verified_return_to(conn, %{purpose: :pod, tenant_id: tenant_id} = completed) do
    {:ok, tenant} = Ankole.Tenants.get(tenant_id)

    AnkoleWeb.PodURL.origin(conn, tenant) <>
      WebSession.safe_return_to(completed.ceremony_context["return_to"])
  end

  defp verified_return_to(_conn, completed),
    do: WebSession.safe_return_to(completed.ceremony_context["return_to"])

  defp login_error(_conn, reason), do: AnkoleWeb.BrowserAPI.Error.login(reason)
  defp error(_conn, status, reason), do: BrowserAPI.error(status, reason)
end
