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
    Ankole.AppConfigure.Cache.clear_for_test()
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
      {conn, flow, upstream} = begin_upstream(conn, client, @params)
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
      assert redirected_to(conn) == "/oauth/authorize/resume?flow=" <> flow
      assert WebSession.oauth_session(conn)["auth_time"] == auth_time
      assert WebSession.admin_session(conn) == nil

      conn = conn |> recycle() |> get("/oauth/authorize/resume", %{"flow" => flow})
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
                 issuer: Ankole.TokenSigning.issuer(),
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
      {conn, flow, upstream} = begin_upstream(conn, client, %{"prompt" => "login"})
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
      assert {:ok, %{status: :pending}} = WebSession.login_transaction(conn, flow)
    end
  end

  test "ordinary upstream login keeps an unknown authentication time unknown", %{
    conn: conn,
    client: client
  } do
    {conn, flow, upstream} = begin_upstream(conn, client, %{})
    refute Map.has_key?(upstream, "prompt")
    refute Map.has_key?(upstream, "max_age")
    refute Map.has_key?(upstream, "claims")
    stub_upstream(upstream["nonce"], %{})

    conn = callback(conn, upstream)
    assert redirected_to(conn) == "/oauth/authorize/resume?flow=" <> flow
    assert %{"auth_time" => nil} = WebSession.oauth_session(conn)
    assert WebSession.admin_session(conn) == nil
  end

  test "only providers that can force authentication enter the fresh provider list", %{
    client: client
  } do
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
    assert {:ok, all} = Ankole.OIDC.LoginPolicy.providers(client, %{})

    native_sources =
      for {id, _adapter} <- Application.get_env(:ankole, :site_identity_sources, []), do: id

    assert MapSet.new(Enum.map(all, & &1["provider_id"])) ==
             MapSet.new(["entra", "google", "slack"] ++ native_sources)

    for request <- [
          %{"prompt" => ["login"]},
          %{"max_age" => 0},
          %{"max_age" => 60},
          %{"auth_time_essential?" => true}
        ] do
      assert {:ok, fresh} = Ankole.OIDC.LoginPolicy.providers(client, request)

      assert Enum.sort(Enum.map(fresh, & &1["provider_id"])) ==
               Enum.sort(["entra"] ++ native_sources)
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

    flow =
      conn
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("flow")

    conn = conn |> recycle() |> get("/sessions/oidc/entra/authorization", %{"flow" => flow})
    upstream = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {conn, flow, upstream}
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
