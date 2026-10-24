defmodule Ankole.E2E.PodContentBrowserTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI

  alias Ankole.E2E.PodContentBrowser
  alias Ankole.Principals

  test "the story browser receives a real email proof for its registered Human", ctx do
    assert {:ok, true} =
             Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    email = "pod-story-#{System.unique_integer([:positive])}@example.org"

    assert {:ok, %{principal: human}} =
             Principals.create_human(%{display_name: "Story owner", email: email})

    assert Principals.principal_site_credentials(human.uid) == []
    origin = AnkoleWeb.PodURL.origin(ctx.conn, ctx.tenant)
    cookies = PodContentBrowser.browser_cookies!(human, origin)

    assert [%{provider: "email_otp", identifier: ^email}] =
             Principals.principal_site_credentials(human.uid)

    # Each story step opens a browser process with this same verified session.
    assert PodContentBrowser.browser_cookies!(human, origin) == cookies
    refute_receive {:smtp_message, _, _, _}

    browser =
      Enum.reduce(cookies, build_conn(), fn cookie, conn ->
        put_req_cookie(conn, cookie.name, cookie.value)
      end)

    rendered = get(browser, origin <> "/")
    html = html_response(rendered, 200)
    assert html =~ ~s(name="ankole-pod" content="#{ctx.tenant.id}")

    [_, authentication] =
      Regex.run(~r/<meta name="ankole-authentication" content="([^"]+)"/, html)

    me =
      rendered
      |> recycle()
      |> put_req_header("x-ankole-authentication", authentication)
      |> api_get("/api/v2/pod/me")

    assert %{
             "displayName" => "Story owner",
             "credentials" => [%{"provider" => "email_otp", "identifier" => ^email}]
           } = api_response(me, 200)

    assert %{"principal_uid" => uid, "tenant_id" => tenant_id} =
             AnkoleWeb.Session.pod_session(me)

    assert uid == human.uid
    assert tenant_id == ctx.tenant.id
  end
end
