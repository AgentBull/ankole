defmodule Ankole.OIDCLogoutIntegrationTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  alias Ankole.{BrowserSessions, OIDC, Repo, TokenSigning}
  alias Ankole.OIDC.{Logout, LogoutDelivery, SigningKey, Tokens}
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()
    {:ok, _} = Ankole.IdentityProviders.save_provider("local", "local", %{}, true)
    :ok
  end

  test "a real RP receives and verifies the standard logout JWT after durable browser revocation",
       %{conn: conn} do
    parent = self()
    {:ok, jwk} = SigningKey.public_jwk()

    endpoint =
      start_upstream_server(fn request ->
        token = request.body["logout_token"]

        claims =
          Ankole.Kernel.jwt_verify_jwk(token, jwk, %{
            algorithms: ["RS256"],
            iss: [TokenSigning.issuer()],
            validate_exp: true,
            required_spec_claims: ["iss", "aud", "iat", "exp", "jti"]
          })

        send(parent, {:logout, request.headers, claims, token})
        {:json, 200, %{}}
      end)

    {browser, client, tokens} = authorize(conn, endpoint)
    {:ok, claims} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())
    sid = claims["sid"]
    {:ok, _} = BrowserSessions.logout(WebSession.browser_reference(browser))
    assert {:error, _} = Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())
    [delivery] = Repo.all(LogoutDelivery)
    assert delivery.status == :pending
    assert :ok = Logout.deliver(delivery.id)
    assert_receive {:logout, headers, verified, token}, 1000
    assert headers["content-type"] =~ "application/x-www-form-urlencoded"

    assert %{
             "aud" => audience,
             "sid" => ^sid,
             "sub" => subject,
             "events" => %{"http://schemas.openid.net/event/backchannel-logout" => %{}}
           } = verified

    assert audience == client.id
    assert subject == claims["sub"]
    refute Map.has_key?(verified, "nonce")
    [header | _] = String.split(token, ".")

    assert Base.url_decode64!(header, padding: false)
           |> Ankole.JSON.decode!()
           |> Map.fetch!("typ") == "logout+jwt"

    assert Repo.get!(LogoutDelivery, delivery.id).status == :delivered
    assert :ok = Logout.deliver(delivery.id)
    refute_receive {:logout, _, _, _}, 50
  end

  test "failed delivery survives retry and keeps the old sid with a fresh JWT", %{conn: conn} do
    parent = self()
    holder = start_supervised!({Agent, fn -> 503 end})

    endpoint =
      start_upstream_server(fn request ->
        send(parent, {:token, request.body["logout_token"]})
        {:json, Agent.get(holder, & &1), %{}}
      end)

    {browser, _client, _tokens} = authorize(conn, endpoint)
    {:ok, _} = BrowserSessions.logout(WebSession.browser_reference(browser))
    [delivery] = Repo.all(LogoutDelivery)
    assert {:snooze, 30} = Logout.deliver(delivery.id)
    assert_receive {:token, first}
    pending = Repo.get!(LogoutDelivery, delivery.id)
    assert pending.status == :pending
    assert pending.last_error == "HTTP 503"
    Agent.update(holder, fn _ -> 200 end)
    {:ok, _} = Logout.retry(delivery.id)
    assert :ok = Logout.deliver(delivery.id)
    assert_receive {:token, second}
    refute first == second
    first_claims = first |> JOSE.JWT.peek_payload() |> Map.fetch!(:fields)
    second_claims = second |> JOSE.JWT.peek_payload() |> Map.fetch!(:fields)
    assert first_claims["sid"] == second_claims["sid"]
    refute first_claims["jti"] == second_claims["jti"]
    assert Repo.get!(LogoutDelivery, delivery.id).attempt_count == 2
  end

  test "manual retry wakes the stored snoozed job without waiting for its backoff", %{conn: conn} do
    parent = self()
    holder = start_supervised!({Agent, fn -> 503 end})

    endpoint =
      start_upstream_server(fn _ ->
        send(parent, :attempted)
        {:json, Agent.get(holder, & &1), %{}}
      end)

    {browser, _client, _tokens} = authorize(conn, endpoint)
    {:ok, _} = BrowserSessions.logout(WebSession.browser_reference(browser))
    [delivery] = Repo.all(LogoutDelivery)
    assert %{snoozed: 1} = Oban.drain_queue(queue: :default)
    assert_receive :attempted
    job = Repo.get_by!(Oban.Job, worker: "Ankole.OIDC.LogoutWorker")
    assert job.state == "scheduled"
    Agent.update(holder, fn _ -> 200 end)
    assert {:ok, _} = Logout.retry(delivery.id)
    assert %{success: 1} = Oban.drain_queue(queue: :default)
    assert_receive :attempted
    assert Repo.get!(LogoutDelivery, delivery.id).status == :delivered
    assert Repo.get!(Oban.Job, job.id).state == "completed"
  end

  test "deadline stops automatic delivery and manual retry reopens it", %{conn: conn} do
    parent = self()

    endpoint =
      start_upstream_server(fn _ ->
        send(parent, :received)
        {:json, 200, %{}}
      end)

    {browser, _client, _tokens} = authorize(conn, endpoint)
    {:ok, _} = BrowserSessions.logout(WebSession.browser_reference(browser))
    [delivery] = Repo.all(LogoutDelivery)

    delivery
    |> Ecto.Changeset.change(deadline: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:discard, :delivery_deadline} = Logout.deliver(delivery.id)
    refute_receive :received, 50
    assert Repo.get!(LogoutDelivery, delivery.id).status == :failed
    {:ok, _} = Logout.retry(delivery.id)
    assert :ok = Logout.deliver(delivery.id)
    assert_receive :received
  end

  test "RP logout repeats over HTTP after cookie removal and requires CSRF confirmation", %{
    conn: conn
  } do
    endpoint = start_upstream_server(fn _ -> {:json, 200, %{}} end)
    {browser, _client, tokens} = authorize(conn, endpoint)
    server = start_supervised!({Bandit, plug: AnkoleWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    origin = "http://127.0.0.1:#{port}"
    cookie = "_ankole_key=" <> browser.resp_cookies["_ankole_key"].value

    params = %{
      id_token_hint: tokens["id_token"],
      post_logout_redirect_uri: "https://rp.example/signed-out",
      state: "repeat-state"
    }

    Enum.reduce(1..2, cookie, fn attempt, cookie ->
      prepared =
        Req.get!(origin <> "/oauth/logout",
          params: params,
          headers: [cookie: cookie],
          redirect: false
        )

      assert prepared.status == 302
      cookie = response_cookie(prepared, cookie)
      [location] = Req.Response.get_header(prepared, "location")

      id =
        location
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("request")

      page = Req.get!(origin <> location, headers: [cookie: cookie])
      assert page.status == 200
      cookie = response_cookie(page, cookie)
      [_, csrf] = Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, page.body)

      identity =
        Req.get!(origin <> "/.internal-apis/oidc-logout/" <> id, headers: [cookie: cookie])

      assert identity.status == 200
      if attempt == 2, do: assert(is_nil(identity.body["identity"]))

      rejected =
        Req.post!(origin <> "/oauth/logout/confirm",
          headers: [cookie: cookie],
          form: [request: id, action: "confirm"],
          redirect: false
        )

      assert rejected.status == 403

      confirmed =
        Req.post!(origin <> "/oauth/logout/confirm",
          headers: [cookie: cookie, "x-csrf-token": csrf, origin: origin],
          form: [request: id, action: "confirm"],
          redirect: false
        )

      assert confirmed.status == 302

      assert Req.Response.get_header(confirmed, "location") == [
               "https://rp.example/signed-out?state=repeat-state"
             ]

      assert {:error, _} =
               Tokens.verify_access(tokens["access_token"], Tokens.userinfo_audience())

      response_cookie(confirmed, cookie)
    end)

    claims = tokens["id_token"] |> JOSE.JWT.peek_payload() |> Map.fetch!(:fields)

    Repo.get!(Ankole.OIDC.Session, claims["sid"])
    |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -86_401))
    |> Repo.update!()

    assert Req.get!(origin <> "/oauth/logout", params: params, redirect: false).status == 400
  end

  defp response_cookie(response, fallback) do
    case Enum.find(
           Req.Response.get_header(response, "set-cookie"),
           &String.starts_with?(&1, "_ankole_key=")
         ) do
      nil -> fallback
      cookie -> cookie |> String.split(";", parts: 2) |> hd()
    end
  end

  defp authorize(conn, endpoint) do
    human = human_fixture()

    {:ok, %{client: client, client_secret: secret}} =
      OIDC.create_client(%{
        name: "Reference RP",
        enabled: true,
        type: "confidential",
        redirect_uris: ["https://rp.example/callback"],
        post_logout_redirect_uris: ["https://rp.example/signed-out"],
        scopes: ["openid"],
        backchannel_logout_uri: endpoint,
        allow_insecure_local_logout: true
      })

    conn = init_test_session(conn, %{})
    {:ok, conn, flow} = WebSession.begin_login(conn, :oauth, %{})
    {:ok, _} = BrowserSessions.bind_provider(WebSession.browser_reference(conn), flow.id, "local")

    {:ok, conn, _} =
      WebSession.complete_login(conn, flow.id, %{
        "principal_uid" => human.principal.uid,
        "provider_id" => "local",
        "external_id" => human.principal.uid,
        "access_version" => human.principal.access_version,
        "auth_time" => System.system_time(:second)
      })

    verifier = String.duplicate("a", 43)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    issued =
      get(conn, "/oauth/authorize", %{
        "response_type" => "code",
        "client_id" => client.id,
        "redirect_uri" => "https://rp.example/callback",
        "scope" => "openid",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    code =
      issued
      |> redirected_to()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("code")

    tokens =
      build_conn()
      |> put_req_header("authorization", "Basic " <> Base.encode64(client.id <> ":" <> secret))
      |> post("/oauth/token", %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => "https://rp.example/callback",
        "code_verifier" => verifier
      })
      |> json_response(200)

    {issued, client, tokens}
  end
end
