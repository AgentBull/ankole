defmodule AnkoleWeb.Session do
  @moduledoc "Browser grouping, independent authentication cookies, and isolated setup state."
  import Plug.Conn
  alias Ankole.BrowserSessions
  alias Ankole.Principals.HumanAccess
  alias Ankole.AuthZ
  alias AnkoleWeb.SessionCookieStore

  @browser_key :browser_session
  @setup_ttl 24 * 60 * 60
  @state_ttl 10 * 60
  @secure Application.compile_env(:ankole, :secure_cookies, false)
  @authentication_prefix if(@secure, do: "__Host-ankole-auth-", else: "_ankole-auth-")

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

  def begin_login(conn, purpose, request, opts \\ []) do
    conn = ensure_browser(conn)

    with {:ok, transaction} <-
           BrowserSessions.begin_login(
             browser_reference(conn),
             purpose,
             request,
             Keyword.put_new(opts, :mode, Map.get(conn.assigns, :browser_login_mode, :replace))
           ),
         do: {:ok, conn, transaction}
  end

  def login_transaction(conn, id), do: BrowserSessions.login(browser_reference(conn), id)

  def put_privileged_tenant do
    with {:ok, tenant} <- Ankole.Tenants.privileged(), do: Ankole.Repo.put_tenant_id(tenant.id)
  end

  def complete_login(conn, id, auth, before_commit \\ fn -> :ok end) do
    with {:ok, %{browser: browser, transaction: transaction, authentication: authentication}} <-
           BrowserSessions.complete_login(browser_reference(conn), id, auth, before_commit) do
      {:ok, put_authentication(conn, browser, authentication), transaction}
    end
  end

  def complete_site_login(conn, id, provider_id, proof) do
    with {:ok, %{browser: browser, transaction: transaction, authentication: authentication}} <-
           BrowserSessions.complete_site_login(browser_reference(conn), id, provider_id, proof) do
      {:ok, put_authentication(conn, browser, authentication), transaction}
    end
  end

  defp put_authentication(conn, browser, authentication) do
    reference = BrowserSessions.reference(authentication)
    name = @authentication_prefix <> authentication.id
    value = SessionCookieStore.put(cookie_conn(conn), nil, reference, cookie_options())

    conn
    |> put_session(@browser_key, BrowserSessions.reference(browser))
    |> put_resp_cookie(name, value,
      secure: @secure,
      http_only: true,
      same_site: "Lax",
      path: "/",
      max_age: max(DateTime.diff(authentication.expires_at, DateTime.utc_now()), 0)
    )
    |> put_private(:browser_authentication_ref, reference)
    |> put_private(
      :browser_authentication_proofs,
      [reference | conn.private[:browser_authentication_proofs] || []]
    )
  end

  @doc "Opens the Console context after setup verifies its first administrator."
  def put_admin_session(conn, attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, version} <- HumanAccess.current_version(attrs["principal_uid"]),
         {:ok, conn, transaction} <- begin_login(conn, :console, %{}),
         {:ok, _} <-
           BrowserSessions.bind_provider(
             browser_reference(conn),
             transaction.id,
             attrs["provider_id"]
           ),
         {:ok, conn, _} <-
           complete_login(conn, transaction.id, Map.put(attrs, "access_version", version)) do
      conn
    else
      {:error, reason} -> raise "Cannot establish setup authentication: #{inspect(reason)}"
    end
  end

  def authentication_references(conn) do
    conn = fetch_cookies(conn)

    cookie_refs =
      Enum.flat_map(conn.req_cookies, fn {name, value} ->
        if String.starts_with?(name, @authentication_prefix) do
          {_sid, reference} = SessionCookieStore.get(cookie_conn(conn), value, cookie_options())

          if reference["id"] == String.replace_prefix(name, @authentication_prefix, ""),
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
    candidate =
      case get_req_header(conn, "x-ankole-authentication") do
        [] ->
          conn.private[:browser_authentication_ref] || parameter_reference(conn) ||
            BrowserSessions.current_reference(browser_reference(conn))

        [value] ->
          decode_reference(value)

        _ ->
          :invalid
      end

    if authentication_proven?(conn, candidate), do: candidate
  end

  def authentication_proven?(conn, %{"id" => id} = reference) when is_binary(id) do
    conn = fetch_cookies(conn)
    name = @authentication_prefix <> id

    {_sid, cookie_ref} =
      SessionCookieStore.get(cookie_conn(conn), conn.req_cookies[name], cookie_options())

    with true <-
           cookie_ref == reference or
             reference in (conn.private[:browser_authentication_proofs] || []),
         %{"id" => browser_id} <- browser_reference(conn),
         {:ok, %{browser_id: ^browser_id}} <- BrowserSessions.get_authentication(reference) do
      true
    else
      _ -> false
    end
  end

  def authentication_proven?(_, _), do: false

  # EventSource cannot send the page's authentication header. Navigation URLs
  # must not select a different signed-in identity.
  defp parameter_reference(
         %{method: "GET", path_info: [".internal-apis", "pod", "conversations", _id, "events"]} =
           conn
       ) do
    case param(conn, "authentication_ref") do
      nil -> nil
      value -> decode_reference(value)
    end
  end

  defp parameter_reference(%{path_info: [prefix | _]} = conn)
       when prefix in [".internal-apis", "api"] do
    if param(conn, "authentication_ref"), do: :invalid
  end

  defp parameter_reference(_conn), do: nil

  defp decode_reference(value) do
    case BrowserSessions.decode_reference(value) do
      {:ok, ref} -> ref
      _ -> :invalid
    end
  end

  def transaction_reference(conn, transaction) do
    ref = %{
      "id" => transaction.authentication_id,
      "revision" => transaction.authentication_revision
    }

    if authentication_proven?(conn, ref), do: ref
  end

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

  def admin_session(conn),
    do: BrowserSessions.authentication(authentication_reference(conn), :console)

  def site_admin_session(conn) do
    case admin_session(conn) do
      %{"principal_uid" => uid} = authentication -> if AuthZ.site_admin?(uid), do: authentication
      _ -> nil
    end
  end

  def oauth_session(conn),
    do: BrowserSessions.authentication(authentication_reference(conn), :oauth)

  def pod_session(conn), do: BrowserSessions.authentication(authentication_reference(conn), :pod)

  def csrf_state(conn) do
    flow = param(conn, "flow")

    case if(is_binary(flow), do: BrowserSessions.transaction_csrf(browser_reference(conn), flow)) do
      state when is_binary(state) ->
        state

      _ ->
        case BrowserSessions.get_authentication(authentication_reference(conn)) do
          {:ok, authentication} -> authentication.csrf_token
          _ -> nil
        end
    end
  end

  def param(conn, key) do
    params = if is_map(conn.params), do: conn.params, else: %{}
    body = if is_map(conn.body_params), do: conn.body_params, else: %{}
    query = fetch_query_params(conn).query_params
    Map.get(params, key) || Map.get(body, key) || Map.get(query, key)
  end

  def revoke_authentication(conn) do
    with ref when is_map(ref) <- authentication_reference(conn),
         {:ok, _} <- BrowserSessions.revoke(browser_reference(conn), ref) do
      {:ok,
       conn
       |> delete_resp_cookie(@authentication_prefix <> ref["id"], secure: @secure, path: "/")
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
        if String.starts_with?(name, @authentication_prefix),
          do: delete_resp_cookie(acc, name, secure: @secure, path: "/"),
          else: acc
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
  def clear_setup_oidc_state(conn), do: delete_session(conn, :setup_oidc_state)

  def opaque_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  def safe_return_to(value) when is_binary(value) do
    if String.starts_with?(value, "/") and not String.starts_with?(value, ["//", "/\\"]),
      do: value,
      else: "/pod"
  end

  def safe_return_to(_), do: "/pod"

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
