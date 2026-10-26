defmodule AnkoleWeb.SessionCookies do
  @moduledoc "Cookie transport for the site's shared browser authentication collection."
  @behaviour Plug
  @secure Application.compile_env(:ankole, :secure_cookies, false)
  @host_policy Application.compile_env(:ankole, :host_policy)

  def authentication_prefix, do: if(@secure, do: "__Secure-ankole-auth-", else: "_ankole-auth-")
  def authentication_prefixes, do: [authentication_prefix(), "__Host-ankole-auth-"]

  def options do
    options = [path: "/", same_site: "Lax", http_only: true, secure: @secure]
    if domain = domain(), do: Keyword.put(options, :domain, domain), else: options
  end

  def delete_options, do: Keyword.take(options(), [:domain, :path, :secure, :same_site])

  def session_options do
    Keyword.merge(options(),
      store: AnkoleWeb.SessionCookieStore,
      key: if(@secure, do: "__Secure-ankole", else: "_ankole_key"),
      key_context: "_ankole_key",
      max_age: 86_400
    )
  end

  def domain do
    host =
      if @host_policy,
        do: apply(@host_policy, :domain, []),
        else: AnkoleWeb.Endpoint.config(:url)[:host]

    # A public suffix or IP cannot carry a domain cookie. Local development
    # needs a registrable parent such as ankole.localhost to share logins.
    if is_binary(host) and host != "localhost" and
         match?({:error, _}, :inet.parse_address(String.to_charlist(host))),
       do: host
  end

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    conn = Plug.Conn.fetch_cookies(conn)
    key = session_options()[:key]
    legacy = conn.req_cookies["__Host-ankole"]

    {conn, migrated?} =
      if is_nil(conn.req_cookies[key]) and is_binary(legacy) and valid_group?(conn, legacy) do
        {%{
           conn
           | cookies: Map.put(conn.cookies, key, legacy),
             req_cookies: Map.put(conn.req_cookies, key, legacy)
         }, true}
      else
        {conn, false}
      end

    conn = Plug.Session.call(conn, Plug.Session.init(session_options()))

    if migrated? or is_binary(legacy) or
         Enum.any?(Map.keys(conn.req_cookies), &String.starts_with?(&1, "__Host-ankole-auth-")) do
      conn = Plug.Conn.fetch_session(conn)
      conn = if migrated?, do: Plug.Conn.configure_session(conn, renew: true), else: conn

      conn
      |> Plug.Conn.delete_resp_cookie("__Host-ankole", secure: true, path: "/")
      |> AnkoleWeb.Session.migrate_legacy_authentications()
      |> clear_legacy_proofs()
    else
      conn
    end
  end

  defp clear_legacy_proofs(conn) do
    Enum.reduce(conn.req_cookies, conn, fn {name, _}, conn ->
      if String.starts_with?(name, "__Host-ankole-auth-"),
        do: Plug.Conn.delete_resp_cookie(conn, name, secure: true, path: "/"),
        else: conn
    end)
  end

  defp valid_group?(conn, raw) do
    {_, payload} =
      AnkoleWeb.SessionCookieStore.get(
        conn,
        raw,
        AnkoleWeb.SessionCookieStore.init(key_context: "_ankole_key", log: false)
      )

    reference = Ankole.Attrs.get(payload, :browser_session)
    match?({:ok, _}, Ankole.BrowserSessions.get(reference))
  end
end
