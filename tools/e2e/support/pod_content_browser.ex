defmodule Ankole.E2E.PodContentBrowser do
  @moduledoc "Authenticated browser actions for real-model Pod user stories."

  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias Ankole.Repo

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
    assert {:ok, _} = Ankole.Setup.Config.put_completed(true)
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

  defp browser_cookies!(human, origin) do
    options =
      Plug.Session.init(AnkoleWeb.SessionCookies.session_options())

    conn =
      Plug.Test.conn(:get, origin <> "/")
      |> Map.put(:secret_key_base, AnkoleWeb.Endpoint.config(:secret_key_base))
      |> Plug.Session.call(options)
      |> Plug.Conn.fetch_session()

    {:ok, conn, transaction} = AnkoleWeb.Session.begin_login(conn, :pod, %{})
    reference = AnkoleWeb.Session.browser_reference(conn)

    on_exit(
      Repo.bind_tenant(fn ->
        assert {:ok, _} = Ankole.BrowserSessions.logout(reference)
        assert {:ok, browser} = Ankole.BrowserSessions.get(reference)
        Repo.delete!(browser)
      end)
    )

    assert {:ok, _} =
             Ankole.BrowserSessions.bind_provider(reference, transaction.id, "pod-real-llm")

    assert {:ok, conn, _} =
             AnkoleWeb.Session.complete_login(conn, transaction.id, %{
               "principal_uid" => human.uid,
               "access_version" => human.access_version,
               "provider_id" => "pod-real-llm",
               "external_id" => human.uid
             })

    conn = Plug.Conn.send_resp(conn, 200, "test session")

    Enum.map(conn.resp_cookies, fn {name, cookie} ->
      scope =
        if domain = cookie[:domain],
          do: %{domain: "." <> String.trim_leading(domain, "."), path: "/"},
          else: %{url: origin}

      %{
        name: name,
        value: cookie.value,
        httpOnly: true,
        secure: false,
        sameSite: "Lax"
      }
      |> Map.merge(scope)
    end)
  end
end
