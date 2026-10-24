defmodule Ankole.E2E.PodContentBrowser do
  @moduledoc "Authenticated browser actions for real-model Pod user stories."

  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Plug.Conn
  import Phoenix.ConnTest, only: [dispatch: 5, html_response: 2, redirected_to: 1]
  import AnkoleWeb.PodAPI, only: [api_post: 3, api_response: 2]
  alias Ankole.Repo
  alias AnkoleWeb.Session, as: WebSession

  def send_message!(ctx, uid, options) do
    run!(ctx, uid, Map.new(options) |> Map.put(:action, "send_message"))
  end

  def report!(ctx, uid, conversation_id, report_id, applet_id, mode) do
    run!(ctx, uid, %{
      action: "report",
      conversation_id: conversation_id,
      report_id: report_id,
      applet_id: applet_id,
      add_sale: mode == :add
    })
  end

  def counter!(ctx, uid, conversation_id, applet_id) do
    run!(ctx, uid, %{action: "counter", conversation_id: conversation_id, applet_id: applet_id})
  end

  def inventory!(ctx, uid, conversation_id, report_id, applet_id, mode) do
    run!(ctx, uid, %{
      action: "inventory",
      conversation_id: conversation_id,
      report_id: report_id,
      applet_id: applet_id,
      reserve: mode == :reserve
    })
  end

  def moved_page!(ctx, uid, parent, child, marker) do
    run!(ctx, uid, %{
      action: "moved_page",
      parent_id: parent.id,
      parent_title: parent.title,
      child_id: child.id,
      child_title: child.title,
      marker: marker
    })
  end

  def document!(ctx, uid, conversation_id, page, facts) do
    run!(ctx, uid, %{
      action: "document",
      conversation_id: conversation_id,
      report_id: page.id,
      title: page.title,
      facts: facts,
      edit_marker: "Human review " <> Ecto.UUID.generate()
    })
  end

  defp run!(ctx, uid, action) do
    assets = Application.fetch_env!(:ankole, AnkoleWeb.Assets)
    Application.put_env(:ankole, AnkoleWeb.Assets, dev_server: nil)
    on_exit(fn -> Application.put_env(:ankole, AnkoleWeb.Assets, assets) end)

    assert {:ok, _} =
             Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    {:ok, human} = Ankole.Principals.get_principal(uid)
    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: ctx.server_port}, tenant)
    state_path = Path.join(System.tmp_dir!(), "ankole-pod-story-#{Ecto.UUID.generate()}.json")

    state =
      Map.merge(action, %{
        base_url: origin,
        tenant_id: Repo.tenant_id!(),
        cookies: browser_cookies!(human, origin)
      })

    File.write!(state_path, Torque.encode!(state))
    File.chmod!(state_path, 0o600)

    try do
      script = File.read!(Path.join(__DIR__, "pod_content_browser.mjs"))

      {output, status} =
        System.cmd("bun", ["--eval", script, state_path],
          cd: Path.expand("../../../app/webapps", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 0, output
      IO.write(output)

      line =
        output
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "Pod browser result: "))

      assert line, "Browser did not report its observed result"
      line |> String.replace_prefix("Pod browser result: ", "") |> Torque.decode!()
    after
      File.rm(state_path)
    end
  end

  @doc false
  def browser_cookies!(human, origin) do
    key = {__MODULE__, :cookies, human.uid, origin}

    case Process.get(key) do
      nil ->
        cookies = login_cookies!(human, origin)
        Process.put(key, cookies)
        cookies

      cookies ->
        cookies
    end
  end

  defp login_cookies!(human, origin) do
    {:ok, %{human_user: %{email: email}}} =
      Ankole.Principals.get_principal_record(human.uid, load: [:human_user])

    assert is_binary(email), "The E2E Human must have a registered contact email"
    smtp = Ankole.Authn.SMTPFixture.start(self())
    {:ok, previous_mail} = Ankole.Authn.Config.get("mail")

    on_exit(fn ->
      Ankole.Authn.SMTPFixture.stop(smtp)
      assert {:ok, _} = Ankole.Authn.Config.put_mail(previous_mail)
    end)

    assert {:ok, _} =
             Ankole.Authn.Config.put_mail(%{
               "server" => "127.0.0.1",
               "port" => smtp.port,
               "ssl" => true,
               "from" => "login@ankole.test",
               "cacertfile" => smtp.ca_path
             })

    conn =
      Phoenix.ConnTest.build_conn()
      |> dispatch(AnkoleWeb.Endpoint, :get, origin <> "/sessions/new", nil)

    reference = WebSession.browser_reference(conn)

    on_exit(
      Repo.bind_tenant(fn ->
        assert {:ok, _} = Ankole.BrowserSessions.logout(reference)
        assert {:ok, browser} = Ankole.BrowserSessions.get(reference)
        Repo.delete!(browser)
      end)
    )

    login = redirected_to(conn)
    flow = login |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("flow")

    shell =
      conn
      |> AnkoleWeb.ConnCase.recycle()
      |> dispatch(AnkoleWeb.Endpoint, :get, URI.merge(origin, login) |> URI.to_string(), nil)

    [_, csrf] =
      Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(shell, 200))

    sent =
      shell
      |> AnkoleWeb.ConnCase.recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("origin", origin)
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/browser/sessions/email-otp/challenges", %{flow: flow, email: email})

    challenge = api_response(sent, 201)["challengeID"]
    assert_receive {:smtp_message, _, [^email], message}, 5_000
    [_, code] = Regex.run(~r/code is (\d{6})/, Ankole.Authn.SMTPFixture.text(message))

    verified =
      sent
      |> AnkoleWeb.ConnCase.recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> put_req_header("origin", origin)
      |> put_req_header("x-csrf-token", csrf)
      |> api_post("/api/v2/browser/sessions/email-otp/verifications", %{
        flow: flow,
        challengeID: challenge,
        code: code
      })

    assert %{"status" => "ok"} = api_response(verified, 201)
    assert %{"principal_uid" => uid} = WebSession.pod_session(verified)
    assert uid == human.uid

    cookies =
      Map.merge(
        verified.req_cookies,
        Map.new(verified.resp_cookies, fn {k, v} -> {k, v.value} end)
      )

    Enum.map(cookies, fn {name, value} ->
      scope =
        if domain = AnkoleWeb.SessionCookies.domain(),
          do: %{domain: "." <> String.trim_leading(domain, "."), path: "/"},
          else: %{url: origin}

      %{
        name: name,
        value: value,
        httpOnly: true,
        secure: false,
        sameSite: "Lax"
      }
      |> Map.merge(scope)
    end)
  end
end
