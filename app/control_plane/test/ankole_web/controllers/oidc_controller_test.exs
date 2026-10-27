defmodule AnkoleWeb.OIDCControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI

  import Ankole.PrincipalsFixtures

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.OIDC
  alias Ankole.OIDC.SigningKey
  alias Ankole.OIDC.Tokens
  alias Ankole.OIDC.Config, as: OIDCConfig
  alias Ankole.Repo
  alias AnkoleWeb.Session, as: WebSession

  @redirect_uri "https://spa.example.test/callback"
  @origin "https://spa.example.test"

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "lark-main",
        "lark",
        %{"appID" => "cli_oidc_fixture", "appSecret" => "secret"},
        true
      )

    smtp = Ankole.Authn.SMTPFixture.start(self())
    on_exit(fn -> Ankole.Authn.SMTPFixture.stop(smtp) end)

    {:ok, _} =
      Ankole.Authn.Config.put_mail(%{
        "server" => "127.0.0.1",
        "port" => smtp.port,
        "ssl" => true,
        "from" => "login@ankole.test",
        "cacertfile" => smtp.ca_path
      })

    :ok
  end

  test "signing-key reads do not enter the key owner process" do
    assert :ok = :sys.suspend(SigningKey)

    try do
      assert {:ok, %{private_key_pem: private_key_pem}} = SigningKey.get()
      assert is_binary(private_key_pem)
      assert {:ok, %{"kty" => "RSA"}} = SigningKey.public_jwk()
    after
      :ok = :sys.resume(SigningKey)
    end
  end

  test "Attesto preserves the deployed RSA key identity and public JWK" do
    assert {:ok, key} = SigningKey.get()
    [entry] = :public_key.pem_decode(key.private_key_pem)

    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} =
      :public_key.pem_entry_decode(entry)

    n = modulus |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)
    e = exponent |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

    old_kid =
      :crypto.hash(:sha256, ~s({"e":"#{e}","kty":"RSA","n":"#{n}"}))
      |> Base.url_encode64(padding: false)

    assert key.kid == old_kid

    assert key.public_jwk == %{
             "alg" => "RS256",
             "e" => e,
             "kid" => old_kid,
             "kty" => "RSA",
             "n" => n,
             "use" => "sig"
           }

    assert %{"keys" => [jwk]} = Attesto.JWKS.from_config(OIDC.attesto_config())
    assert jwk == key.public_jwk
  end

  test "discovery and JWKS publish the one RS256 installation key", %{conn: conn} do
    discovery = conn |> get("/.well-known/openid-configuration") |> json_response(200)

    assert discovery["issuer"] == OIDCConfig.issuer()
    assert discovery["authorization_endpoint"] == OIDCConfig.issuer() <> "/oauth/authorize"
    assert discovery["token_endpoint"] == OIDCConfig.issuer() <> "/oauth/token"
    assert discovery["userinfo_endpoint"] == OIDCConfig.issuer() <> "/oauth/userinfo"
    assert discovery["jwks_uri"] == OIDCConfig.issuer() <> "/.well-known/jwks.json"
    assert discovery["response_types_supported"] == ["code"]
    assert discovery["grant_types_supported"] == ["authorization_code", "refresh_token"]
    assert discovery["code_challenge_methods_supported"] == ["S256"]
    assert discovery["id_token_signing_alg_values_supported"] == ["RS256"]
    assert discovery["token_endpoint_auth_methods_supported"] == ["none", "client_secret_basic"]

    assert %{"keys" => [%{"alg" => "RS256", "kid" => kid, "kty" => "RSA", "use" => "sig"} = jwk]} =
             conn |> recycle() |> get("/.well-known/jwks.json") |> json_response(200)

    assert {:ok, %{kid: ^kid, public_jwk: ^jwk}} = SigningKey.get()
  end

  test "public Client completes PKCE, receives RS256 tokens, rotates refresh, and serves UserInfo",
       %{
         conn: conn
       } do
    human =
      human_fixture(%{
        uid: unique_uid("oidc-human"),
        display_name: "OIDC Human",
        email: "#{unique_uid("oidc-human")}@example.com"
      })

    client =
      create_client!(%{
        name: "Public SPA",
        type: "public",
        scopes: ["openid", "profile", "email", "offline_access"]
      })

    verifier = pkce_verifier()
    code = authorize_code!(conn, human.principal.uid, client.id, verifier)

    token_response =
      conn
      |> recycle()
      |> put_req_header("origin", @origin)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => verifier
      })
      |> json_response(200)

    assert %{
             "access_token" => access_token,
             "id_token" => id_token,
             "refresh_token" => refresh_token,
             "scope" => "openid profile email offline_access"
           } = token_response

    assert token_response["expires_in"] in 1..1800

    assert {:ok,
            %{
              "sub" => principal_uid,
              "client_id" => client_id,
              "subject_type" => "human",
              "token_use" => "access",
              "scope" => "openid profile email offline_access"
            } = access_claims} = Tokens.verify_access(access_token, Tokens.userinfo_audience())

    assert principal_uid == human.principal.uid
    assert client_id == client.id
    assert is_binary(access_claims["jti"])
    assert is_integer(access_claims["iat"])
    assert Tokens.userinfo_audience() in List.wrap(access_claims["aud"])

    assert {:error, :expired} =
             Attesto.Token.verify(Ankole.OIDC.Config.get(), access_token,
               now: access_claims["exp"]
             )

    assert access_claims["exp"] > access_claims["iat"]

    assert %{"alg" => "RS256", "kid" => kid, "typ" => "at+jwt"} = jwt_header(access_token)
    assert {:ok, %{kid: ^kid}} = SigningKey.get()

    id_claims = verify_id_token!(id_token, client.id)
    assert id_claims["sub"] == human.principal.uid
    assert id_claims["aud"] == client.id
    assert id_claims["nonce"] == "nonce-1"
    assert id_claims["name"] == "OIDC Human"
    assert id_claims["email"] == human.human_user.email
    assert jwt_header(id_token)["alg"] == "RS256"

    userinfo =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("origin", @origin)
      |> get("/oauth/userinfo")
      |> json_response(200)

    assert userinfo["sub"] == human.principal.uid
    assert userinfo["name"] == "OIDC Human"
    assert userinfo["email"] == human.human_user.email

    refreshed =
      conn
      |> recycle()
      |> put_req_header("origin", @origin)
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => refresh_token
      })
      |> json_response(200)

    assert refreshed["access_token"] != access_token
    assert refreshed["refresh_token"] != refresh_token

    replay =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => refresh_token
      })

    retried = json_response(replay, 200)
    assert retried["refresh_token"] == refreshed["refresh_token"]

    advanced =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => refreshed["refresh_token"]
      })
      |> json_response(200)

    reuse =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => refresh_token
      })

    assert %{"error" => "invalid_grant"} = json_response(reuse, 400)

    assert {:error, _} =
             Tokens.verify_access(advanced["access_token"], Tokens.userinfo_audience())
  end

  test "authorization errors use only a trusted redirect and consent ignores unimplemented claims",
       %{conn: conn} do
    human = human_fixture()
    client = create_client!(%{})
    session = oauth_session_conn(conn, human.principal.uid)
    request = authorization_request(client.id, "openid")
    session = get(session, "/oauth/authorize", request)
    assert is_binary(redirect_query(session)["code"])

    for {parameter, expected} <- [
          {"request", "request_not_supported"},
          {"request_uri", "request_uri_not_supported"}
        ] do
      params = Map.put(request, parameter, "unsupported")

      direct =
        get(
          recycle(session),
          "/oauth/authorize",
          Map.put(params, "redirect_uri", "https://unregistered.example/callback")
        )

      assert %{"error" => "invalid_request"} = json_response(direct, 400)
      assert get_resp_header(direct, "location") == []
      redirected = get(recycle(session), "/oauth/authorize", params)
      assert redirect_query(redirected)["error"] == expected
    end

    result =
      get(
        recycle(session),
        "/oauth/authorize",
        request
        |> Map.put("prompt", "consent")
        |> Map.put("claims", ~s({"id_token":{"unknown":{"essential":true}},"other":{"x":true}}))
      )

    assert is_binary(redirect_query(result)["code"]), inspect(redirect_query(result))
    refute Map.has_key?(redirect_query(result), "error")
  end

  test "UserInfo accepts case insensitive Bearer and POST form tokens", %{conn: conn} do
    human = human_fixture()
    client = create_client!(%{})

    {:ok, access} =
      Ankole.OIDCFixtures.access_token(human.principal.uid, client.id, "openid profile email")

    bearer =
      conn
      |> recycle()
      |> put_req_header("authorization", "bEaReR " <> access.token)
      |> get("/oauth/userinfo")
      |> json_response(200)

    form =
      conn
      |> recycle()
      |> post("/oauth/userinfo", %{"access_token" => access.token})
      |> json_response(200)

    assert bearer == form
    assert bearer["sub"] == human.principal.uid
    assert bearer["email"] == human.human_user.email
  end

  test "authorization requires an exact redirect URI, openid, and PKCE S256", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("oidc-validation")})
    client = create_client!(%{name: "Exact redirect", type: "public"})
    verifier = pkce_verifier()

    base = %{
      "response_type" => "code",
      "client_id" => client.id,
      "redirect_uri" => @redirect_uri,
      "scope" => "openid",
      "state" => "state-1",
      "code_challenge" => pkce_challenge(verifier),
      "code_challenge_method" => "S256"
    }

    session_conn = oauth_session_conn(conn, human.principal.uid)

    bad_redirect =
      get(session_conn, "/oauth/authorize", %{base | "redirect_uri" => @redirect_uri <> "/other"})

    assert %{"error" => "invalid_request"} = json_response(bad_redirect, 400)

    missing_openid =
      get(recycle(session_conn), "/oauth/authorize", %{base | "scope" => "profile"})

    assert URI.decode_query(URI.parse(redirected_to(missing_openid, 302)).query)["error"] ==
             "invalid_scope"

    plain_pkce =
      get(recycle(session_conn), "/oauth/authorize", %{
        base
        | "code_challenge" => verifier,
          "code_challenge_method" => "plain"
      })

    assert URI.decode_query(URI.parse(redirected_to(plain_pkce, 302)).query)["error"] ==
             "invalid_request"

    unsupported_response_mode =
      get(recycle(session_conn), "/oauth/authorize", Map.put(base, "response_mode", "fragment"))

    assert URI.decode_query(URI.parse(redirected_to(unsupported_response_mode, 302)).query)[
             "error"
           ] == "invalid_request"

    invalid_state =
      get(recycle(session_conn), "/oauth/authorize", Map.put(base, "state", %{"bad" => true}))

    invalid_state_query = URI.decode_query(URI.parse(redirected_to(invalid_state, 302)).query)
    assert invalid_state_query["error"] == "invalid_request"
    refute Map.has_key?(invalid_state_query, "state")
  end

  test "authorization code presentation is single-use even when PKCE validation fails", %{
    conn: conn
  } do
    human = human_fixture(%{uid: unique_uid("oidc-code")})
    client = create_client!(%{name: "Code replay", type: "public"})
    verifier = pkce_verifier()
    code = authorize_code!(conn, human.principal.uid, client.id, verifier, "openid")

    wrong =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => String.duplicate("b", 43)
      })

    assert %{"error" => "invalid_grant"} = json_response(wrong, 400)

    malformed =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => "short"
      })

    assert %{"error" => "invalid_grant"} = json_response(malformed, 400)

    spent =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => verifier
      })

    assert %{"error" => "invalid_grant"} = json_response(spent, 400)
    fresh_code = authorize_code!(conn, human.principal.uid, client.id, verifier, "openid")
    first = exchange_public_code(conn, client.id, fresh_code, verifier)
    refute Map.has_key?(first, "refresh_token")

    replay =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "code" => fresh_code,
        "code_verifier" => verifier
      })

    assert %{"error" => "invalid_grant"} = json_response(replay, 400)
  end

  test "confidential Client accepts only client_secret_basic and secret rotation takes effect", %{
    conn: conn
  } do
    human = human_fixture(%{uid: unique_uid("oidc-confidential")})

    {:ok, %{client: client, client_secret: secret}} =
      OIDC.create_client(client_attrs(%{name: "Server Client", type: "confidential"}))

    verifier = pkce_verifier()

    code =
      authorize_code!(conn, human.principal.uid, client.id, verifier, "openid offline_access")

    post_secret =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "client_secret" => secret,
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => verifier
      })

    assert %{"error" => "invalid_client"} = json_response(post_secret, 400)

    basic_with_body_client =
      conn
      |> recycle()
      |> put_req_header("authorization", basic(client.id, secret))
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => verifier
      })

    assert %{"error" => "invalid_request"} = json_response(basic_with_body_client, 400)
    assert get_resp_header(basic_with_body_client, "www-authenticate") == []

    bearer =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer rejected-client-credential")
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => verifier
      })

    assert %{"error" => "invalid_client"} = json_response(bearer, 401)

    assert get_resp_header(bearer, "www-authenticate") ==
             ["Basic realm=\"OIDC token\""]

    token_set =
      conn
      |> recycle()
      |> put_req_header("authorization", basic(client.id, secret))
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "redirect_uri" => @redirect_uri,
        "code" => code,
        "code_verifier" => verifier
      })
      |> json_response(200)

    assert is_binary(token_set["refresh_token"])
    assert {:ok, %{client_secret: rotated}} = OIDC.rotate_secret(client.id)
    assert rotated != secret

    old_secret =
      conn
      |> recycle()
      |> put_req_header("authorization", basic(client.id, secret))
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => token_set["refresh_token"]
      })

    assert %{"error" => "invalid_client"} = json_response(old_secret, 401)

    refreshed =
      conn
      |> recycle()
      |> put_req_header("authorization", basic(client.id, rotated))
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => token_set["refresh_token"]
      })
      |> json_response(200)

    assert is_binary(refreshed["access_token"])
  end

  test "refresh uses the Client's current Scope policy", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("oidc-refresh-scope")})

    client =
      create_client!(%{
        name: "Refresh Scope Client",
        type: "public",
        scopes: ["openid", "email", "offline_access"]
      })

    verifier = pkce_verifier()

    code =
      authorize_code!(
        conn,
        human.principal.uid,
        client.id,
        verifier,
        "openid email offline_access"
      )

    token_set = exchange_public_code(conn, client.id, code, verifier)

    assert {:ok, _client} = OIDC.update_client(client.id, %{scopes: ["openid"]})

    refresh =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => token_set["refresh_token"]
      })

    assert %{"error" => "invalid_grant"} = json_response(refresh, 400)
  end

  test "OIDC refresh requires the declared Client credentials", %{
    conn: conn
  } do
    {admin_conn, admin_uid} = active_admin_conn_with_principal(conn)

    client =
      create_client!(%{
        name: "Dispatch Client",
        type: "public",
        scopes: ["openid", "offline_access"]
      })

    verifier = pkce_verifier()
    code = authorize_code!(admin_conn, admin_uid, client.id, verifier, "openid offline_access")
    oidc_tokens = exchange_public_code(conn, client.id, code, verifier)

    oidc_without_client_credentials =
      admin_conn
      |> with_console_csrf()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => oidc_tokens["refresh_token"]
      })

    assert %{"error" => "invalid_client"} = json_response(oidc_without_client_credentials, 400)

    oidc_with_admin_cookie =
      admin_conn
      |> put_req_header("origin", @origin)
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => Ankole.Ecto.UUIDv7.autogenerate(),
        "refresh_token" => oidc_tokens["refresh_token"]
      })

    assert %{"error" => "invalid_client"} = json_response(oidc_with_admin_cookie, 400)
  end

  test "the token endpoint rejects the removed Console grant", %{conn: conn} do
    result =
      post(conn, "/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })

    assert %{"error" => "unsupported_grant_type"} = json_response(result, 400)
  end

  test "prompt and max_age require fresh proof and preserve the actual authentication time", %{
    conn: conn
  } do
    human = human_fixture()
    client = create_client!(%{})
    session = oauth_session_conn(conn, human.principal.uid)
    auth_time = WebSession.oauth_session(session)["auth_time"]
    request = authorization_request(client.id, "openid")
    session = get(session, "/oauth/authorize", request)

    for params <- [%{"prompt" => "login"}, %{"max_age" => "0"}] do
      result = get(recycle(session), "/oauth/authorize", Map.merge(request, params))
      assert String.starts_with?(redirected_to(result), "/sessions/new?")
      oauth_request = URI.decode_query(URI.parse(redirected_to(result)).query)["oauth_request"]

      {:ok, stored} =
        OIDC.AuthorizationRequests.get(WebSession.browser_reference(result), oauth_request)

      if Map.has_key?(params, "prompt"), do: assert(stored.request["prompt"] == ["login"])
      if Map.has_key?(params, "max_age"), do: assert(stored.request["max_age"] == 0)
    end

    result =
      get(
        recycle(session),
        "/oauth/authorize",
        Map.merge(request, %{"prompt" => "none", "max_age" => "0"})
      )

    assert redirect_query(result)["error"] == "login_required"

    for age <- ["-1", "abc", "2147483648"] do
      result = get(recycle(session), "/oauth/authorize", Map.put(request, "max_age", age))
      assert redirect_query(result)["error"] == "invalid_request"
    end

    issued = get(recycle(session), "/oauth/authorize", Map.put(request, "max_age", "3600"))
    assert is_binary(redirect_query(issued)["code"]), inspect(redirect_query(issued))

    tokens =
      exchange_public_code(conn, client.id, redirect_query(issued)["code"], pkce_verifier())

    claims = verify_id_token!(tokens["id_token"], client.id)
    assert claims["auth_time"] == auth_time
    assert is_binary(claims["sid"])
    refute Map.has_key?(claims, "ankole_authentication")
  end

  test "unknown upstream authentication time is omitted and cannot meet an age request", %{
    conn: conn
  } do
    human = human_fixture()
    client = create_client!(%{})
    session = oauth_session_conn(conn, human.principal.uid, nil)
    issued = get(session, "/oauth/authorize", authorization_request(client.id, "openid"))

    tokens =
      exchange_public_code(conn, client.id, redirect_query(issued)["code"], pkce_verifier())

    refute Map.has_key?(verify_id_token!(tokens["id_token"], client.id), "auth_time")

    result =
      get(
        recycle(issued),
        "/oauth/authorize",
        Map.merge(authorization_request(client.id, "openid"), %{
          "prompt" => "none",
          "max_age" => "3600"
        })
      )

    assert redirect_query(result)["error"] == "login_required"
  end

  test "introspection authenticates a confidential caller and limits results to its own grants",
       %{conn: conn} do
    human = human_fixture()

    {:ok, %{client: client, client_secret: secret}} =
      OIDC.create_client(client_attrs(%{type: "confidential"}))

    {:ok, %{client: other, client_secret: other_secret}} =
      OIDC.create_client(client_attrs(%{type: "confidential"}))

    code = authorize_code!(conn, human.principal.uid, client.id, pkce_verifier())
    basic = "Basic " <> Base.encode64(client.id <> ":" <> secret)

    tokens =
      conn
      |> recycle()
      |> put_req_header("authorization", basic)
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => pkce_verifier()
      })
      |> json_response(200)

    for token <- [tokens["access_token"], tokens["refresh_token"]] do
      active =
        conn
        |> recycle()
        |> put_req_header("authorization", basic)
        |> post("/oauth/introspect", %{"token" => token})
        |> json_response(200)

      assert active["active"] == true
      assert active["sub"] == human.principal.uid
      refute Map.has_key?(active, "client")

      assert %{"active" => false} ==
               conn
               |> recycle()
               |> put_req_header(
                 "authorization",
                 "Basic " <> Base.encode64(other.id <> ":" <> other_secret)
               )
               |> post("/oauth/introspect", %{"token" => token})
               |> json_response(200)
    end

    assert %{"active" => false} ==
             conn
             |> recycle()
             |> put_req_header("authorization", basic)
             |> post("/oauth/introspect", %{"token" => "unknown"})
             |> json_response(200)

    assert %{"error" => "invalid_client"} =
             conn
             |> recycle()
             |> post("/oauth/introspect", %{"token" => tokens["access_token"]})
             |> json_response(401)

    {:ok, _} =
      Repo.with_tenant(human.principal.tenant_id, fn ->
        Ankole.PrincipalsFixtures.disable_principal_fixture(human.principal.uid)
      end)

    assert %{"active" => false} ==
             conn
             |> recycle()
             |> put_req_header("authorization", basic)
             |> post("/oauth/introspect", %{"token" => tokens["access_token"]})
             |> json_response(200)
  end

  test "RP logout confirms before revocation, checks redirects, and rejects an old browser request",
       %{conn: conn} do
    human = human_fixture()
    client = create_client!(%{post_logout_redirect_uris: ["https://spa.example.test/signed-out"]})
    session = oauth_session_conn(conn, human.principal.uid)
    issued = get(session, "/oauth/authorize", authorization_request(client.id, "openid"))

    tokens =
      exchange_public_code(conn, client.id, redirect_query(issued)["code"], pkce_verifier())

    params = %{
      "id_token_hint" => tokens["id_token"],
      "post_logout_redirect_uri" => "https://spa.example.test/signed-out",
      "state" => "return-state"
    }

    invalid =
      get(recycle(issued), "/oauth/logout", %{
        params
        | "post_logout_redirect_uri" => "https://attacker.example/"
      })

    assert html_response(invalid, 400) =~ "ankole-app"
    prepared = get(recycle(issued), "/oauth/logout", params)
    id = redirect_query(prepared)["request"]
    assert {:ok, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())

    confirmation =
      get(recycle(prepared), "/api/v2/browser/oidc-logout/" <> id)
      |> api_response(200)

    assert confirmation["identity"]["principalUID"] == human.principal.uid

    cancelled =
      post(recycle(prepared), "/oauth/logout/confirm", %{"request" => id, "action" => "cancel"})

    assert redirected_to(cancelled) == "/sessions/logged-out?cancelled=1"
    assert {:ok, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())
    prepared = get(recycle(issued), "/oauth/logout", params)
    id = redirect_query(prepared)["request"]

    confirmed =
      post(recycle(prepared), "/oauth/logout/confirm", %{"request" => id, "action" => "confirm"})

    assert redirected_to(confirmed) == "https://spa.example.test/signed-out?state=return-state"
    assert {:error, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())
    assert WebSession.oauth_session(issued) == nil

    repeated = get(recycle(confirmed), "/oauth/logout", params)
    repeated_id = redirect_query(repeated)["request"]
    assert is_binary(repeated_id)

    assert %{"identity" => nil} =
             get(recycle(repeated), "/api/v2/browser/oidc-logout/" <> repeated_id)
             |> api_response(200)

    repeated =
      post(recycle(repeated), "/oauth/logout/confirm", %{
        "request" => repeated_id,
        "action" => "confirm"
      })

    assert redirected_to(repeated) == "https://spa.example.test/signed-out?state=return-state"

    assert html_response(
             post(recycle(prepared), "/oauth/logout/confirm", %{
               "request" => id,
               "action" => "confirm"
             }),
             409
           ) =~ "ankole-app"
  end

  test "a valid hint from another browser requires confirmation of the current identity", %{
    conn: conn
  } do
    first = human_fixture()
    current = human_fixture()
    client = create_client!(%{post_logout_redirect_uris: ["https://spa.example.test/signed-out"]})

    issued =
      conn
      |> oauth_session_conn(first.principal.uid)
      |> get("/oauth/authorize", authorization_request(client.id, "openid"))

    tokens =
      exchange_public_code(conn, client.id, redirect_query(issued)["code"], pkce_verifier())

    params = %{
      "id_token_hint" => tokens["id_token"],
      "post_logout_redirect_uri" => "https://spa.example.test/signed-out"
    }

    current_browser = oauth_session_conn(build_conn(), current.principal.uid)
    prepared = get(current_browser, "/oauth/logout", params)
    id = redirect_query(prepared)["request"]

    confirmation =
      get(recycle(prepared), "/api/v2/browser/oidc-logout/" <> id)
      |> api_response(200)

    assert confirmation["identity"]["principalUID"] == current.principal.uid

    cancelled =
      post(recycle(prepared), "/oauth/logout/confirm", %{"request" => id, "action" => "cancel"})

    assert WebSession.oauth_session(cancelled)["principal_uid"] == current.principal.uid
    assert {:ok, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())
    prepared = get(recycle(cancelled), "/oauth/logout", params)
    id = redirect_query(prepared)["request"]

    confirmed =
      post(recycle(prepared), "/oauth/logout/confirm", %{"request" => id, "action" => "confirm"})

    assert redirected_to(confirmed) == "https://spa.example.test/signed-out"
    assert WebSession.oauth_session(current_browser) == nil
    assert {:ok, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())
  end

  test "ordinary browser logout preserves only explicit offline grants; human revocation removes all",
       %{conn: conn} do
    human = human_fixture()
    client = create_client!(%{})
    session = oauth_session_conn(conn, human.principal.uid)

    issued =
      get(session, "/oauth/authorize", authorization_request(client.id, "openid offline_access"))

    tokens =
      exchange_public_code(conn, client.id, redirect_query(issued)["code"], pkce_verifier())

    Ankole.BrowserSessions.logout(WebSession.browser_reference(issued))
    assert {:ok, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())

    refreshed =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => tokens["refresh_token"]
      })
      |> json_response(200)

    {:ok, refreshed_claims} =
      Tokens.verify_access(refreshed["access_token"], Tokens.userinfo_audience())

    assert refreshed_claims["sid"] == verify_id_token!(tokens["id_token"], client.id)["sid"]
    {:ok, _} = Ankole.PrincipalsFixtures.disable_principal_fixture(human.principal.uid)

    assert {:error, _} =
             Tokens.verify_access(refreshed["access_token"], Tokens.userinfo_audience())

    assert %{"error" => "invalid_grant"} =
             conn
             |> recycle()
             |> post("/oauth/token", %{
               "grant_type" => "refresh_token",
               "client_id" => client.id,
               "refresh_token" => refreshed["refresh_token"]
             })
             |> json_response(400)
  end

  test "provider policy changes reject existing access, refresh, and authorization codes", %{
    conn: conn
  } do
    human = human_fixture()
    client = create_client!(%{})

    tokens =
      exchange_public_code(
        conn,
        client.id,
        authorize_code!(conn, human.principal.uid, client.id, pkce_verifier()),
        pkce_verifier()
      )

    code = authorize_code!(conn, human.principal.uid, client.id, pkce_verifier())

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "different",
        "lark",
        %{"appID" => "test", "appSecret" => "test"},
        false
      )

    {:ok, _} = OIDC.update_client(client.id, %{allowed_identity_provider_ids: ["different"]})
    assert {:error, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())

    assert %{"error" => "invalid_grant"} =
             conn
             |> recycle()
             |> post("/oauth/token", %{
               "grant_type" => "authorization_code",
               "client_id" => client.id,
               "code" => code,
               "redirect_uri" => @redirect_uri,
               "code_verifier" => pkce_verifier()
             })
             |> json_response(400)

    assert %{"error" => "invalid_grant"} =
             conn
             |> recycle()
             |> post("/oauth/token", %{
               "grant_type" => "refresh_token",
               "client_id" => client.id,
               "refresh_token" => tokens["refresh_token"]
             })
             |> json_response(400)
  end

  test "gateway refresh rejects a disabled Human with invalid_grant", %{conn: conn} do
    {human, _group, client} = gateway_authorization_fixture()
    scope = "openid offline_access ai_gateway.write"
    code = authorize_code!(conn, human.principal.uid, client.id, pkce_verifier(), scope)
    tokens = exchange_public_code(conn, client.id, code, pkce_verifier())
    assert {:ok, _} = disable_principal_fixture(human.principal.uid)

    assert %{"error" => "invalid_grant"} =
             conn
             |> recycle()
             |> post("/oauth/token", %{
               "grant_type" => "refresh_token",
               "client_id" => client.id,
               "refresh_token" => tokens["refresh_token"]
             })
             |> json_response(400)
  end

  test "gateway authorization redirects access_denied after group removal", %{conn: conn} do
    {human, group, client} = gateway_authorization_fixture()
    session = oauth_session_conn(conn, human.principal.uid)

    assert {:ok, :deleted} =
             Ankole.AuthZ.remove_principal_from_group(human.principal.uid, group.id)

    response =
      get(
        session,
        "/oauth/authorize",
        authorization_request(client.id, "openid ai_gateway.write")
      )

    assert redirect_query(response)["error"] == "access_denied"
    refute redirect_query(response)["code"]
  end

  test "gateway authorization redirects access_denied after tenant suspension", %{conn: conn} do
    {human, _group, client} = gateway_authorization_fixture()
    session = oauth_session_conn(conn, human.principal.uid)
    tenant = Repo.get!(Ankole.Tenants.Tenant, Repo.tenant_id!())
    Repo.update!(Ecto.Changeset.change(tenant, suspended_at: DateTime.utc_now(:microsecond)))

    response =
      get(
        session,
        "/oauth/authorize",
        authorization_request(client.id, "openid ai_gateway.write")
      )

    assert redirect_query(response)["error"] == "access_denied"
    refute redirect_query(response)["code"]
  end

  test "select_account uses a held proof explicitly and separates two identities for one Client",
       %{conn: conn, tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    a = human_fixture(%{display_name: "Identity A"})
    b = human_fixture(%{display_name: "Identity B"})
    client = create_client!(%{})
    conn = init_test_session(conn, %{})
    {conn, a_ref} = add_authentication(conn, a.principal)
    {conn, b_ref} = add_authentication(conn, b.principal)

    authorization =
      get(
        conn,
        "/oauth/authorize",
        Map.put(authorization_request(client.id, "openid"), "prompt", "select_account")
      )

    oauth_request = redirect_query(authorization)["oauth_request"]
    assert is_binary(oauth_request)
    refute redirect_query(authorization)["code"]

    page =
      authorization |> recycle() |> get("/sessions/new", %{"oauth_request" => oauth_request})

    assert html_response(page, 200) =~ "entrypoints/auth.tsx"

    assert html_response(page, 200) =~
             ~s(<meta name="ankole-login-tenant-name" content="#{tenant.display_name}">)

    choices =
      page
      |> recycle()
      |> api_get("/api/v2/browser/identity-providers", %{"oauth_request" => oauth_request})

    assert %{"selectAccount" => true, "identities" => identities} =
             api_response(choices, 200)

    assert Enum.sort(Enum.map(identities, & &1["principalUID"])) ==
             Enum.sort([a.principal.uid, b.principal.uid])

    selected =
      choices
      |> recycle()
      |> api_post("/api/v2/browser/sessions/identity-selection", %{
        "oauthRequest" => oauth_request,
        "authenticationRef" => Ankole.BrowserSessions.encode_reference(a_ref)
      })

    assert %{"returnTo" => resume} = api_response(selected, 200)
    issued_a = selected |> recycle() |> get(resume)
    assert is_binary(redirect_query(issued_a)["code"])

    assert selected |> recycle() |> get(resume) |> json_response(400) == %{
             "error" => "invalid_request",
             "error_description" => "authorization request expired or not allowed"
           }

    Repo.put_tenant_id(tenant.id)
    [session_a] = Repo.all(Ankole.OIDC.Session)
    assert session_a.principal_uid == a.principal.uid
    assert session_a.authentication_id == a_ref["id"]

    # Select B through a protected operation; a URL hint cannot change it back to A.
    {:ok, _} =
      Ankole.BrowserSessions.activate(WebSession.browser_reference(issued_a), b_ref, tenant.id)

    issued_b =
      issued_a
      |> recycle()
      |> get(
        "/oauth/authorize",
        authorization_request(client.id, "openid")
        |> Map.put("prompt", "none")
        |> Map.put("authentication_ref", Ankole.BrowserSessions.encode_reference(a_ref))
      )

    assert is_binary(redirect_query(issued_b)["code"])
    Repo.put_tenant_id(tenant.id)
    sessions = Repo.all(Ankole.OIDC.Session)

    assert Enum.sort(Enum.map(sessions, & &1.principal_uid)) ==
             Enum.sort([a.principal.uid, b.principal.uid])

    assert Enum.find(sessions, &(&1.principal_uid == b.principal.uid)).authentication_id ==
             b_ref["id"]
  end

  test "login select_account pins the chosen subject and requires a real authentication", %{
    conn: conn,
    tenant: tenant
  } do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    a = human_fixture()
    b = human_fixture()
    client = create_client!(%{})
    conn = init_test_session(conn, %{})
    {conn, a_ref} = add_authentication(conn, a.principal)
    {conn, _} = add_authentication(conn, b.principal)

    authorization =
      get(
        conn,
        "/oauth/authorize",
        Map.put(authorization_request(client.id, "openid"), "prompt", "login select_account")
      )

    oauth_request = redirect_query(authorization)["oauth_request"]

    selected =
      authorization
      |> recycle()
      |> api_post("/api/v2/browser/sessions/identity-selection", %{
        "oauthRequest" => oauth_request,
        "authenticationRef" => Ankole.BrowserSessions.encode_reference(a_ref)
      })

    assert %{"returnTo" => return_to} = api_response(selected, 200)
    assert return_to =~ "/sessions/new?oauth_request="

    assert {:ok, %{status: :pending, expected_authentication_id: expected}} =
             OIDC.AuthorizationRequests.get(
               WebSession.browser_reference(selected),
               oauth_request
             )

    assert expected == a_ref["id"]
    Repo.put_tenant_id(tenant.id)
    browser = WebSession.browser_reference(selected)

    wrong = %{
      "principal_uid" => b.principal.uid,
      "provider_id" => "lark-main",
      "access_version" => b.principal.access_version,
      "auth_time" => System.system_time(:second)
    }

    assert {:error, :login_subject_mismatch} =
             Ankole.BrowserSessions.authenticate(
               browser,
               :oauth,
               wrong,
               oauth_request_id: oauth_request,
               expected_authentication_id: expected
             )

    {:ok, _} = Ankole.BrowserSessions.revoke(browser, a_ref)

    assert {:error, :login_expired} =
             Ankole.BrowserSessions.authenticate(
               browser,
               :oauth,
               Map.put(wrong, "principal_uid", a.principal.uid),
               oauth_request_id: oauth_request,
               expected_authentication_id: expected
             )
  end

  test "OIDC prompt combinations reject unsupported and contradictory values", %{conn: conn} do
    client = create_client!(%{})

    for prompt <- [
          "none select_account",
          "none login",
          "select_account select_account"
        ] do
      response =
        get(
          recycle(conn),
          "/oauth/authorize",
          Map.put(authorization_request(client.id, "openid"), "prompt", prompt)
        )

      assert redirect_query(response)["error"] == "invalid_request"
    end
  end

  for type <- ["public", "confidential"] do
    @client_type type
    test "#{type} token errors consume presented grants and distinguish Client authentication failures",
         %{
           conn: conn
         } do
      human = human_fixture(%{uid: unique_uid("token-errors")})

      {:ok, %{client: client, client_secret: secret}} =
        OIDC.create_client(
          client_attrs(%{
            type: @client_type,
            redirect_uris: [@redirect_uri, @redirect_uri <> "/second"]
          })
        )

      verifier = pkce_verifier()
      code = authorize_code!(conn, human.principal.uid, client.id, verifier, "openid")

      params = %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "code" => code,
        "code_verifier" => verifier,
        "redirect_uri" => @redirect_uri
      }

      params = if secret, do: Map.delete(params, "client_id"), else: params

      for changed <- [
            %{"code_verifier" => String.duplicate("b", 43)},
            %{"redirect_uri" => @redirect_uri <> "/second"},
            %{"redirect_uri" => "https://unregistered.example/callback"}
          ] do
        code = authorize_code!(conn, human.principal.uid, client.id, verifier, "openid")
        attempt = Map.put(params, "code", code)
        request = recycle(conn)

        request =
          if secret,
            do: put_req_header(request, "authorization", basic(client.id, secret)),
            else: request

        response =
          post(request, "/oauth/token", Map.merge(attempt, changed)) |> json_response(400)

        assert response["error"] == "invalid_grant"
        refute Map.has_key?(response, "access_token")
        retry_request = recycle(conn)

        retry_request =
          if secret,
            do: put_req_header(retry_request, "authorization", basic(client.id, secret)),
            else: retry_request

        assert %{"error" => "invalid_grant"} =
                 retry_request |> post("/oauth/token", attempt) |> json_response(400)
      end

      if secret do
        wrong =
          conn
          |> recycle()
          |> put_req_header("authorization", basic(client.id, "wrong"))
          |> post("/oauth/token", params)

        assert %{"error" => "invalid_client"} = json_response(wrong, 401)
      end

      request = recycle(conn)

      request =
        if secret,
          do: put_req_header(request, "authorization", basic(client.id, secret)),
          else: request

      assert %{"access_token" => token} =
               request |> post("/oauth/token", params) |> json_response(200)

      assert is_binary(token)
    end
  end

  test "logout rejects structured parameters without creating a redirect or revoking a login", %{
    conn: conn
  } do
    human = human_fixture(%{uid: unique_uid("logout-shape")})
    session = oauth_session_conn(conn, human.principal.uid)

    for key <- ~w(id_token_hint client_id post_logout_redirect_uri state),
        value <- [["x"], %{"x" => "y"}] do
      result = session |> recycle() |> post("/oauth/logout", %{key => value})
      assert result.status == 400
      assert get_resp_header(result, "location") == []
    end

    valid = session |> recycle() |> post("/oauth/logout", %{"state" => "one & two"})

    assert URI.decode_query(URI.parse(redirected_to(valid, 303)).query) == %{
             "state" => "one & two"
           }

    assert WebSession.oauth_session(session)["principal_uid"] == human.principal.uid
  end

  test "an unparsed POST body needs a valid CSRF header and the same origin", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("csrf-body")})
    session = oauth_session_conn(conn, human.principal.uid)
    session = %{session | method: "POST", body_params: %Plug.Conn.Unfetched{aspect: :body_params}}
    session = put_private(session, :plug_skip_csrf_protection, false)
    state = WebSession.csrf_state(session)
    assert is_binary(state)
    :ok = Plug.CSRFProtection.load_state(session.secret_key_base, state)
    token = Plug.CSRFProtection.get_csrf_token()
    options = AnkoleWeb.Plugs.BrowserCSRF.init([])
    valid = put_req_header(session, "x-csrf-token", token)
    assert %Plug.Conn{} = AnkoleWeb.Plugs.BrowserCSRF.call(valid, options)

    for request <- [session, put_req_header(valid, "origin", "https://untrusted.example")] do
      assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
        AnkoleWeb.Plugs.BrowserCSRF.call(request, options)
      end
    end

    Plug.CSRFProtection.delete_csrf_token()
  end

  defp add_authentication(conn, principal) do
    conn = WebSession.ensure_browser(conn)

    {:ok, %{browser: browser, authentication: authentication}} =
      Ankole.BrowserSessions.authenticate(
        WebSession.browser_reference(conn),
        :pod,
        %{
          "principal_uid" => principal.uid,
          "provider_id" => "lark-main",
          "external_id" => principal.uid,
          "access_version" => principal.access_version,
          "auth_time" => System.system_time(:second)
        },
        mode: :add
      )

    conn = WebSession.put_authentication(conn, browser, authentication)
    {conn, WebSession.authentication_reference(conn)}
  end

  defp gateway_authorization_fixture do
    human = human_fixture()
    name = "r50-" <> Ecto.UUID.generate()

    assert {:ok, group} =
             Ankole.AuthZ.create_principal_group(%{
               name: name,
               display_name: "Gateway users",
               kind: "static"
             })

    assert {:ok, _} = Ankole.AuthZ.add_principal_to_group(human.principal.uid, group.id)

    assert {:ok, _} =
             Ankole.AIGateway.ProviderConfigs.create_provider(%{
               provider_id: name,
               provider_kind: "openai",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    client =
      create_client!(%{
        scopes: ["openid", "offline_access", "ai_gateway.write"],
        allowed_group_ids: [group.id],
        allowed_models: %{
          "assistant" => %{
            "provider_id" => name,
            "model" => "model",
            "description" => "Gateway model",
            "provider_options" => %{}
          }
        }
      })

    {human, group, client}
  end

  defp authorization_request(client_id, scope) do
    %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => @redirect_uri,
      "scope" => scope,
      "state" => "state-1",
      "code_challenge" => pkce_challenge(pkce_verifier()),
      "code_challenge_method" => "S256"
    }
  end

  defp redirect_query(conn),
    do: conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp create_client!(overrides) do
    {:ok, %{client: client}} = OIDC.create_client(client_attrs(overrides))
    client
  end

  defp client_attrs(overrides) do
    Map.merge(
      %{
        name: "OIDC Client",
        enabled: true,
        type: "public",
        redirect_uris: [@redirect_uri],
        scopes: ["openid", "profile", "email", "offline_access"],
        allowed_group_ids: [],
        allowed_models: %{}
      },
      overrides
    )
  end

  defp authorize_code!(
         conn,
         principal_uid,
         client_id,
         verifier,
         scope \\ "openid profile email offline_access"
       ) do
    authorization =
      conn
      |> recycle()
      |> oauth_session_conn(principal_uid)
      |> get("/oauth/authorize", %{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => @redirect_uri,
        "scope" => scope,
        "state" => "state-1",
        "nonce" => "nonce-1",
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256"
      })

    query =
      authorization
      |> redirected_to(302)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query["state"] == "state-1"
    assert is_binary(query["code"])
    query["code"]
  end

  defp exchange_public_code(conn, client_id, code, verifier) do
    conn
    |> recycle()
    |> post("/oauth/token", %{
      "grant_type" => "authorization_code",
      "client_id" => client_id,
      "redirect_uri" => @redirect_uri,
      "code" => code,
      "code_verifier" => verifier
    })
    |> json_response(200)
  end

  defp oauth_session_conn(conn, principal_uid, auth_time \\ System.system_time(:second)) do
    conn = conn |> init_test_session(%{}) |> WebSession.ensure_browser()
    {:ok, version} = Ankole.Principals.HumanAccess.current_version(principal_uid)

    {:ok, %{browser: browser, authentication: authentication}} =
      Ankole.BrowserSessions.authenticate(
        WebSession.browser_reference(conn),
        :oauth,
        %{
          "principal_uid" => principal_uid,
          "provider_id" => "lark-main",
          "external_id" => principal_uid,
          "access_version" => version,
          "auth_time" => auth_time
        }
      )

    WebSession.put_authentication(conn, browser, authentication)
  end

  defp verify_id_token!(token, audience) do
    {:ok, jwk} = SigningKey.public_jwk()

    claims =
      NativeKernel.jwt_verify_jwk(token, jwk, %{
        algorithms: ["RS256"],
        aud: [audience],
        iss: [OIDCConfig.issuer()],
        required_spec_claims: ["exp", "aud", "iss", "sub"],
        validate_exp: true
      })

    assert is_map(claims)
    claims
  end

  defp jwt_header(token) do
    [encoded | _parts] = String.split(token, ".", parts: 3)
    {:ok, json} = Base.url_decode64(encoded, padding: false)
    Ankole.JSON.decode!(json)
  end

  defp pkce_verifier, do: String.duplicate("a", 43)

  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp basic(client_id, secret), do: "Basic " <> Base.encode64("#{client_id}:#{secret}")
end
