defmodule AnkoleWeb.SessionCookies do
  @moduledoc "Cookie transport for the site's shared browser authentication collection."
  @behaviour Plug
  @secure Application.compile_env(:ankole, :secure_cookies, false)
  @host_policy Application.compile_env(:ankole, :host_policy)

  def authentication_prefix, do: if(@secure, do: "__Secure-ankole-auth-", else: "_ankole-auth-")

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
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end
end
