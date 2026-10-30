defmodule AnkoleWeb.SessionCookieStoreTest do
  # This module exercises the site-wide privileged-tenant setting.
  use Ankole.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Ankole.Kernel, as: NativeKernel
  alias AnkoleWeb.Session, as: WebSession

  @cookie_key "_ankole_test_session"
  @session_opts Plug.Session.init(
                  store: AnkoleWeb.SessionCookieStore,
                  key: @cookie_key,
                  key_context: @cookie_key,
                  log: false
                )

  test "stores session data in a kernel-aead encrypted cookie" do
    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> Plug.Session.call(@session_opts)
      |> fetch_session()
      |> put_session(:setup_secret_plaintext, "setup-secret")
      |> send_resp(200, "ok")

    cookie = conn |> get_resp_header("set-cookie") |> List.first()
    assert is_binary(cookie)
    refute cookie =~ "setup-secret"

    cookie_value = cookie_value(cookie)

    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> put_req_header("cookie", "#{@cookie_key}=#{cookie_value}")
      |> Plug.Session.call(@session_opts)
      |> fetch_session()

    assert get_session(conn, :setup_secret_plaintext) == "setup-secret"
  end

  test "the group cookie needs an independent proof cookie to authenticate", %{tenant: tenant} do
    :ok = set_privileged_tenant(tenant)
    human = Ankole.PrincipalsFixtures.human_fixture()
    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(human.principal.uid)

    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> Plug.Session.call(@session_opts)
      |> fetch_session()
      |> WebSession.put_tenant_session(%{
        principal_uid: human.principal.uid,
        provider_id: "oidc-main",
        external_id: "external-123"
      })
      |> send_resp(200, "ok")

    cookies = get_resp_header(conn, "set-cookie")
    assert length(cookies) == 2

    for cookie <- cookies do
      refute cookie =~ human.principal.uid
      refute cookie =~ "oidc-main"
      refute cookie =~ "external-123"
    end

    group_cookie = Enum.find(cookies, &String.starts_with?(&1, @cookie_key <> "="))
    cookie_value = cookie_value(group_cookie)

    group_only =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> put_req_header("cookie", "#{@cookie_key}=#{cookie_value}")
      |> Plug.Session.call(@session_opts)
      |> fetch_session()

    assert %{"id" => browser_id} = get_session(group_only, :browser_session)
    assert is_binary(browser_id)
    assert map_size(get_session(group_only, :browser_session)) == 1
    refute WebSession.site_admin_session(group_only)

    cookie_header = Enum.map_join(cookies, "; ", &(&1 |> String.split(";", parts: 2) |> hd()))

    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> put_req_header("cookie", cookie_header)
      |> Plug.Session.call(@session_opts)
      |> fetch_session()

    uid = human.principal.uid

    assert %{
             "principal_uid" => ^uid,
             "provider_id" => "oidc-main",
             "external_id" => "external-123"
           } = WebSession.site_admin_session(conn)
  end

  test "ignores malformed cookies" do
    conn =
      :get
      |> conn("/")
      |> with_secret_key_base()
      |> put_req_header("cookie", "#{@cookie_key}=not-an-ankole-session")
      |> Plug.Session.call(@session_opts)
      |> fetch_session()

    assert get_session(conn) == %{}
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: secret_key_base()}
  end

  defp secret_key_base do
    case NativeKernel.derive_key(String.duplicate("a", 64), "session_cookie_store_test") do
      key when is_binary(key) -> key
      {:error, reason} -> raise "could not derive test secret key base: #{inspect(reason)}"
    end
  end

  defp cookie_value(cookie) do
    [[_, value]] = Regex.scan(~r/#{@cookie_key}=([^;]+)/, cookie)
    value
  end
end
