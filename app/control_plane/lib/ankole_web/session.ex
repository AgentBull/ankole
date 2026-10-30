defmodule AnkoleWeb.Session do
  @moduledoc "Browser grouping, independent authentication cookies, and isolated setup state."
  import Plug.Conn
  alias Ankole.BrowserSessions
  alias Ankole.Principals.HumanAccess
  alias Ankole.AuthZ
  alias AnkoleWeb.SessionCookieStore
  alias AnkoleWeb.SessionCookies

  @browser_key :browser_session
  @setup_ttl 24 * 60 * 60
  @state_ttl 10 * 60
  def browser_reference(conn), do: get_session(conn, @browser_key)

  def ensure_browser(conn) do
    case BrowserSessions.get(browser_reference(conn)) do
      {:ok, _} ->
        conn

      {:error, :browser_session_expired} ->
        {:ok, browser} = BrowserSessions.create()
        put_session(conn, @browser_key, BrowserSessions.reference(browser))
    end
  end

  def put_privileged_tenant do
    with {:ok, tenant} <- Ankole.Tenants.privileged(), do: Ankole.Repo.put_tenant_id(tenant.id)
  end

  @doc "Writes a verified authentication after login."
  def put_authentication(
        conn,
        %BrowserSessions.Session{} = browser,
        %BrowserSessions.Authentication{} = authentication
      ) do
    reference = BrowserSessions.reference(authentication)

    conn
    |> put_session(@browser_key, BrowserSessions.reference(browser))
    |> put_authentication_cookie(authentication)
    |> put_private(:browser_authentication_ref, reference)
    |> put_private(
      :browser_authentication_proofs,
      [reference | conn.private[:browser_authentication_proofs] || []]
    )
  end

  @doc "Writes a verified tenant authentication after setup or test sign-in."
  def put_tenant_session(conn, attrs) do
    attrs = stringify_keys(attrs)
    conn = ensure_browser(conn)

    with {:ok, version} <- HumanAccess.current_version(attrs["principal_uid"]),
         {:ok, %{browser: browser, authentication: authentication}} <-
           BrowserSessions.authenticate(
             browser_reference(conn),
             Map.put(attrs, "access_version", version)
           ) do
      put_authentication(conn, browser, authentication)
    else
      {:error, reason} -> raise "Cannot establish tenant authentication: #{inspect(reason)}"
    end
  end

  @doc "Pins a proven authentication on the current document and synchronizes its CSRF state."
  def pin_authentication(conn, reference) when is_map(reference) do
    conn = put_private(conn, :browser_authentication_ref, reference)

    case BrowserSessions.get_authentication(reference) do
      {:ok, authentication} when is_binary(conn.secret_key_base) ->
        Plug.CSRFProtection.delete_csrf_token()
        :ok = Plug.CSRFProtection.load_state(conn.secret_key_base, authentication.csrf_token)

        register_before_send(conn, fn conn ->
          Plug.CSRFProtection.delete_csrf_token()
          :ok = Plug.CSRFProtection.load_state(nil, nil)
          conn
        end)

      _ ->
        conn
    end
  end

  def authentication_references(conn) do
    conn = fetch_cookies(conn)

    prefix = SessionCookies.authentication_prefix()

    cookie_refs =
      Enum.flat_map(conn.req_cookies, fn {name, value} ->
        if String.starts_with?(name, prefix) do
          {_sid, reference} = SessionCookieStore.get(cookie_conn(conn), value, cookie_options())

          if reference["id"] == String.replace_prefix(name, prefix, ""),
            do: [reference],
            else: []
        else
          []
        end
      end)

    (cookie_refs ++ (conn.private[:browser_authentication_proofs] || []))
    |> Enum.uniq()
    |> Enum.filter(fn reference ->
      case {BrowserSessions.get_authentication(reference), browser_reference(conn)} do
        {{:ok, authentication}, %{"id" => browser_id}} -> authentication.browser_id == browser_id
        _ -> false
      end
    end)
  end

  def authentication_reference(%{assigns: %{pod_authentication: identity}, private: private})
      when not is_map_key(private, :browser_authentication_ref) do
    %{"id" => identity["authentication_id"], "revision" => identity["authentication_revision"]}
  end

  def authentication_reference(conn) do
    candidate = authentication_candidate(conn)
    if authentication_proven?(conn, candidate), do: candidate
  end

  def invalid_authentication_selection?(conn), do: authentication_candidate(conn) == :invalid

  defp authentication_candidate(%{private: %{browser_authentication_ref: ref}}), do: ref

  defp authentication_candidate(conn) do
    case get_req_header(conn, "x-ankole-authentication") do
      [] ->
        parameter_reference(conn) ||
          BrowserSessions.current_reference(browser_reference(conn))

      [value] ->
        decode_reference(value)

      _ ->
        :invalid
    end
  end

  def authentication_proven?(conn, reference) do
    not is_nil(proven_authentication(conn, reference))
  end

  defp proven_authentication(conn, reference) do
    with true <- authentication_cookie_proven?(conn, reference),
         %{"id" => browser_id} <- browser_reference(conn),
         {:ok, %{browser_id: ^browser_id} = authentication} <-
           BrowserSessions.get_authentication(reference),
         do: authentication,
         else: (_ -> nil)
  end

  defp authentication_cookie_proven?(conn, %{"id" => id} = reference) when is_binary(id) do
    conn = fetch_cookies(conn)
    raw = conn.req_cookies[SessionCookies.authentication_prefix() <> id]

    {_sid, cookie_ref} =
      SessionCookieStore.get(cookie_conn(conn), raw, cookie_options())

    cookie_ref == reference or reference in (conn.private[:browser_authentication_proofs] || [])
  end

  defp authentication_cookie_proven?(_, _), do: false

  defp put_authentication_cookie(conn, authentication) do
    value =
      SessionCookieStore.put(
        cookie_conn(conn),
        nil,
        BrowserSessions.reference(authentication),
        cookie_options()
      )

    put_resp_cookie(
      conn,
      SessionCookies.authentication_prefix() <> authentication.id,
      value,
      Keyword.put(
        SessionCookies.options(),
        :max_age,
        max(DateTime.diff(authentication.expires_at, DateTime.utc_now()), 0)
      )
    )
  end

  # EventSource and file subresources cannot send the document's authentication
  # header. Other API URLs must not select a different signed-in identity.
  defp parameter_reference(conn) do
    case {conn.method, String.split(conn.request_path, "/", trim: true)} do
      {"GET", ["pod", "applet-frame", "current", _id, _revision | _]} ->
        BrowserSessions.current_reference(browser_reference(conn))

      {"GET", ["pod", "applet-frame", ref, _id, _revision | _]} ->
        decode_reference(ref)

      {"GET", ["api", "v2", "pod", "conversations", _id, "events"]} ->
        parameter_authentication(conn)

      {"GET", ["api", "v2", "pod", "pages", _id, "files", "content"]} ->
        parameter_authentication(conn)

      {"GET", ["api", "v2", "pod", "metadata", "files", "content"]} ->
        parameter_authentication(conn)

      {"GET", ["api", "v2", "pod", "conversations", _id, "attachments", _message_id]} ->
        parameter_authentication(conn)

      {_, ["api" | _]} ->
        if param(conn, "authentication_ref"), do: :invalid

      _ ->
        nil
    end
  end

  defp parameter_authentication(conn) do
    case param(conn, "authentication_ref") do
      nil -> nil
      value -> decode_reference(value)
    end
  end

  defp decode_reference(value) do
    case BrowserSessions.decode_reference(value) do
      {:ok, ref} -> ref
      _ -> :invalid
    end
  end

  def authorization_reference(conn, %{
        authentication_id: id,
        authentication_revision: revision
      })
      when is_binary(id) and is_integer(revision) do
    ref = %{"id" => id, "revision" => revision}
    if authentication_proven?(conn, ref), do: ref
  end

  def authorization_reference(_conn, _request), do: nil

  def seal_reauthentication(conn, uid, authentication_ref, tenant_id)
      when is_binary(uid) and is_map(authentication_ref) and is_binary(tenant_id) do
    with {:ok, browser} <- BrowserSessions.get(browser_reference(conn)),
         true <- authentication_proven?(conn, authentication_ref),
         payload =
           Ankole.JSON.encode!(%{
             "uid" => uid,
             "authentication_id" => authentication_ref["id"],
             "started_revision" => browser.revision,
             "exp" => System.system_time(:second) + @state_ttl
           }),
         {:ok, ticket} <-
           Ankole.SecretKeyBase.seal(payload, "browser.reauth", [browser.id, tenant_id]) do
      {:ok, ticket}
    else
      false -> {:error, :invalid_authentication}
      error -> error
    end
  end

  def unseal_reauthentication(conn, ticket, tenant_id)
      when is_binary(ticket) and ticket != "" and is_binary(tenant_id) do
    with {:ok, browser} <- BrowserSessions.get(browser_reference(conn)),
         {:ok, json} <-
           Ankole.SecretKeyBase.unseal(ticket, "browser.reauth", [browser.id, tenant_id]),
         {:ok,
          %{
            "uid" => uid,
            "authentication_id" => authentication_id,
            "started_revision" => started_revision,
            "exp" => exp
          }} <- Ankole.JSON.decode(json),
         true <-
           is_binary(uid) and is_binary(authentication_id) and is_integer(started_revision) and
             started_revision >= browser.logout_revision and exp > System.system_time(:second) do
      {:ok,
       %{
         uid: uid,
         authentication_id: authentication_id,
         started_revision: started_revision
       }}
    else
      _ -> {:error, :login_expired}
    end
  end

  def unseal_reauthentication(_, _, _), do: {:error, :login_expired}

  def seal_membership_invitation(conn, invitation_id, tenant_id)
      when is_binary(invitation_id) and is_binary(tenant_id) do
    with {:ok, browser} <- BrowserSessions.get(browser_reference(conn)),
         payload =
           Ankole.JSON.encode!(%{
             "invitation_id" => invitation_id,
             "exp" => System.system_time(:second) + @state_ttl
           }),
         {:ok, ticket} <-
           Ankole.SecretKeyBase.seal(payload, "browser.invitation", [browser.id, tenant_id]) do
      {:ok, ticket}
    end
  end

  def unseal_membership_invitation(conn, ticket, tenant_id)
      when is_binary(ticket) and ticket != "" and is_binary(tenant_id) do
    with {:ok, browser} <- BrowserSessions.get(browser_reference(conn)),
         {:ok, json} <-
           Ankole.SecretKeyBase.unseal(ticket, "browser.invitation", [browser.id, tenant_id]),
         {:ok, %{"invitation_id" => invitation_id, "exp" => exp}} <- Ankole.JSON.decode(json),
         true <- is_binary(invitation_id) and exp > System.system_time(:second) do
      {:ok, invitation_id}
    else
      _ -> {:error, :login_expired}
    end
  end

  def unseal_membership_invitation(_, _, _), do: {:error, :login_expired}

  def seal_console_return(return_to, privileged_tenant_id)
      when is_binary(return_to) and is_binary(privileged_tenant_id) do
    safe = safe_console_return_to(return_to)

    payload =
      Ankole.JSON.encode!(%{
        "return_to" => safe,
        "exp" => System.system_time(:second) + @state_ttl
      })

    Ankole.SecretKeyBase.seal(payload, "browser.console_return", [privileged_tenant_id])
  end

  def unseal_console_return(ticket, tenant_id)
      when is_binary(ticket) and ticket != "" and is_binary(tenant_id) do
    with {:ok, privileged} <- Ankole.Tenants.privileged(),
         true <- privileged.id == tenant_id,
         {:ok, json} <-
           Ankole.SecretKeyBase.unseal(ticket, "browser.console_return", [privileged.id]),
         {:ok, %{"return_to" => return_to, "exp" => exp}} <- Ankole.JSON.decode(json),
         true <-
           is_binary(return_to) and exp > System.system_time(:second) and
             valid_console_return_to?(return_to) do
      {:ok, return_to}
    else
      _ -> {:error, :login_expired}
    end
  end

  def unseal_console_return(_, _), do: {:error, :login_expired}

  defp safe_console_return_to(value) do
    safe = safe_return_to(value)
    if valid_console_return_to?(safe), do: safe, else: AnkoleWeb.SiteAdminConsole.path()
  end

  defp valid_console_return_to?(path) do
    base = AnkoleWeb.SiteAdminConsole.path()
    path == base or String.starts_with?(path, [base <> "/", base <> "?"])
  end

  def current_authentication(conn) do
    with %BrowserSessions.Authentication{} = authentication <-
           proven_authentication(conn, authentication_candidate(conn)),
         tenant_id when is_binary(tenant_id) <-
           selected_tenant(conn, authentication),
         do: BrowserSessions.identity(BrowserSessions.reference(authentication), tenant_id),
         else: (_ -> nil)
  end

  @doc "Resolves an explicit Pod selector against the request host; callers own any fallback."
  def request_tenant(conn, explicit \\ nil) do
    selected =
      case {get_req_header(conn, "x-ankole-pod"), explicit} do
        {[], id} -> {:ok, id}
        {[id], nil} -> {:ok, id}
        {[id], id} -> {:ok, id}
        _ -> {:error, :tenant_mismatch}
      end

    with {:ok, selected} <- selected,
         {:ok, selected} <- cast_request_tenant(selected),
         host = Ankole.Repo.tenant_id(),
         true <- is_nil(selected) or is_nil(host) or selected == host do
      {:ok, host || selected}
    else
      false -> {:error, :tenant_mismatch}
      error -> error
    end
  end

  defp cast_request_tenant(nil), do: {:ok, nil}

  defp cast_request_tenant(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp selected_tenant(conn, authentication) do
    case request_tenant(conn) do
      {:ok, id} ->
        id || authentication.tenant_id ||
          case BrowserSessions.get(browser_reference(conn)) do
            {:ok, browser} -> browser.active_tenant_id
            _ -> nil
          end

      _ ->
        nil
    end
  end

  def site_admin_session(conn) do
    with {:ok, privileged} <- Ankole.Tenants.privileged(),
         {:ok, identity, _ref} <-
           site_admin_for_reference(conn, authentication_candidate(conn), privileged.id) do
      identity
    else
      _ -> nil
    end
  end

  def authorize_site_admin_session(conn) do
    candidate = authentication_candidate(conn)

    if candidate == :invalid do
      :unauthorized
    else
      case Ankole.Tenants.privileged() do
        {:ok, privileged} ->
          case site_admin_for_reference(conn, candidate, privileged.id) do
            {:ok, identity, _ref} ->
              {:ok, identity}

            :forbidden ->
              :forbidden

            :unauthenticated ->
              if active_non_admin_authentication?(conn, candidate),
                do: :forbidden,
                else: :unauthorized
          end

        _ ->
          :unauthorized
      end
    end
  end

  defp active_non_admin_authentication?(conn, candidate) do
    if get_req_header(conn, "x-ankole-authentication") != [] do
      not is_nil(proven_authentication(conn, candidate)) and
        BrowserSessions.identities(candidate) != []
    else
      (not is_nil(proven_authentication(conn, candidate)) and
         BrowserSessions.identities(candidate) != []) or
        Enum.any?(authentication_references(conn), &(BrowserSessions.identities(&1) != []))
    end
  end

  def resolve_site_admin_session(conn) do
    with {:ok, privileged} <- Ankole.Tenants.privileged() do
      candidate = authentication_candidate(conn)
      result = site_admin_for_reference(conn, candidate, privileged.id)

      if match?({:ok, _, _}, result) or
           get_req_header(conn, "x-ankole-authentication") != [] or candidate == :invalid do
        result
      else
        conn
        |> authentication_references()
        |> Enum.reject(&(&1 == candidate))
        |> Enum.reduce_while(result, fn ref, result ->
          case site_admin_for_reference(conn, ref, privileged.id) do
            {:ok, _, _} = resolved ->
              {:halt, resolved}

            :forbidden ->
              {:cont, :forbidden}

            :unauthenticated ->
              {:cont, result}
          end
        end)
      end
    else
      _ -> :unauthenticated
    end
  end

  def oauth_session(conn) do
    reference = authentication_candidate(conn)

    with true <- is_map(reference),
         tenant_id when is_binary(tenant_id) <- oauth_tenant_id(conn, reference) do
      reference_identity(conn, reference, tenant_id)
    else
      _ -> nil
    end
  end

  defp oauth_tenant_id(conn, reference) do
    Ankole.Repo.tenant_id() ||
      with {:ok, authentication} <- BrowserSessions.get_authentication(reference) do
        authentication.tenant_id ||
          case BrowserSessions.get(browser_reference(conn)) do
            {:ok, browser} -> browser.active_tenant_id
            _ -> nil
          end
      else
        _ -> nil
      end
  end

  def pod_session(conn) do
    case Ankole.Repo.tenant_id() do
      tenant_id when is_binary(tenant_id) ->
        reference_identity(conn, authentication_candidate(conn), tenant_id)

      nil ->
        nil
    end
  end

  defp site_admin_for_reference(conn, reference, privileged_tenant_id) do
    case reference_identity(conn, reference, privileged_tenant_id) do
      %{"principal_uid" => uid} = identity ->
        if Ankole.Repo.with_tenant(privileged_tenant_id, fn -> AuthZ.site_admin?(uid) end),
          do: {:ok, identity, reference},
          else: :forbidden

      nil ->
        :unauthenticated
    end
  end

  defp reference_identity(conn, reference, tenant_id) do
    with true <- authentication_cookie_proven?(conn, reference),
         %{"id" => browser_id} <- browser_reference(conn),
         %{"browser_id" => ^browser_id} = identity <-
           BrowserSessions.identity(reference, tenant_id),
         do: identity,
         else: (_ -> nil)
  end

  def csrf_state(conn) do
    cond do
      ceremony_shell_route?(conn) ->
        nil

      ceremony_api_route?(conn) ->
        if conn.method in ["GET", "HEAD", "OPTIONS"] or session_csrf_matches?(conn),
          do: nil,
          else: authentication_csrf_state(conn)

      true ->
        authentication_csrf_state(conn)
    end
  end

  defp authentication_csrf_state(conn) do
    case proven_authentication(conn, authentication_candidate(conn)) do
      %BrowserSessions.Authentication{} = authentication -> authentication.csrf_token
      _ -> nil
    end
  end

  defp session_csrf_matches?(conn) do
    state = get_session(conn, "_csrf_token")
    header = List.first(get_req_header(conn, "x-csrf-token"))
    body = if is_non_struct_map(conn.body_params), do: conn.body_params["_csrf_token"]

    is_binary(state) and
      (Plug.CSRFProtection.valid_state_and_csrf_token?(state, header) or
         Plug.CSRFProtection.valid_state_and_csrf_token?(state, body))
  end

  defp ceremony_shell_route?(conn) do
    conn.request_path in [
      "/sessions/new",
      "/sessions/logged-out",
      "/oauth/logout",
      "/setup"
    ] or
      String.starts_with?(conn.request_path, [
        "/setup/",
        "/join/",
        "/sessions/oidc/"
      ])
  end

  defp ceremony_api_route?(conn) do
    conn.request_path in [
      "/oauth/logout/confirm",
      "/api/v2/browser/pod-logins"
    ] or
      String.starts_with?(conn.request_path, [
        "/api/v2/browser/setup/",
        "/api/v2/browser/invitations/",
        "/api/v2/browser/sessions/"
      ])
  end

  def param(conn, key) do
    params = if is_map(conn.params), do: conn.params, else: %{}

    body =
      case conn.body_params do
        %{"data" => %{} = data} -> data
        %{} = body -> body
        _ -> %{}
      end

    query = fetch_query_params(conn).query_params

    case Map.fetch(body, key) do
      {:ok, value} -> value
      :error -> Map.get(params, key) || Map.get(query, key)
    end
  end

  def revoke_authentication(conn) do
    with ref when is_map(ref) <- authentication_reference(conn),
         {:ok, target_tenant_id} <- revocation_tenant(conn),
         {:ok, authentication_revoked?} <-
           revoke_target(browser_reference(conn), ref, target_tenant_id) do
      conn = put_private(conn, :browser_authentication_ref, nil)

      if authentication_revoked? do
        {:ok,
         conn
         |> delete_resp_cookie(
           SessionCookies.authentication_prefix() <> ref["id"],
           SessionCookies.delete_options()
         )
         |> put_private(
           :browser_authentication_proofs,
           Enum.reject(conn.private[:browser_authentication_proofs] || [], &(&1 == ref))
         )}
      else
        {:ok, conn}
      end
    else
      {:error, :invalid_authentication} -> {:error, :invalid_authentication}
      _ -> {:error, :browser_session_expired}
    end
  end

  defp revocation_tenant(conn) do
    case request_tenant(conn) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :invalid_authentication}
    end
  end

  defp revoke_target(browser_ref, ref, nil) do
    with {:ok, _} <- BrowserSessions.revoke(browser_ref, ref), do: {:ok, true}
  end

  defp revoke_target(browser_ref, ref, tenant_id) do
    with {:ok, %{authentication_revoked?: revoked?}} <-
           BrowserSessions.revoke_pod(browser_ref, ref, tenant_id),
         do: {:ok, revoked?}
  end

  def logout(conn) do
    case BrowserSessions.logout(browser_reference(conn)) do
      {:ok, _} -> {:ok, clear_authentication_cookies(conn)}
      error -> error
    end
  end

  def clear_authentication_cookies(conn) do
    conn = fetch_cookies(conn)

    conn =
      Enum.reduce(conn.req_cookies, conn, fn {name, _}, acc ->
        if String.starts_with?(name, SessionCookies.authentication_prefix()) do
          delete_resp_cookie(acc, name, SessionCookies.delete_options())
        else
          acc
        end
      end)

    conn
    |> put_private(:browser_authentication_ref, nil)
    |> put_private(:browser_authentication_proofs, [])
  end

  defp cookie_options,
    do: SessionCookieStore.init(key_context: "browser.authentication", log: false)

  defp cookie_conn(%{secret_key_base: nil} = conn),
    do: %{conn | secret_key_base: AnkoleWeb.Endpoint.config(:secret_key_base)}

  defp cookie_conn(conn), do: conn

  def put_setup_session(conn), do: put_expiring_session(conn, :setup_session, %{}, @setup_ttl)

  def setup_session_active?(conn),
    do: not is_nil(active_payload(get_session(conn, :setup_session)))

  def clear_setup_session(conn) do
    conn
    |> delete_session(:setup_session)
    |> delete_session(:setup_oidc_state)
    |> delete_session(:setup_brain_packs)
  end

  def put_setup_brain_packs(conn, packs) when is_list(packs),
    do: put_expiring_session(conn, :setup_brain_packs, %{packs: packs}, @setup_ttl)

  def setup_brain_packs(conn) do
    case active_payload(get_session(conn, :setup_brain_packs)) do
      %{"packs" => packs} when is_list(packs) -> packs
      _ -> []
    end
  end

  def put_setup_oidc_state(conn, attrs),
    do: put_expiring_session(conn, :setup_oidc_state, attrs, @state_ttl)

  def setup_oidc_state(conn), do: active_payload(get_session(conn, :setup_oidc_state))

  def opaque_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  def safe_return_to(value) when is_binary(value) do
    if String.starts_with?(value, "/") and not String.starts_with?(value, ["//", "/\\"]),
      do: value,
      else: "/"
  end

  def safe_return_to(_), do: "/"

  defp put_expiring_session(conn, key, attrs, ttl) do
    now = System.system_time(:second)

    put_session(
      conn,
      key,
      attrs |> stringify_keys() |> Map.merge(%{"issued_at" => now, "expires_at" => now + ttl})
    )
  end

  defp active_payload(%{"expires_at" => expiry} = payload) when is_integer(expiry) do
    if expiry > System.system_time(:second), do: payload
  end

  defp active_payload(_), do: nil
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
