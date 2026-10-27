defmodule Ankole.Authn.EmailTransportTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  alias Ankole.{AppConfigure, AuthZ}
  alias Ankole.Authn.{Mailer, SMTPFixture}
  alias AnkoleWeb.Session, as: WebSession

  test "FOSS bootstrap verifies email through the real TLS SMTP adapter before opening Console",
       %{conn: conn, tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    AppConfigure.Cache.clear_for_test()
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    {:ok, false} = AppConfigure.put_global_by_key("setup.completed", false)
    {:ok, _} = AppConfigure.put_global_by_key("authn.email.mail", nil)
    {:ok, _} = Ankole.Setup.Config.put_bootstrap_activation_code("ABCDEFGH")
    smtp = SMTPFixture.start(self())
    previous = Application.get_env(:ankole, Mailer)
    Application.put_env(:ankole, Mailer, adapter: Swoosh.Adapters.SMTP)
    Ankole.Authn.RateLimiter.reset_for_test()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, Mailer, previous),
        else: Application.delete_env(:ankole, Mailer)

      SMTPFixture.stop(smtp)
    end)

    settings = %{
      "server" => "127.0.0.1",
      "port" => smtp.port,
      "ssl" => true,
      "from" => "login@ankole.test",
      "cacertfile" => smtp.ca_path
    }

    page = get(conn, "/setup")
    [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, page.resp_body)
    origin = URI.to_string(%URI{scheme: to_string(page.scheme), host: page.host, port: page.port})

    conn =
      page
      |> recycle()
      |> put_req_header("x-csrf-token", csrf)
      |> put_req_header("origin", origin)
      |> put_private(:plug_skip_csrf_protection, false)
      |> api_post("/api/v2/browser/setup/sessions", %{activation_code: "ABCDEFGH"})

    assert %{"ok" => true} = api_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> api_post("/api/v2/browser/setup/email-otp/challenges", %{
        email: "operator@example.org",
        mail: settings
      })

    %{"challengeID" => challenge} = api_response(conn, 200)
    assert_receive {:smtp_message, "login@ankole.test", ["operator@example.org"], message}, 5_000
    [_, code] = Regex.run(~r/code is (\d{6})/, SMTPFixture.text(message))
    html = SMTPFixture.html(message)
    assert html =~ "<!doctype html>"
    assert html =~ code
    assert {:ok, false} = Ankole.Setup.Config.completed?()
    assert is_nil(WebSession.admin_session(conn))
    wrong = if code == "000000", do: "111111", else: "000000"

    conn =
      conn
      |> recycle_api()
      |> api_post("/api/v2/browser/setup/email-otp/verifications", %{
        challengeID: challenge,
        code: wrong
      })

    assert api_error(conn, 401)["code"] == "invalid_code"
    assert {:ok, false} = Ankole.Setup.Config.completed?()

    conn =
      conn
      |> recycle_api()
      |> api_post("/api/v2/browser/setup/email-otp/challenges", %{
        email: "operator@example.org",
        mail: settings
      })

    %{"challengeID" => resent_challenge} = api_response(conn, 200)

    assert_receive {:smtp_message, "login@ankole.test", ["operator@example.org"], resent_message},
                   5_000

    [_, resent_code] = Regex.run(~r/code is (\d{6})/, SMTPFixture.text(resent_message))
    assert {:ok, false} = Ankole.Setup.Config.completed?()

    conn =
      conn
      |> recycle_api()
      |> api_post("/api/v2/browser/setup/email-otp/verifications", %{
        challengeID: resent_challenge,
        code: resent_code
      })

    assert %{"returnTo" => "/site-admin-console"} = api_response(conn, 200)
    assert %{"principal_uid" => uid} = WebSession.site_admin_session(conn)
    assert AuthZ.site_admin?(uid)
    assert Ankole.Repo.with_tenant(tenant.id, fn -> AuthZ.pod_admin?(uid) end)
  end

  test "SMTP authentication failures keep their server diagnostic without the login code" do
    smtp = SMTPFixture.start(self())
    previous = Application.get_env(:ankole, Mailer)
    Application.put_env(:ankole, Mailer, adapter: Swoosh.Adapters.SMTP)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, Mailer, previous),
        else: Application.delete_env(:ankole, Mailer)

      SMTPFixture.stop(smtp)
    end)

    settings = %{
      "server" => "127.0.0.1",
      "port" => smtp.port,
      "ssl" => true,
      "from" => "login@ankole.test",
      "cacertfile" => smtp.ca_path,
      "username" => "operator",
      "password" => "smtp-secret-never-log"
    }

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        assert {:error, :mail_unavailable} =
                 Mailer.send_code("person@example.org", "691357", :login, mail: settings)
      end)

    assert log =~ "authn.mail_delivery_failed"
    assert log =~ "missing_requirement"
    assert log =~ "auth"
    refute log =~ "691357"
    refute log =~ "smtp-secret-never-log"
  end
end
