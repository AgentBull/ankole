defmodule Ankole.EditionFixture.Test do
  use ExUnit.Case

  test "the selected source build includes private test support" do
    assert Ankole.EditionFixture.TestSupport.compiled?()

    assert Enum.any?(
             Mix.Project.config()[:test_paths],
             &String.ends_with?(&1, "internals/control_plane/test")
           )

    assert Ankole.IdentityProviders.SiteSources.registered?("fixture-site")
  end
end

defmodule Ankole.EditionFixture.ConformanceTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  import Ankole.PrincipalsFixtures
  alias Ankole.{AppConfigure, Repo}
  alias AnkoleWeb.Session, as: WebSession
  @otp_path "/api/v2/browser/sessions/email-otp/challenges"

  setup %{conn: conn} do
    {:ok, tenant} = Ankole.Tenants.privileged()
    :ok = Repo.put_tenant_id(tenant.id)
    {:ok, true} = AppConfigure.put_global_by_key("setup.completed", true)
    AppConfigure.Cache.clear_for_test()
    %{tenant: tenant, conn: assign(conn, :test_tenant, tenant)}
  end

  test "FixturePodModule enforces Host, session, tenant and Principal authorization", %{
    conn: conn,
    tenant: tenant
  } do
    assert conn |> api_get("/api/v2/saas-pod/fixture-settings") |> response(404)

    assert conn
           |> pod_conn(tenant)
           |> api_get("/api/v2/saas-pod/fixture-settings")
           |> api_response(401)

    %{principal: member} = human_fixture()

    member_conn =
      conn |> pod_conn(tenant) |> init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, completed} =
      Ankole.BrowserSessions.authenticate(
        WebSession.browser_reference(member_conn),
        :pod,
        %{
          "principal_uid" => member.uid,
          "access_version" => member.access_version,
          "provider_id" => "fixture",
          "external_id" => "fixture-member"
        },
        mode: :add
      )

    member_conn =
      WebSession.put_authentication(member_conn, completed.browser, completed.authentication)

    assert member_conn |> api_get("/api/v2/saas-pod/fixture-settings") |> api_response(403)

    {admin_conn, uid} = active_admin_conn_with_principal(conn)

    result =
      admin_conn
      |> pod_conn(tenant)
      |> api_get("/api/v2/saas-pod/fixture-settings")
      |> api_response(200)

    assert result == %{"tenantID" => tenant.id, "principalUID" => uid}
    assert admin_conn |> pod_conn(tenant) |> api_get("/api/v2/saas/openapi.json") |> response(404)

    assert Map.has_key?(
             Ankole.SaaSWeb.PodJSONAPIRouter.spec().paths,
             "/api/v2/saas-pod/fixture-settings"
           )
  end

  test "the browser session API omits the HTML host snapshots", %{conn: conn} do
    conn = active_admin_conn(conn)
    result = conn |> api_get("/api/v2/browser/session") |> api_response(200)
    refute Map.has_key?(result, "features")
    refute Map.has_key?(result, "activePlugins")
  end

  test "a site quota contribution limits tenant A while tenant B can create two Agents", %{
    tenant: tenant
  } do
    previous = Application.get_env(:ankole, :fixture_agent_limits, %{})
    Application.put_env(:ankole, :fixture_agent_limits, %{tenant.id => 1})
    on_exit(fn -> Application.put_env(:ankole, :fixture_agent_limits, previous) end)
    provider = worker_provider_fixture()
    %{principal: owner} = human_fixture()

    attrs = %{
      display_name: "Fixture Agent",
      role: "Researcher",
      handle: "limited-one",
      owner_principal_uid: owner.uid,
      worker_provider_id: provider.provider_id
    }

    assert {:ok, _} = Ankole.Principals.create_agent(attrs)

    assert {:error, :fixture_quota_exceeded} =
             Ankole.Principals.create_agent(%{attrs | handle: "over-limit"})

    assert length(Ankole.Principals.list_agents()) == 1
    other = Ankole.DataCase.create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: owner} = human_fixture()
      attrs = %{attrs | owner_principal_uid: owner.uid}
      assert {:ok, _} = Ankole.Principals.create_agent(%{attrs | handle: "unlimited-one"})
      assert {:ok, _} = Ankole.Principals.create_agent(%{attrs | handle: "unlimited-two"})
    end)
  end

  @tag timeout: 120_000
  test "the built Pod and Auth extensions use the real HTTP, session, generated client and SMTP contracts",
       %{tenant: tenant} do
    assets = Application.get_env(:ankole, AnkoleWeb.Assets)
    Application.put_env(:ankole, AnkoleWeb.Assets, dev_server: nil)
    on_exit(fn -> Application.put_env(:ankole, AnkoleWeb.Assets, assets) end)
    email = "fixture-browser@example.test"
    %{principal: principal} = human_fixture(email: email)
    {:ok, _} = first_site_admin_fixture(principal.uid)

    {:ok, _} =
      Repo.transact(fn ->
        Ankole.Principals.bind_site_credential_in_tx(principal.uid, %{
          provider_id: "email_otp",
          subject_id: email,
          verified_email: email
        })
      end)

    smtp = Ankole.Authn.SMTPFixture.start(self())
    on_exit(fn -> Ankole.Authn.SMTPFixture.stop(smtp) end)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "127.0.0.1",
        "port" => smtp.port,
        "ssl" => true,
        "from" => "fixture@example.test",
        "cacertfile" => smtp.ca_path
      })

    directory =
      Path.join(System.tmp_dir!(), "ankole-extension-tls-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    key = Path.join(directory, "key.pem")
    cert = Path.join(directory, "cert.pem")

    {_output, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-days",
          "1",
          "-keyout",
          key,
          "-out",
          cert,
          "-subj",
          "/CN=site.example.test"
        ],
        stderr_to_stdout: true
      )

    server =
      start_supervised!(
        {Bandit,
         plug: AnkoleWeb.Endpoint,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         keyfile: key,
         certfile: cert}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    script = Path.expand("../../webapps/fixture-browser.ts", __DIR__)

    for mode <- ["enabled", "disabled"] do
      for key <- ["fixture.pod-module", "fixture.auth-challenge"] do
        {:ok, _} =
          AppConfigure.put_global_by_key("features." <> key, %{
            "enabled" => true,
            "percent" => 0,
            "targets" => %{tenant.id => mode == "enabled"}
          })
      end

      inbox = Path.join(directory, mode <> "-email.txt")

      browser =
        Task.async(fn ->
          System.cmd(
            "bun",
            ["run", script, Integer.to_string(port), tenant.id, principal.uid, mode, inbox],
            stderr_to_stdout: true
          )
        end)

      assert_receive {:smtp_message, _from, [^email], message}, 30_000
      File.write!(inbox, Ankole.Authn.SMTPFixture.text(message))
      {output, status} = Task.await(browser, 60_000)
      assert status == 0, output
      assert output =~ "edition-browser-verified"
    end
  end

  test "FixtureAuthChallenge wraps the core challenge route and shares its anonymous snapshot", %{
    conn: conn
  } do
    previous = Application.get_env(:ankole, Ankole.Authn.Mailer)
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Test)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, Ankole.Authn.Mailer, previous),
        else: Application.delete_env(:ankole, Ankole.Authn.Mailer)
    end)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "smtp.example.test",
        "from" => "fixture@example.test"
      })

    conn = init_test_session(conn, %{})
    providers = conn |> api_get("/api/v2/browser/identity-providers", %{purpose: "site"})
    assert api_response(providers, 200)["providers"]

    payload = %{purpose: "site", email: "fixture@example.test"}
    assert conn |> api_post(@otp_path, payload) |> response(403) == "Fixture challenge required"

    passed =
      conn |> put_req_header("x-fixture-challenge", "passed") |> api_post(@otp_path, payload)

    assert api_response(passed, 200)["challengeID"]
    assert_receive {:email, %Swoosh.Email{to: [{_, "fixture@example.test"}]}}

    {:ok, _} =
      AppConfigure.put_global_by_key("features.fixture.auth-challenge", %{
        "enabled" => false,
        "percent" => 100,
        "targets" => %{}
      })

    snapshot =
      conn
      |> api_get("/api/v2/browser/identity-providers", %{purpose: "site"})
      |> api_response(200)

    refute Map.has_key?(snapshot, "features")

    unchallenged =
      conn |> api_post(@otp_path, %{purpose: "site", email: "fixture-disabled@example.test"})

    assert api_response(unchallenged, 200)["challengeID"]
    assert_receive {:email, %Swoosh.Email{to: [{_, "fixture-disabled@example.test"}]}}

    assert AnkoleWeb.JSONAPI.BrowserRouter.spec().paths[@otp_path].post.operationId ==
             "requestEmailOTP"
  end
end
