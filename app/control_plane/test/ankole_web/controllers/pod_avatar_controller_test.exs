defmodule AnkoleWeb.PodAvatarControllerTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  import AnkoleWeb.PodAPI, only: [api_get: 2, api_response: 2]
  alias Ankole.{BrowserSessions, Principals, PrincipalsFixtures}
  alias AnkoleWeb.Session, as: WebSession

  @png_signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  defp png_bytes(total_size) do
    @png_signature <> :crypto.strong_rand_bytes(total_size - byte_size(@png_signature))
  end

  defp upload(name, bytes, content_type \\ "image/png") do
    path = Path.join(System.tmp_dir!(), "#{name}-#{Ecto.UUID.generate()}.png")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: "#{name}.png", content_type: content_type}
  end

  test "a member uploads and replaces a profile picture across profile, session, and download responses",
       %{
         conn: conn
       } do
    {conn, uid} = console_conn_with_principal(conn)
    first_bytes = png_bytes(64)
    second_bytes = png_bytes(72)

    created = post(conn, "/api/v2/pod/me/avatar", %{file: upload("first-avatar", first_bytes)})
    assert %{"avatarURL" => first_url} = json_response(created, 200)
    assert first_url =~ "/api/v2/pod/avatars/#{URI.encode_www_form("member:#{uid}")}?v="

    profile = created |> api_get("/api/v2/pod/me")
    assert api_response(profile, 200)["avatarURL"] == first_url

    session = profile |> api_get("/api/v2/browser/session")
    assert api_response(session, 200)["avatarURL"] == first_url
    assert {:ok, first_avatar} = Principals.fetch_avatar("member:#{uid}")

    reference = WebSession.authentication_reference(created)

    image_url =
      first_url <> "&authentication_ref=" <> BrowserSessions.encode_reference(reference)

    downloaded = created |> recycle() |> get(image_url)
    assert response(downloaded, 200) == first_bytes
    assert get_resp_header(downloaded, "content-type") == ["image/png; charset=utf-8"]

    replaced =
      created
      |> recycle_api()
      |> post("/api/v2/pod/me/avatar", %{file: upload("second-avatar", second_bytes)})

    assert %{"avatarURL" => second_url} = json_response(replaced, 200)
    assert second_url != first_url
    assert {:ok, second_avatar} = Principals.fetch_avatar("member:#{uid}")
    assert second_avatar.object_id != first_avatar.object_id

    latest = replaced |> recycle_api() |> get(second_url)
    assert response(latest, 200) == second_bytes
  end

  test "an administrator uploads a space picture returned by settings and the browser session", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)
    bytes = png_bytes(80)

    created =
      post(conn, "/api/v2/pod/admin/settings/avatar", %{file: upload("space-avatar", bytes)})

    assert %{"avatarURL" => url} = json_response(created, 200)
    assert url =~ "/api/v2/pod/avatars/space?v="

    settings = created |> api_get("/api/v2/pod/admin/settings")
    assert api_response(settings, 200)["avatarURL"] == url

    session = settings |> api_get("/api/v2/browser/session")
    assert api_response(session, 200)["tenant"]["avatarURL"] == url

    downloaded = created |> recycle() |> get(url)
    assert response(downloaded, 200) == bytes
  end

  test "rejects invalid and oversized pictures and forbids space changes by ordinary members", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)

    invalid =
      post(conn, "/api/v2/pod/me/avatar", %{
        file: upload("not-an-image", "not a picture")
      })

    assert %{"error" => %{"code" => "invalid_file_type"}} = json_response(invalid, 422)

    spoofed =
      invalid
      |> recycle_api()
      |> post("/api/v2/pod/me/avatar", %{
        file: upload("spoofed-image", "not a picture", "image/png")
      })

    assert %{"error" => %{"code" => "invalid_file_type"}} = json_response(spoofed, 422)

    oversized =
      spoofed
      |> recycle_api()
      |> post("/api/v2/pod/me/avatar", %{
        file: upload("large-avatar", png_bytes(5 * 1024 * 1024 + 1))
      })

    assert %{"error" => %{"code" => "file_too_large"}} = json_response(oversized, 413)

    member = PrincipalsFixtures.human_fixture(%{display_name: "Ordinary Member"}).principal
    member_session = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, %{browser: browser, authentication: authentication}} =
      BrowserSessions.authenticate(WebSession.browser_reference(member_session), %{
        "principal_uid" => member.uid,
        "access_version" => member.access_version,
        "provider_id" => "lark-main",
        "external_id" => "ordinary-member"
      })

    forbidden =
      member_session
      |> WebSession.put_authentication(browser, authentication)
      |> with_console_csrf()
      |> get("/api/v2/browser/session")
      |> recycle_api()
      |> post("/api/v2/pod/admin/settings/avatar", %{
        file: upload("forbidden-avatar", png_bytes(64))
      })

    assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)
  end

  test "a multi-space browser downloads each Space avatar from its own Pod origin and authentication_ref",
       %{conn: conn, tenant: tenant_a} do
    tenant_b = Ankole.DataCase.create_tenant()
    bytes_a = png_bytes(68)
    bytes_b = png_bytes(84)

    admin_a =
      Ankole.Repo.with_tenant(tenant_a.id, fn ->
        {:ok, true} =
          Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

        human = PrincipalsFixtures.human_fixture(%{display_name: "Admin A"}).principal
        {:ok, _} = Ankole.Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(human.uid) end)
        human
      end)

    admin_b =
      Ankole.Repo.with_tenant(tenant_b.id, fn ->
        human = PrincipalsFixtures.human_fixture(%{display_name: "Admin B"}).principal
        {:ok, _} = Ankole.Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(human.uid) end)
        human
      end)

    shared = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, %{browser: browser, authentication: auth_a}} =
      Ankole.Repo.with_tenant(tenant_a.id, fn ->
        BrowserSessions.authenticate(WebSession.browser_reference(shared), %{
          "principal_uid" => admin_a.uid,
          "access_version" => admin_a.access_version,
          "provider_id" => "lark-main",
          "external_id" => "admin-a"
        })
      end)

    conn_a =
      shared
      |> pod_conn(tenant_a)
      |> WebSession.put_authentication(browser, auth_a)
      |> with_console_csrf()
      |> get("/api/v2/browser/session")
      |> recycle_api()
      |> post("/api/v2/pod/admin/settings/avatar", %{file: upload("space-a", bytes_a)})

    assert %{"avatarURL" => url_a} = json_response(conn_a, 200)
    ref_a = conn_a |> WebSession.authentication_reference() |> BrowserSessions.encode_reference()

    {:ok, %{browser: browser, authentication: auth_b}} =
      Ankole.Repo.with_tenant(tenant_b.id, fn ->
        BrowserSessions.authenticate(WebSession.browser_reference(conn_a), %{
          "principal_uid" => admin_b.uid,
          "access_version" => admin_b.access_version,
          "provider_id" => "lark-main",
          "external_id" => "admin-b"
        })
      end)

    conn_b =
      conn_a
      |> recycle()
      |> pod_conn(tenant_b)
      |> Plug.Test.init_test_session(Plug.Conn.get_session(conn_a))
      |> WebSession.put_authentication(browser, auth_b)
      |> with_console_csrf()
      |> get("/api/v2/browser/session")
      |> recycle_api()
      |> post("/api/v2/pod/admin/settings/avatar", %{file: upload("space-b", bytes_b)})

    assert %{"avatarURL" => url_b} = json_response(conn_b, 200)
    ref_b = conn_b |> WebSession.authentication_reference() |> BrowserSessions.encode_reference()

    # While Space B is the active browser session, Space A's avatar loads cleanly from Space A's origin + ref_a
    fetched_a =
      conn_b
      |> recycle()
      |> pod_conn(tenant_a)
      |> get(url_a <> "&authentication_ref=" <> ref_a)

    assert response(fetched_a, 200) == bytes_a

    fetched_b =
      conn_b
      |> recycle()
      |> pod_conn(tenant_b)
      |> get(url_b <> "&authentication_ref=" <> ref_b)

    assert response(fetched_b, 200) == bytes_b

    # Without Space A's origin, requesting url_a on Space B's host does not resolve Space A's avatar
    wrong_origin =
      conn_b
      |> recycle()
      |> pod_conn(tenant_b)
      |> get(url_a)

    refute wrong_origin.status == 200 and wrong_origin.resp_body == bytes_a
  end
end
