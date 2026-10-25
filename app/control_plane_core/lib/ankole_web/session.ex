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

  def begin_login(conn, purpose, request, opts \\ []) do
    conn = ensure_browser(conn)

    with {:ok, transaction} <-
           BrowserSessions.begin_login(
             browser_reference(conn),
             purpose,
             request,
             Keyword.put_new(
               opts,
               :mode,
               Map.get(
                 conn.assigns,
                 :browser_login_mode,
                 if(purpose == :pod, do: :add, else: :replace)
               )
             )
           ),
         do: {:ok, conn, transaction}
  end

  def login_transaction(conn, id) do
    with {:ok, transaction} <- BrowserSessions.login(browser_reference(conn), id) do
      case conn.assigns[:host_context] do
        {:pod, tenant_id} when transaction.tenant_id != tenant_id -> {:error, :login_expired}
        _ -> {:ok, transaction}
      end
    end
  end

  def put_privileged_tenant do
    with {:ok, tenant} <- Ankole.Tenants.privileged(), do: Ankole.Repo.put_tenant_id(tenant.id)
  end

  def complete_login(conn, id, auth, before_commit \\ fn -> :ok end) do
    with {:ok, %{browser: browser, transaction: transaction, authentication: authentication}} <-
           BrowserSessions.complete_login(browser_reference(conn), id, auth, before_commit) do
      {:ok, put_authentication(conn, browser, authentication), transaction}
    end
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

    cookie_refs =
      Enum.flat_map(conn.req_cookies, fn {name, value} ->
        if prefix =
             Enum.find(SessionCookies.authentication_prefixes(), &String.starts_with?(name, &1)) do
          {_sid, reference} = SessionCookieStore.get(cookie_conn(conn), value, cookie_options())

          if reference["id"] ==
               String.replace_prefix(name, prefix, ""),
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
    raw = Enum.find_value(SessionCookies.authentication_prefixes(), &conn.req_cookies[&1 <> id])

    {_sid, cookie_ref} =
      SessionCookieStore.get(cookie_conn(conn), raw, cookie_options())

    cookie_ref == reference or reference in (conn.private[:browser_authentication_proofs] || [])
  end

  defp authentication_cookie_proven?(_, _), do: false

  @doc "Copies only verified legacy proofs into shared cookies without changing the active identity."
  def migrate_legacy_authentications(conn) do
    Enum.reduce(authentication_references(conn), conn, fn reference, conn ->
      name = "__Host-ankole-auth-" <> reference["id"]

      if conn.req_cookies[name] do
        case BrowserSessions.get_authentication(reference) do
          {:ok, authentication} -> put_authentication_cookie(conn, authentication)
          _ -> conn
        end
      else
        conn
      end
    end)
  end

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
    # Setup owns its activation session and keeps that form's browser CSRF
    # state while its internal login transaction verifies the first operator.
    flow =
      if String.starts_with?(conn.request_path, "/api/v2/browser/setup/"),
        do: nil,
        else: param(conn, "flow")

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
       |> delete_resp_cookie("__Host-ankole-auth-" <> ref["id"], secure: true, path: "/")
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
        cond do
          String.starts_with?(name, SessionCookies.authentication_prefix()) ->
            delete_resp_cookie(acc, name, SessionCookies.delete_options())

          String.starts_with?(name, "__Host-ankole-auth-") ->
            delete_resp_cookie(acc, name, secure: true, path: "/")

          true ->
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
