defmodule Ankole.AIGateway.GoogleVertexAITest do
  use Ankole.AIGatewayCase

  import Ankole.AIGateway.ResponseFixtures
  import ExUnit.CaptureLog

  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.GoogleServiceAccount
  alias Ankole.AIGateway.Providers
  alias Ankole.Repo

  setup_all do
    %{private_key: :public_key.generate_key({:rsa, 2048, 65_537})}
  end

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok = GoogleServiceAccount.clear_for_test()
    :ok
  end

  test "an operator's service-account key reaches Vertex AI as a cached access token", %{
    private_key: private_key
  } do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    token_uri =
      start_upstream_server(fn request ->
        send(test_pid, {:token_request, request})
        {:json, 200, %{"access_token" => "ya29.minted", "expires_in" => 3599}}
      end)

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200, chat_completion_body(request.body["model"], "meow")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "vertex",
               provider_kind: "google_vertex_ai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "Default",
                     "service_account_key" => key_json(private_key, token_uri)
                   }
                 ]
               },
               connection_options: %{
                 "vertex_location" => "us-central1",
                 "safety_threshold" => "OFF"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "vertex",
               model: "gemini-4-argon"
             })

    request = %{"model" => "primary", "input" => "describe a cat"}
    assert {:ok, %{body: body}} = AIGateway.create_response(agent.uid, request)
    assert get_in(body, ["output", Access.at(0), "content", Access.at(0), "text"]) == "meow"

    assert_receive {:token_request, token_request}
    assert token_request.body["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"

    [header, claims, signature] = String.split(token_request.body["assertion"], ".")
    assert %{"alg" => "RS256"} = decode_part(header)

    assert %{
             "iss" => "ankole@vertex-project.iam.gserviceaccount.com",
             "scope" => "https://www.googleapis.com/auth/cloud-platform",
             "aud" => ^token_uri
           } = decode_part(claims)

    {:RSAPrivateKey, _version, modulus, public_exponent, _d, _p, _q, _e1, _e2, _c, _other} =
      private_key

    assert :public_key.verify(
             header <> "." <> claims,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             {:RSAPublicKey, modulus, public_exponent}
           )

    assert_receive {:gateway_request, upstream}

    assert upstream.path ==
             "projects/vertex-project/locations/us-central1/endpoints/openapi/chat/completions"

    assert upstream.headers["authorization"] == "Bearer ya29.minted"
    assert upstream.body["model"] == "google/gemini-4-argon"

    assert upstream.body["google"]["safety_settings"] ==
             Enum.map(
               ~w(HARM_CATEGORY_HATE_SPEECH HARM_CATEGORY_DANGEROUS_CONTENT HARM_CATEGORY_SEXUALLY_EXPLICIT HARM_CATEGORY_HARASSMENT),
               &%{"category" => &1, "threshold" => "OFF"}
             )

    assert {:ok, _response} = AIGateway.create_response(agent.uid, request)
    assert_receive {:gateway_request, _second}
    refute_receive {:token_request, _request}
  end

  test "a key that Google rejects cools down and the next key serves the request", %{
    private_key: private_key
  } do
    %{principal: agent} = agent_fixture()

    revoked_token_uri =
      start_upstream_server(fn _request -> {:json, 400, %{"error" => "invalid_grant"}} end)

    token_uri =
      start_upstream_server(fn _request ->
        {:json, 200, %{"access_token" => "ya29.second", "expires_in" => 3599}}
      end)

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200, chat_completion_body(request.body["model"], "ok")}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "vertex-pool",
               provider_kind: "google_vertex_ai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "revoked",
                     "label" => "Revoked",
                     "priority" => 0,
                     "service_account_key" => key_json(private_key, revoked_token_uri)
                   },
                   %{
                     "id" => "second",
                     "label" => "Second",
                     "priority" => 1,
                     "service_account_key" => key_json(private_key, token_uri, "second-project")
                   }
                 ]
               },
               connection_options: %{}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "vertex-pool",
               model: "meta/llama-4"
             })

    assert {:ok, _response} =
             AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})

    assert_receive {:gateway_request, upstream}
    assert upstream.headers["authorization"] == "Bearer ya29.second"
    assert upstream.body["model"] == "meta/llama-4"
    refute Map.has_key?(upstream.body, "google")

    assert upstream.path ==
             "projects/second-project/locations/global/endpoints/openapi/chat/completions"

    {:ok, provider} = ProviderConfigs.fetch_provider("vertex-pool")
    entries = ProviderConfigs.projection(provider)["credential_pool"]["entries"]
    revoked = Enum.find(entries, &(&1["id"] == "revoked"))
    assert revoked["status"] == "exhausted"
    assert {:ok, retry_at, _offset} = DateTime.from_iso8601(revoked["retry_at"])
    assert_in_delta DateTime.diff(retry_at, DateTime.utc_now()), 300, 30
    assert Enum.find(entries, &(&1["id"] == "second"))["status"] == "ok"
  end

  test "a token endpoint outage fails the request and leaves the key's health alone", %{
    private_key: private_key
  } do
    %{principal: agent} = agent_fixture()

    token_uri =
      start_upstream_server(fn _request -> {:json, 503, %{"error" => "unavailable"}} end)

    create_single_key_provider!("vertex-outage", key_json(private_key, token_uri))

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "vertex-outage",
               model: "gemini-2.5-flash"
             })

    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 AIGateway.create_response(agent.uid, %{"model" => "primary", "input" => "hello"})
      end)

    assert log =~ "Google service-account token exchange failed"
    refute_receive {:gateway_request, _request}

    {:ok, provider} = ProviderConfigs.fetch_provider("vertex-outage")

    assert [%{"status" => "ok"}] =
             ProviderConfigs.projection(provider)["credential_pool"]["entries"]
  end

  test "resolving the credential inside a transaction exchanges no token", %{
    private_key: private_key
  } do
    test_pid = self()

    token_uri =
      start_upstream_server(fn _request ->
        send(test_pid, :token_request)
        {:json, 400, %{"error" => "invalid_grant"}}
      end)

    provider = create_single_key_provider!("vertex-in-tx", key_json(private_key, token_uri))

    assert {:ok, selected} =
             Repo.transact_top_level(fn -> ProviderConfigs.resolve_credential(provider) end)

    refute Map.has_key?(selected["credential"], "access_token")
    refute_receive :token_request

    {:ok, provider} = ProviderConfigs.fetch_provider("vertex-in-tx")

    assert [%{"status" => "ok"}] =
             ProviderConfigs.projection(provider)["credential_pool"]["entries"]
  end

  test "the token exchange goes through the proxy of the provider row", %{
    private_key: private_key
  } do
    test_pid = self()

    proxy =
      start_upstream_server(fn request ->
        send(test_pid, {:proxied, request.headers["host"]})
        {:json, 200, %{"access_token" => "ya29.proxied", "expires_in" => 3599}}
      end)

    provider =
      create_single_key_provider!(
        "vertex-proxy",
        key_json(private_key, "http://token.vertex.invalid/token"),
        %{"transport" => %{"proxy" => proxy}}
      )

    assert {:ok, selected} = ProviderConfigs.resolve_credential(provider)
    assert selected["credential"]["access_token"] == "ya29.proxied"
    assert_receive {:proxied, "token.vertex.invalid"}
  end

  test "saving a credential rejects anything that is not a usable service-account key", %{
    private_key: private_key
  } do
    valid = key_json(private_key, "https://oauth2.googleapis.com/token")
    assert {:ok, _options} = normalize(valid)

    for {key, reason} <- [
          {"AIzaSy-an-api-key", :invalid_json},
          {Jason.encode!(%{"type" => "authorized_user"}), :not_a_service_account_key},
          {valid |> Jason.decode!() |> Map.delete("project_id") |> Jason.encode!(),
           :missing_project_id},
          {valid |> Jason.decode!() |> Map.put("private_key", "not a pem") |> Jason.encode!(),
           :invalid_private_key}
        ] do
      assert {:error, {:credential_options, {:service_account_key, ^reason}} = rejected} =
               normalize(key)

      assert {"AIGateway provider configuration is invalid: the " <> _detail, []} =
               ProviderConfigs.rejection(rejected)
    end

    for bad_uri <- [
          "ftp://oauth2.googleapis.com/token",
          "https://user:pass@oauth2.googleapis.com/token",
          "http://169.254.169.254/computeMetadata/v1/instance/service-accounts/default/token"
        ] do
      assert {:error, {:credential_options, {:service_account_key, :invalid_token_uri}}} =
               normalize(key_json(private_key, bad_uri))
    end
  end

  test "token exchange blocks private endpoints under ssrf_filter and never follows redirects", %{
    private_key: private_key
  } do
    redirect_uri =
      start_upstream_server(fn _request ->
        {:json, 302, [{"location", "http://169.254.169.254/token"}], %{}}
      end)

    key = key_json(private_key, redirect_uri)

    assert {:error, {:google_token_rejected, "token_uri_" <> _reason}} =
             GoogleServiceAccount.access_token(key, ssrf_filter: true)

    capture_log(fn ->
      assert {:error, {:google_token_transient, "302"}} =
               GoogleServiceAccount.access_token(key, ssrf_filter: false)
    end)
  end

  defp create_single_key_provider!(provider_id, key, connection_options \\ %{}) do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "google_vertex_ai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "service_account_key" => key}]
               },
               connection_options: connection_options
             })

    provider
  end

  defp normalize(key),
    do:
      Providers.normalize_credential_options("google_vertex_ai", %{"service_account_key" => key})

  defp key_json(private_key, token_uri, project_id \\ "vertex-project") do
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, private_key)])

    Jason.encode!(%{
      "type" => "service_account",
      "project_id" => project_id,
      "private_key_id" => "key-#{project_id}",
      "private_key" => pem,
      "client_email" => "ankole@#{project_id}.iam.gserviceaccount.com",
      "token_uri" => token_uri
    })
  end

  defp decode_part(part), do: part |> Base.url_decode64!(padding: false) |> Jason.decode!()
end
