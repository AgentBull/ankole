defmodule AnkoleWeb.OIDCControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.OIDC
  alias Ankole.OIDC.SigningKey
  alias Ankole.OIDC.Tokens
  alias Ankole.TokenSigning
  alias AnkoleWeb.Session, as: WebSession

  @redirect_uri "https://spa.example.test/callback"
  @origin "https://spa.example.test"

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

  test "discovery and JWKS publish the one RS256 installation key", %{conn: conn} do
    discovery = conn |> get("/.well-known/openid-configuration") |> json_response(200)

    assert discovery["issuer"] == TokenSigning.issuer()
    assert discovery["authorization_endpoint"] == TokenSigning.issuer() <> "/oauth/authorize"
    assert discovery["token_endpoint"] == TokenSigning.issuer() <> "/oauth/token"
    assert discovery["userinfo_endpoint"] == TokenSigning.issuer() <> "/oauth/userinfo"
    assert discovery["jwks_uri"] == TokenSigning.issuer() <> "/.well-known/jwks.json"
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

    assert token_response["expires_in"] in 1..Tokens.access_ttl_seconds()

    assert {:ok,
            %{
              "sub" => principal_uid,
              "client_id" => client_id,
              "subject_type" => "human",
              "token_use" => "access",
              "scope" => "openid profile email offline_access",
              "aud" => ["ankole.oidc_userinfo"]
            } = access_claims} = Tokens.verify_access(access_token, Tokens.userinfo_audience())

    assert principal_uid == human.principal.uid
    assert client_id == client.id
    assert is_binary(access_claims["jti"])
    assert is_integer(access_claims["iat"])
    assert is_integer(access_claims["nbf"])
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

    assert %{"error" => "invalid_grant"} = json_response(replay, 400)
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

  test "authorization code is single-use and a wrong verifier does not consume it", %{conn: conn} do
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

    assert %{"error" => "invalid_request"} = json_response(wrong, 400)

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

    assert %{"error" => "invalid_request"} = json_response(malformed, 400)

    first = exchange_public_code(conn, client.id, code, verifier)
    refute Map.has_key?(first, "refresh_token")

    replay =
      conn
      |> recycle()
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client.id,
        "redirect_uri" => @redirect_uri,
        "code" => code,
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

    assert %{"error" => "invalid_client"} = json_response(basic_with_body_client, 400)

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

  test "shared token endpoint dispatches Console and OIDC refresh by credential shape", %{
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

    console_tokens =
      admin_conn
      |> with_console_csrf()
      |> post("/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
      })
      |> json_response(200)

    console_with_client_credentials =
      admin_conn
      |> with_console_csrf()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => client.id,
        "refresh_token" => console_tokens["refresh_token"]
      })

    assert %{"error" => "invalid_request"} = json_response(console_with_client_credentials, 400)

    oidc_without_client_credentials =
      admin_conn
      |> with_console_csrf()
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "refresh_token" => oidc_tokens["refresh_token"]
      })

    assert %{"error" => "invalid_grant"} = json_response(oidc_without_client_credentials, 400)

    oidc_with_admin_cookie =
      admin_conn
      |> put_req_header("origin", @origin)
      |> post("/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => Ankole.Ecto.UUIDv7.autogenerate(),
        "refresh_token" => oidc_tokens["refresh_token"]
      })

    assert %{"error" => "invalid_client"} = json_response(oidc_with_admin_cookie, 400)

    console_with_oidc_credentials =
      admin_conn
      |> with_console_csrf()
      |> post("/oauth/token", %{
        "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session",
        "client_id" => client.id
      })

    assert %{"error" => "invalid_request"} = json_response(console_with_oidc_credentials, 400)
  end

  test "Console grants require the active session, same Origin, and CSRF", %{conn: conn} do
    {admin_conn, _admin_uid} = active_admin_conn_with_principal(conn)
    grant = %{"grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"}

    missing_origin = post(admin_conn, "/oauth/token", grant)
    assert %{"error" => "invalid_request"} = json_response(missing_origin, 403)

    wrong_origin =
      admin_conn
      |> with_console_csrf()
      |> delete_req_header("origin")
      |> put_req_header("origin", "https://attacker.example")
      |> post("/oauth/token", grant)

    assert %{"error" => %{"code" => "origin_not_allowed"}} = json_response(wrong_origin, 403)

    missing_csrf =
      admin_conn
      |> put_req_header("origin", request_origin(admin_conn))
      |> post("/oauth/token", grant)

    assert %{"error" => "invalid_request"} = json_response(missing_csrf, 403)
  end

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

  defp oauth_session_conn(conn, principal_uid) do
    conn
    |> init_test_session(%{})
    |> WebSession.put_oauth_session(%{
      principal_uid: principal_uid,
      provider_id: "local",
      external_id: principal_uid
    })
  end

  defp verify_id_token!(token, audience) do
    {:ok, jwk} = SigningKey.public_jwk()

    claims =
      NativeKernel.jwt_verify_jwk(token, jwk, %{
        algorithms: ["RS256"],
        aud: [audience],
        iss: [TokenSigning.issuer()],
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

  defp request_origin(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end
end
