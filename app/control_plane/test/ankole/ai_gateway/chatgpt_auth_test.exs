defmodule Ankole.AIGateway.ChatGPTAuthTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.ChatGPTAuth
  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderRuntime
  alias Ankole.AIGateway.Resolver

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "device login forwards one poll at a time and stores the completed OAuth credential" do
    verifier = String.duplicate("v", 64)
    challenge = pkce_challenge(verifier)

    issuer =
      start_upstream_server(fn request ->
        case {request.method, request.path} do
          {:post, "api/accounts/deviceauth/usercode"} ->
            assert request.body == %{"client_id" => ChatGPTAuth.client_id()}

            {:json, 200,
             %{
               "device_auth_id" => "device-1",
               "usercode" => "ABCD-EFGH",
               "interval" => 2
             }}

          {:post, "api/accounts/deviceauth/token"} ->
            assert request.body == %{
                     "device_auth_id" => "device-1",
                     "user_code" => "ABCD-EFGH"
                   }

            {:json, 200,
             %{
               "authorization_code" => "authorization-code",
               "code_verifier" => verifier,
               "code_challenge" => challenge
             }}

          {:post, "oauth/token"} ->
            assert request.body["grant_type"] == "authorization_code"
            assert request.body["code"] == "authorization-code"
            assert request.body["code_verifier"] == verifier

            assert request.body["redirect_uri"] ==
                     "#{issuer_from_request(request)}/deviceauth/callback"

            {:json, 200,
             oauth_tokens("device-access", "device-refresh", "account-device", "business")}
        end
      end)

    create_chatgpt_provider!("chatgpt-device", issuer)
    # A current-time base keeps the stored credential fresh for the final
    # unpinned resolve_credential call, which must not take the refresh path.
    now = DateTime.utc_now(:second)

    assert {:ok, login} =
             ChatGPTAuth.start_login(
               "chatgpt-device",
               %{"id" => "device-entry", "label" => "Device account"},
               now: now
             )

    assert login["mode"] == "device"
    assert login["verification_url"] == "#{issuer}/codex/device"
    assert login["user_code"] == "ABCD-EFGH"
    assert login["interval"] == 2
    refute inspect(login) =~ "device-access"

    assert {:ok, completed} =
             ChatGPTAuth.poll_login(
               "chatgpt-device",
               login["login_context"],
               now: DateTime.add(now, 2, :second)
             )

    assert completed["status"] == "complete"

    assert %{
             "credential_pool" => %{
               "entries" => [
                 %{
                   "id" => "device-entry",
                   "label" => "Device account",
                   "source" => "device_oauth",
                   "account_id" => "account-device",
                   "plan_type" => "business",
                   "auth_type" => "oauth",
                   "credential_present" => true,
                   "status" => "ok"
                 }
               ]
             }
           } = completed["ai_gateway_provider"]

    assert {:ok, provider} = ProviderConfigs.fetch_provider("chatgpt-device")
    assert {:ok, selected} = ProviderConfigs.resolve_credential(provider)
    assert selected["credential"]["access_token"] == "device-access"
    assert selected["credential"]["refresh_token"] == "device-refresh"
    refute inspect(completed) =~ "device-refresh"
  end

  test "pending device status is stateless and the 15-minute deadline is enforced" do
    issuer =
      start_upstream_server(fn request ->
        case request.path do
          "api/accounts/deviceauth/usercode" ->
            {:json, 200,
             %{"device_auth_id" => "pending-device", "user_code" => "PENDING", "interval" => 3}}

          "api/accounts/deviceauth/token" ->
            {:json, 403, %{"error" => "authorization_pending"}}
        end
      end)

    create_chatgpt_provider!("chatgpt-pending", issuer)
    issued_at = ~U[2026-07-29 09:00:00Z]

    assert {:ok, login} =
             ChatGPTAuth.start_login("chatgpt-pending", %{}, now: issued_at)

    assert {:ok,
            %{
              "status" => "pending",
              "retry_after" => 3,
              "expires_at" => "2026-07-29T09:15:00Z"
            }} =
             ChatGPTAuth.poll_login(
               "chatgpt-pending",
               login["login_context"],
               now: DateTime.add(issued_at, 30, :second)
             )

    assert {:error, :login_expired} =
             ChatGPTAuth.poll_login(
               "chatgpt-pending",
               login["login_context"],
               now: DateTime.add(issued_at, 901, :second)
             )
  end

  test "browser-paste fallback is used only when the device route returns 404" do
    issuer =
      start_upstream_server(fn request ->
        case request.path do
          "api/accounts/deviceauth/usercode" ->
            {:json, 404, %{"error" => "not_found"}}

          "oauth/token" ->
            assert request.body["grant_type"] == "authorization_code"
            assert request.body["redirect_uri"] == "http://localhost:1455/auth/callback"
            {:json, 200, oauth_tokens("browser-access", "browser-refresh", "account-browser")}
        end
      end)

    create_chatgpt_provider!("chatgpt-browser", issuer)
    now = ~U[2026-07-29 10:00:00Z]

    assert {:ok, login} =
             ChatGPTAuth.start_login(
               "chatgpt-browser",
               %{"label" => "Browser account"},
               now: now
             )

    assert login["mode"] == "browser_paste"
    assert login["redirect_uri"] == "http://localhost:1455/auth/callback"
    query = login["authorization_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["scope"] == "openid email profile offline_access"
    assert query["prompt"] == "login"
    assert query["id_token_add_organizations"] == "true"
    assert query["codex_cli_simplified_flow"] == "true"

    callback_url =
      "http://localhost:1455/auth/callback?" <>
        URI.encode_query(%{"code" => "browser-code", "state" => query["state"]})

    assert {:ok, %{"status" => "complete", "ai_gateway_provider" => projection}} =
             ChatGPTAuth.complete_browser_login(
               "chatgpt-browser",
               login["login_context"],
               callback_url,
               now: DateTime.add(now, 30, :second)
             )

    assert [entry] = projection["credential_pool"]["entries"]
    assert entry["account_id"] == "account-browser"
    assert entry["label"] == "Browser account"

    failing_issuer =
      start_upstream_server(fn _request ->
        {:json, 500, %{"error" => %{"code" => "upstream_failed"}}}
      end)

    create_chatgpt_provider!("chatgpt-no-fallback", failing_issuer)

    assert {:error, {:device_login_failed, 500, "upstream_failed"}} =
             ChatGPTAuth.start_login("chatgpt-no-fallback")
  end

  @tag timeout: 10_000
  test "concurrent near-expiry reads consume a rotating refresh token once" do
    {:ok, call_counter} = Agent.start_link(fn -> 0 end)

    issuer =
      start_upstream_server(fn request ->
        assert request.path == "oauth/token"
        assert request.body["grant_type"] == "refresh_token"
        assert request.body["refresh_token"] == "rotating-refresh"
        Agent.update(call_counter, &(&1 + 1))
        Process.sleep(50)

        {:json, 200,
         oauth_tokens(
           future_access_token("fresh-access", "account-singleflight"),
           "rotated-refresh",
           "account-singleflight"
         )}
      end)

    provider =
      create_chatgpt_provider!("chatgpt-singleflight", issuer, [
        oauth_entry(
          "singleflight",
          expired_access_token("stale-access", "account-singleflight"),
          "rotating-refresh",
          "account-singleflight"
        )
      ])

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn -> ProviderRuntime.context(provider) end)
      end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, fn
             {:ok, %{connection: %{"refresh_token" => refresh_token}}} ->
               refresh_token == "rotated-refresh"

             _result ->
               false
           end)

    assert Agent.get(call_counter, & &1) == 1

    assert {:ok, latest} = ProviderConfigs.fetch_provider("chatgpt-singleflight")
    assert {:ok, latest_selected} = ProviderConfigs.resolve_credential(latest)
    assert latest_selected["credential"]["refresh_token"] == "rotated-refresh"
  end

  test "token refresh ignores account and plan aliases outside the Codex auth claim" do
    issuer =
      start_upstream_server(fn request ->
        assert request.path == "oauth/token"

        {:json, 200,
         %{
           "access_token" => future_access_token("alias-access", "account-exact"),
           "refresh_token" => "alias-refresh-rotated",
           "id_token" =>
             jwt(%{
               "https://api.openai.com/auth.chatgpt_account_id" => "dotted-alias",
               "chatgpt_account_id" => "top-level-alias",
               "chatgpt_plan_type" => "top-level-plan",
               "https://api.openai.com/profile" => %{"email" => "profile@example.test"}
             })
         }}
      end)

    create_chatgpt_provider!("chatgpt-exact-claims", issuer, [
      oauth_entry(
        "exact-claims",
        future_access_token("old-access", "account-exact"),
        "alias-refresh",
        "account-exact"
      )
    ])

    assert {:ok, %{"credential" => credential}} =
             ChatGPTAuth.force_refresh("chatgpt-exact-claims", "exact-claims")

    assert credential["account_id"] == "account-exact"
    assert credential["email"] == "profile@example.test"
    refute Map.has_key?(credential, "plan_type")
  end

  test "token refresh does not erase a concurrent quota cooldown" do
    reset_at = DateTime.utc_now(:second) |> DateTime.add(600)

    issuer =
      start_upstream_server(fn _request ->
        {:json, 200,
         oauth_tokens(
           future_access_token("rotated-access", "account-refresh-race"),
           "rotated-refresh",
           "account-refresh-race"
         )}
      end)

    provider =
      create_chatgpt_provider!("chatgpt-refresh-health-race", issuer, [
        oauth_entry(
          "refresh-race",
          future_access_token("old-access", "account-refresh-race"),
          "old-refresh",
          "account-refresh-race"
        )
      ])

    [entry] = provider.credential_pool["entries"]

    :ok =
      CredentialPool.mark_exhausted(
        provider.id,
        entry,
        429,
        %{"x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(reset_at))}
      )

    assert {:ok,
            %{
              "entry" => refreshed_entry,
              "credential" => %{
                "access_token" => rotated_access,
                "refresh_token" => "rotated-refresh"
              }
            }} =
             ChatGPTAuth.force_refresh("chatgpt-refresh-health-race", "refresh-race")

    assert rotated_access =~ "."
    assert refreshed_entry["health_revision"] == entry["health_revision"]

    assert {:ok, projection} =
             ProviderConfigs.get_provider("chatgpt-refresh-health-race")

    assert [%{"status" => "exhausted", "retry_at" => retry_at}] =
             projection["credential_pool"]["entries"]

    assert {:ok, actual, _offset} = DateTime.from_iso8601(retry_at)
    assert DateTime.compare(actual, reset_at) == :eq
  end

  test "permanent refresh failures require reauthentication while 429 keeps the token recoverable" do
    reset_at = DateTime.utc_now(:second) |> DateTime.add(1_200)

    issuer =
      start_upstream_server(fn request ->
        case request.body["refresh_token"] do
          "revoked-refresh" ->
            {:json, 400,
             %{"error" => %{"code" => "refresh_token_invalidated", "type" => "invalid_grant"}}}

          "limited-refresh" ->
            {:json, 429,
             [{"x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(reset_at))}],
             %{"error" => %{"code" => "rate_limit"}}}
        end
      end)

    create_chatgpt_provider!("chatgpt-refresh-failures", issuer, [
      oauth_entry("revoked", "access-revoked", "revoked-refresh", "account-revoked"),
      oauth_entry("limited", "access-limited", "limited-refresh", "account-limited")
    ])

    assert {:error, {:chatgpt_refresh_permanent, "refresh_token_invalidated"}} =
             ChatGPTAuth.force_refresh("chatgpt-refresh-failures", "revoked")

    assert {:error, {:chatgpt_refresh_transient, 429, _headers, "rate_limit"}} =
             ChatGPTAuth.force_refresh("chatgpt-refresh-failures", "limited")

    projection = ProviderConfigs.projection(provider_for!("chatgpt-refresh-failures"))
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["revoked"]["status"] == "dead"
    assert by_id["revoked"]["reauth_required"] == true
    assert by_id["limited"]["status"] == "exhausted"

    assert {:ok, limited_retry_at, _offset} =
             DateTime.from_iso8601(by_id["limited"]["retry_at"])

    assert DateTime.compare(limited_retry_at, reset_at) == :eq

    assert {:ok, _provider} =
             ProviderConfigs.update_credential(
               "chatgpt-refresh-failures",
               "revoked",
               oauth_entry(
                 "revoked",
                 future_access_token("reauth-access", "account-revoked"),
                 "new-refresh",
                 "account-revoked"
               )
             )

    projection = ProviderConfigs.projection(provider_for!("chatgpt-refresh-failures"))
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["revoked"]["status"] == "ok"
    refute Map.get(by_id["revoked"], "reauth_required", false)
  end

  test "model resolution rotates past credentials whose OAuth refresh fails" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    issuer =
      start_upstream_server(fn request ->
        refresh_token = request.body["refresh_token"]
        send(test_pid, {:refresh_attempt, refresh_token})

        case refresh_token do
          "revoked-refresh" ->
            {:json, 400,
             %{"error" => %{"code" => "refresh_token_invalidated", "type" => "invalid_grant"}}}

          "limited-refresh" ->
            {:json, 429, %{"error" => %{"code" => "rate_limit"}}}
        end
      end)

    fresh_entry =
      "fresh"
      |> oauth_entry(
        future_access_token("fresh-access", "account-fresh"),
        "fresh-refresh",
        "account-fresh"
      )
      |> Map.put("last_refresh", DateTime.utc_now(:second) |> DateTime.to_iso8601())

    create_chatgpt_provider!("chatgpt-refresh-rotation", issuer, [
      oauth_entry(
        "revoked",
        expired_access_token("revoked-access", "account-revoked"),
        "revoked-refresh",
        "account-revoked"
      ),
      oauth_entry(
        "limited",
        expired_access_token("limited-access", "account-limited"),
        "limited-refresh",
        "account-limited"
      ),
      fresh_entry
    ])

    assert {:ok, runtime} =
             Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "chatgpt-refresh-rotation/gpt-5.6-codex"
             })

    assert runtime["credential_id"] == "fresh"
    assert runtime["credential_available_count"] == 1
    assert_receive {:refresh_attempt, "revoked-refresh"}
    assert_receive {:refresh_attempt, "limited-refresh"}
    refute_receive {:refresh_attempt, "fresh-refresh"}

    projection = ProviderConfigs.projection(provider_for!("chatgpt-refresh-rotation"))
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["revoked"]["status"] == "dead"
    assert by_id["limited"]["status"] == "exhausted"
    assert by_id["fresh"]["status"] == "ok"
  end

  test "refresh endpoint failures do not exhaust or rotate credentials" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    issuer =
      start_upstream_server(fn request ->
        send(test_pid, {:refresh_attempt, request.body["refresh_token"]})

        {:json, 503, %{"error" => %{"code" => "provider_unavailable", "type" => "server_error"}}}
      end)

    fresh_entry =
      "fresh"
      |> oauth_entry(
        future_access_token("fresh-access", "account-fresh"),
        "fresh-refresh",
        "account-fresh"
      )
      |> Map.put("last_refresh", DateTime.utc_now(:second) |> DateTime.to_iso8601())

    create_chatgpt_provider!("chatgpt-refresh-route-failure", issuer, [
      oauth_entry(
        "unavailable",
        expired_access_token("unavailable-access", "account-unavailable"),
        "unavailable-refresh",
        "account-unavailable"
      ),
      fresh_entry
    ])

    assert {:error, {:chatgpt_refresh_transient, 503, _headers, "provider_unavailable"}} =
             Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "chatgpt-refresh-route-failure/gpt-5.6-codex"
             })

    assert_receive {:refresh_attempt, "unavailable-refresh"}
    refute_receive {:refresh_attempt, _refresh_token}

    projection = ProviderConfigs.projection(provider_for!("chatgpt-refresh-route-failure"))
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["unavailable"]["status"] == "ok"
    assert by_id["fresh"]["status"] == "ok"
  end

  defp create_chatgpt_provider!(provider_id, issuer, entries \\ []) do
    assert {:ok, provider} = create_chatgpt_provider(provider_id, issuer, entries)
    provider
  end

  defp create_chatgpt_provider(provider_id, issuer, entries) do
    ProviderConfigs.create_provider(%{
      "provider_id" => provider_id,
      "provider_kind" => "chatgpt_subscription",
      "connection_options" => %{"auth_issuer" => issuer},
      "credential_pool" => %{"entries" => entries}
    })
  end

  defp provider_for!(provider_id) do
    {:ok, provider} = ProviderConfigs.fetch_provider(provider_id)
    provider
  end

  defp oauth_entry(id, access_token, refresh_token, account_id) do
    %{
      "id" => id,
      "label" => id,
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "id_token" => id_token(account_id),
      "account_id" => account_id,
      "auth_type" => "oauth",
      "last_refresh" => "2026-07-01T00:00:00Z"
    }
  end

  defp oauth_tokens(access_token, refresh_token, account_id, plan_type \\ "enterprise") do
    %{
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "id_token" => id_token(account_id, plan_type)
    }
  end

  defp id_token(account_id, plan_type \\ "enterprise") do
    jwt(%{
      "email" => "#{account_id}@example.test",
      "https://api.openai.com/auth" => %{
        "chatgpt_account_id" => account_id,
        "chatgpt_plan_type" => plan_type
      }
    })
  end

  defp expired_access_token(label, account_id) do
    jwt(%{
      "sub" => label,
      "exp" => DateTime.utc_now() |> DateTime.add(-60) |> DateTime.to_unix(),
      "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
    })
  end

  defp future_access_token(label, account_id) do
    jwt(%{
      "sub" => label,
      "exp" => DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.to_unix(),
      "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
    })
  end

  defp jwt(payload) do
    [
      Base.url_encode64(~s({"alg":"none"}), padding: false),
      payload |> Ankole.JSON.encode!() |> Base.url_encode64(padding: false),
      Base.url_encode64("signature", padding: false)
    ]
    |> Enum.join(".")
  end

  defp pkce_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  defp issuer_from_request(request) do
    uri = URI.parse(request.url)
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end
end
