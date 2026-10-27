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

  @doc "Opens the Console context after setup verifies its first administrator."
  def put_admin_session(conn, attrs) do
    attrs = stringify_keys(attrs)
    conn = ensure_browser(conn)

    with {:ok, version} <- HumanAccess.current_version(attrs["principal_uid"]),
         {:ok, %{browser: browser, authentication: authentication}} <-
           BrowserSessions.authenticate(
             browser_reference(conn),
             :console,
             Map.put(attrs, "access_version", version)
           ) do
      put_authentication(conn, browser, authentication)
    else
      {:error, reason} -> raise "Cannot establish setup authentication: #{inspect(reason)}"
    end
  end

  @doc "Writes the verified site proof that completed first-administrator setup."
  def put_site_admin_session(
        conn,
        %BrowserSessions.Session{} = browser,
        %BrowserSessions.Authentication{purpose: :site, console_authenticated: true} =
          authentication
      ),
      do: put_authentication(conn, browser, authentication)

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

  def authentication_reference(conn) do
    candidate = authentication_candidate(conn)
    if authentication_proven?(conn, candidate), do: candidate
  end

  def invalid_authentication_selection?(conn), do: authentication_candidate(conn) == :invalid

  defp authentication_candidate(conn) do
    case get_req_header(conn, "x-ankole-authentication") do
      [] ->
        conn.private[:browser_authentication_ref] || parameter_reference(conn) ||
          BrowserSessions.current_reference(browser_reference(conn))

      [value] ->
        decode_reference(value)

      _ ->
        :invalid
    end
  end

  def authentication_proven?(conn, reference) do
    with true <- authentication_cookie_proven?(conn, reference),
         %{"id" => browser_id} <- browser_reference(conn),
         {:ok, %{browser_id: ^browser_id}} <- BrowserSessions.get_authentication(reference),
         do: true,
         else: (_ -> false)
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

  def current_authentication(conn) do
    with ref when is_map(ref) <- authentication_reference(conn),
         {:ok, authentication} <- BrowserSessions.get_authentication(ref),
         tenant_id when is_binary(tenant_id) <-
           selected_tenant(conn, authentication),
         do: BrowserSessions.identity(ref, tenant_id),
         else: (_ -> nil)
  end

  defp selected_tenant(conn, authentication) do
    case get_req_header(conn, "x-ankole-pod") do
      [id] ->
        case Ecto.UUID.cast(id) do
          {:ok, id} ->
            if Ankole.Repo.tenant_id() in [nil, id], do: id

          _ ->
            nil
        end

      [] ->
        Ankole.Repo.tenant_id() || authentication.tenant_id ||
          case BrowserSessions.get(browser_reference(conn)) do
            {:ok, browser} -> browser.active_tenant_id
            _ -> nil
          end

      _ ->
        nil
    end
  end

  def admin_session(conn), do: browser_authentication(conn, :console)

  def site_admin_session(conn) do
    case admin_session(conn) do
      %{"principal_uid" => uid} = authentication -> if AuthZ.site_admin?(uid), do: authentication
      _ -> nil
    end
  end

  def oauth_session(conn), do: browser_authentication(conn, :oauth)

  def pod_session(conn), do: browser_authentication(conn, :pod)

  defp browser_authentication(conn, purpose) do
    reference = authentication_candidate(conn)

    with true <- authentication_cookie_proven?(conn, reference),
         %{"id" => browser_id} <- browser_reference(conn),
         %{"browser_id" => ^browser_id} = identity <-
           BrowserSessions.authentication(reference, purpose),
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
    case BrowserSessions.get_authentication(authentication_reference(conn)) do
      {:ok, authentication} -> authentication.csrf_token
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
      "/sessions/logout-error",
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
         {:ok, _} <- BrowserSessions.revoke(browser_reference(conn), ref) do
      {:ok,
       conn
       |> delete_resp_cookie(
         SessionCookies.authentication_prefix() <> ref["id"],
         SessionCookies.delete_options()
       )
       |> put_private(:browser_authentication_ref, nil)
       |> put_private(
         :browser_authentication_proofs,
         Enum.reject(conn.private[:browser_authentication_proofs] || [], &(&1 == ref))
       )}
    else
      _ -> {:error, :browser_session_expired}
    end
  end

  def logout(conn) do
    case BrowserSessions.logout(browser_reference(conn)) do
      {:ok, _} -> {:ok, clear_authentication_cookies(conn)}
      error -> error
    end
  end

  def clear_admin_session(conn) do
    case logout(conn) do
      {:ok, conn} -> conn
      {:error, :browser_session_expired} -> clear_authentication_cookies(conn)
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
