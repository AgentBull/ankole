defmodule AnkoleWeb.BrowserAuth.Targets do
  @moduledoc "Resolves browser login ceremonies and their tenant boundaries."
  alias Ankole.OIDC.AuthorizationRequests
  alias AnkoleWeb.Session, as: WebSession

  def assign_context(conn, params) when is_map(params) do
    case resolve(conn, params) do
      {:ok, target} ->
        if is_nil(target.tenant_id), do: WebSession.put_privileged_tenant()
        Plug.Conn.assign(conn, :login_target, {:ok, target})

      {:error, _} = error ->
        _ = WebSession.put_privileged_tenant()
        Plug.Conn.assign(conn, :login_target, error)
    end
  end

  def resolve(conn, params) when is_map(params) do
    oauth_request = non_empty(params["oauthRequest"] || params["oauth_request"])
    purpose = non_empty(params["purpose"])

    cond do
      not is_nil(oauth_request) ->
        resolve_oauth_target(conn, oauth_request)

      purpose == "console" ->
        resolve_console_target(conn, params)

      purpose in [nil, "site"] and conn.assigns[:default_login_purpose] == :site and
          not match?({:pod, _}, conn.assigns[:host_context]) ->
        resolve_site_target(conn, params)

      purpose in [nil, "pod"] and conn.assigns[:default_login_purpose] != :site ->
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
         return_to: AnkoleWeb.PodURL.oauth_return_to(conn, request),
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
      with :ok <- WebSession.put_privileged_tenant(),
           {:ok, target_tenant} <- resolve_site_target_tenant(params),
           {:ok, reauth, invitation_id} <-
             resolve_site_pod_ceremony(conn, params, target_tenant) do
        reauthenticate? = not is_nil(reauth)
        prompt = if params["prompt"] == "login", do: ["login"], else: []
        raw_return_to = params["returnTo"] || params["return_to"]

        return_to =
          if target_tenant,
            do: default_return_to(:pod, raw_return_to),
            else: default_return_to(:site, raw_return_to)

        {:ok,
         %{
           purpose: :site,
           tenant_id: nil,
           target_tenant: target_tenant,
           target_tenant_id: target_tenant && target_tenant.id,
           mode: :add,
           oauth_request: nil,
           oauth_request_id: nil,
           request_params: %{"prompt" => prompt, "reauthenticate" => reauthenticate?},
           return_to: return_to,
           started_revision: reauth && reauth.started_revision,
           expected_authentication_id: reauth && reauth.authentication_id,
           reauthentication_principal_uid: reauth && reauth.uid,
           invitation_id: invitation_id
         }}
      end
    end
  end

  defp resolve_site_target_tenant(params) do
    raw_tid = non_empty(params["tenantID"] || params["tenant_id"])
    raw_token = non_empty(params["invitationToken"] || params["invitation_token"])

    cond do
      is_binary(raw_tid) ->
        with {:ok, id} <- Ecto.UUID.cast(raw_tid),
             {:ok, tenant} <- Ankole.Tenants.get(id),
             true <- Ankole.Tenants.accepting_work?(tenant) do
          {:ok, tenant}
        else
          _ -> {:error, :login_expired}
        end

      is_binary(raw_token) ->
        with {:ok, invitation} <- Ankole.Principals.locate_invitation(raw_token),
             {:ok, tenant} <- Ankole.Tenants.get(invitation.tenant_id),
             true <- Ankole.Tenants.accepting_work?(tenant) do
          {:ok, tenant}
        else
          _ -> {:error, :login_expired}
        end

      not is_nil(non_empty(params["reauth"])) or not is_nil(non_empty(params["invitation"])) ->
        {:error, :login_expired}

      true ->
        {:ok, nil}
    end
  end

  defp resolve_site_pod_ceremony(_conn, _params, nil), do: {:ok, nil, nil}

  defp resolve_site_pod_ceremony(conn, params, %Ankole.Tenants.Tenant{id: tenant_id}) do
    Ankole.Repo.with_tenant(tenant_id, fn ->
      with {:ok, reauth} <- resolve_reauth(conn, params, tenant_id),
           {:ok, invitation_id} <- resolve_invitation(conn, params, tenant_id),
           do: {:ok, reauth, invitation_id}
    end)
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

  def verify_pod_host(%{assigns: %{host_context: {:pod, host_tenant_id}}}, tenant_id)
      when host_tenant_id != tenant_id,
      do: {:error, :login_expired}

  def verify_pod_host(_conn, _tenant_id), do: :ok

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
end
