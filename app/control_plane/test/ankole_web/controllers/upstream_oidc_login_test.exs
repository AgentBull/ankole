defmodule AnkoleWeb.UpstreamOIDCLoginTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.IdentityProviders
  alias Ankole.OIDC
  alias Ankole.OIDCClientFixture
  alias Ankole.Repo
  alias AnkoleWeb.Session, as: WebSession

  @directory "11111111-1111-1111-1111-111111111111"
  @issuer "https://login.microsoftonline.com/#{@directory}/v2.0"
  @token_path "/#{@directory}/oauth2/v2.0/token"
  @redirect_uri "https://rp.example.test/callback"

  setup %{tenant: tenant} do
    Req.Test.set_req_test_to_shared()
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    Ankole.AppConfigure.Registry.clear_for_test()
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)

    {:ok, _} =
      IdentityProviders.save_provider(
        "entra",
        "entra-id",
        %{
          "tenantID" => @directory,
          "clientID" => "upstream-client",
          "clientSecret" => "test-secret",
          "sync" => %{"contacts" => false}
        },
        true
      )

    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Upstream authentication RP",
        type: "public",
        enabled: true,
        redirect_uris: [@redirect_uri],
        scopes: ["openid"],
        allowed_identity_provider_ids: ["entra"]
      })

    {:ok, client: client}
  end

  for params <- [
        %{"prompt" => "login"},
        %{"max_age" => "0"},
        %{"max_age" => "60"},
        %{"claims" => ~s({"id_token":{"auth_time":{"essential":true}}})}
      ] do
    @params params
    test "RP authentication preserves verified upstream time for #{inspect(params)}", %{
      conn: conn,
      client: client
    } do
      {conn, oauth_request, upstream} = begin_upstream(conn, client, @params)
      assert upstream["nonce"] == upstream["state"]
      assert upstream["nonce"] != "rp-nonce"

      assert upstream["max_age"] ==
               if(@params["prompt"] == "login", do: "0", else: @params["max_age"])

      assert upstream["prompt"] ==
               if(@params["prompt"] == "login" or @params["max_age"] == "0", do: "login")

      assert Ankole.JSON.decode!(upstream["claims"]) ==
               %{"id_token" => %{"auth_time" => %{"essential" => true}}}

      auth_time = System.system_time(:second)
      stub_upstream(upstream["nonce"], %{"auth_time" => auth_time})
      conn = callback(conn, upstream)
      # The SaaS edition redirects to the absolute Pod origin.
      assert %URI{path: "/oauth/authorize/resume", query: query} = URI.parse(redirected_to(conn))
      assert query == "oauth_request=" <> oauth_request
      assert WebSession.oauth_session(conn)["auth_time"] == auth_time
      assert WebSession.site_admin_session(conn) == nil

      conn =
        conn |> recycle() |> get("/oauth/authorize/resume", %{"oauth_request" => oauth_request})

      issued = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert issued["state"] == "rp-state"
      assert is_binary(issued["code"])

      tokens =
        conn
        |> recycle()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => client.id,
          "redirect_uri" => @redirect_uri,
          "code" => issued["code"],
          "code_verifier" => String.duplicate("v", 43)
        })
        |> json_response(200)

      {:ok, jwk} = Ankole.OIDC.SigningKey.public_jwk()

      assert {:ok, %{"auth_time" => ^auth_time, "nonce" => "rp-nonce"}} =
               AttestoClient.IDToken.verify(tokens["id_token"],
                 issuer: Ankole.OIDC.Config.issuer(),
                 client_id: client.id,
                 jwks: %{"keys" => [jwk]},
                 nonce: "rp-nonce"
               )
    end
  end

  for {proof, error} <- [
        {%{}, :authentication_time_unavailable},
        {%{"auth_time" => :old}, :authentication_too_old},
        {%{"auth_time" => :current, "nonce" => "wrong-nonce"}, :nonce_mismatch},
        {%{"auth_time" => :current, "oid" => "other-user"}, :subject_mismatch}
      ] do
    @proof proof
    @error error
    test "invalid upstream proof #{@error} cannot create a Human or authentication", %{
      conn: conn,
      client: client
    } do
      {conn, oauth_request, upstream} = begin_upstream(conn, client, %{"prompt" => "login"})
      count = Repo.aggregate(Ankole.Principals.Principal, :count)
      now = System.system_time(:second)

      proof =
        Map.new(@proof, fn
          {key, :old} -> {key, now - 600}
          {key, :current} -> {key, now}
          pair -> pair
        end)

      stub_upstream(upstream["nonce"], proof)

      conn = callback(conn, upstream)
      body = json_response(conn, 400)

      expected_error =
        case @error do
          :subject_mismatch -> ":oidc_subject_mismatch"
          reason -> inspect({:invalid_id_token, reason})
        end

      assert body["error"] == expected_error

      assert WebSession.oauth_session(conn) == nil
      assert Repo.aggregate(Ankole.Principals.Principal, :count) == count

      assert {:ok, %{status: :pending}} =
               Ankole.OIDC.AuthorizationRequests.get(
                 WebSession.browser_reference(conn),
                 oauth_request
               )
    end
  end

  test "ordinary upstream login keeps an unknown authentication time unknown", %{
    conn: conn,
    client: client
  } do
    {conn, oauth_request, upstream} = begin_upstream(conn, client, %{})
    refute Map.has_key?(upstream, "prompt")
    refute Map.has_key?(upstream, "max_age")
    refute Map.has_key?(upstream, "claims")
    stub_upstream(upstream["nonce"], %{})

    conn = callback(conn, upstream)
    # The SaaS edition redirects to the absolute Pod origin.
    assert %URI{path: "/oauth/authorize/resume", query: query} = URI.parse(redirected_to(conn))
    assert query == "oauth_request=" <> oauth_request
    assert %{"auth_time" => nil} = WebSession.oauth_session(conn)
    assert WebSession.site_admin_session(conn) == nil
  end

  test "Enterprise OIDC login with console_return returns directly to Console and grants siteadmin access",
       %{conn: conn, tenant: tenant} do
    {:ok, %{principal: admin}} =
      Ankole.Principals.create_human(%{
        email: "upstream@example.com",
        display_name: "Upstream Admin"
      })

    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(admin.uid)

    {:ok, _} =
      Ankole.PrincipalsFixtures.create_external_identity(%{
        principal_uid: admin.uid,
        provider: "entra",
        external_id: "graph-user"
      })

    console_entry = conn |> init_test_session(%{}) |> get("/site-admin-console/settings")
    login_redirect = redirected_to(console_entry)
    refute login_redirect =~ "/site-admin-console"

    console_return =
      URI.parse(login_redirect).query |> URI.decode_query() |> Map.fetch!("console_return")

    authorized =
      console_entry
      |> recycle()
      |> pod_conn(tenant)
      |> get("/sessions/oidc/entra/authorization", %{"console_return" => console_return})

    upstream =
      authorized |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    stub_upstream(upstream["nonce"], %{"auth_time" => System.system_time(:second)})

    completed =
      authorized
      |> recycle()
      |> pod_conn(tenant)
      |> get("/sessions/oidc/entra/callback", %{"code" => "code-1", "state" => upstream["state"]})

    expected_console_url = AnkoleWeb.PodURL.site_origin(conn) <> "/site-admin-console/settings"
    assert redirected_to(completed) == expected_console_url
    assert WebSession.site_admin_session(completed)["principal_uid"] == admin.uid

    console_shell =
      completed
      |> recycle()
      |> site_conn()
      |> get("/site-admin-console/settings")

    assert html_response(console_shell, 200) =~
             ~s(<meta name="ankole-principal" content="#{admin.uid}">)
  end

  test "only providers that can force authentication enter the fresh provider list", %{
    client: client
  } do
    previous_sources = Application.get_env(:ankole, :site_identity_sources, [])
    Application.put_env(:ankole, :site_identity_sources, [])
    on_exit(fn -> Application.put_env(:ankole, :site_identity_sources, previous_sources) end)

    {:ok, _} =
      IdentityProviders.save_provider(
        "google",
        "google-workspace",
        %{
          "clientID" => "google-client",
          "clientSecret" => "secret",
          "oidc" => %{"allowedDomains" => ["example.com"]},
          "sync" => %{"contacts" => false}
        },
        true
      )

    {:ok, _} =
      IdentityProviders.save_provider(
        "slack",
        "slack",
        %{
          "clientID" => "slack-client",
          "clientSecret" => "secret",
          "sync" => %{"contacts" => false}
        },
        true
      )

    {:ok, client} = OIDC.get_active_client(client.id)
    client = %{client | allowed_identity_provider_ids: []}

    for {mail, site_sources} <- [
          {nil, []},
          {%{"server" => "smtp.example.test", "from" => "login@example.test"}, ["email_otp"]}
        ] do
      assert {:ok, _} = Ankole.Authn.Config.put_mail(mail)
      assert {:ok, all} = Ankole.OIDC.LoginPolicy.providers(client, %{})

      assert MapSet.new(Enum.map(all, & &1["provider_id"])) ==
               MapSet.new(["entra", "google", "slack"] ++ site_sources)

      for request <- [
            %{"prompt" => ["login"]},
            %{"max_age" => 0},
            %{"max_age" => 60},
            %{"auth_time_essential?" => true}
          ] do
        assert {:ok, fresh} = Ankole.OIDC.LoginPolicy.providers(client, request)

        assert Enum.sort(Enum.map(fresh, & &1["provider_id"])) ==
                 Enum.sort(["entra"] ++ site_sources)
      end
    end

    for provider <- ["google", "slack"] do
      assert {:error, :oidc_unsupported} =
               IdentityProviders.Login.authorization_url(provider,
                 redirect_uri: "https://ankole.example.test/callback",
                 state: "state",
                 nonce: "nonce",
                 auth_time_required: true
               )

      assert {:error, :oidc_unsupported} =
               IdentityProviders.Login.complete_oidc_login(
                 provider,
                 "code",
                 nonce: "nonce",
                 auth_time_required: true
               )
    end
  end

  defp begin_upstream(conn, client, params) do
    verifier = String.duplicate("v", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    conn =
      conn
      |> init_test_session(%{})
      |> get(
        "/oauth/authorize",
        Map.merge(
          %{
            "client_id" => client.id,
            "redirect_uri" => @redirect_uri,
            "response_type" => "code",
            "scope" => "openid",
            "state" => "rp-state",
            "nonce" => "rp-nonce",
            "code_challenge" => challenge,
            "code_challenge_method" => "S256"
          },
          params
        )
      )

    oauth_request =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("oauth_request")

    conn =
      conn
      |> recycle()
      |> get("/sessions/oidc/entra/authorization", %{"oauth_request" => oauth_request})

    upstream = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {conn, oauth_request, upstream}
  end

  defp callback(conn, upstream) do
    conn
    |> recycle()
    |> get("/sessions/oidc/entra/callback", %{"code" => "code-1", "state" => upstream["state"]})
  end

  defp stub_upstream(nonce, proof) do
    {id_token, jwks} =
      OIDCClientFixture.token(
        @issuer,
        "upstream-client",
        Map.merge(
          %{
            "sub" => "pairwise-subject",
            "oid" => "graph-user",
            "tid" => @directory,
            "nonce" => nonce
          },
          proof
        )
      )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        @token_path ->
          Req.Test.json(conn, %{
            "id_token" => id_token,
            "access_token" => "access",
            "expires_in" => 300
          })

        "/v1.0/me" ->
          Req.Test.json(conn, %{
            "id" => "graph-user",
            "displayName" => "Upstream Human",
            "mail" => "upstream@example.com"
          })

        _discovery ->
          OIDCClientFixture.discovery(conn, @issuer, jwks)
      end
    end)
  end
end
