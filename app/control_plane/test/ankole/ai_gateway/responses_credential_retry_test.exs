defmodule Ankole.AIGateway.ResponsesCredentialRetryTest do
  use Ankole.AIGatewayCase

  import Ankole.AIGateway.ResponseFixtures

  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.CredentialPool

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "a retryable provider failure is attributed to its credential and rotates within the row" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    reset_at = DateTime.utc_now(:second) |> DateTime.add(600)

    base_url =
      start_upstream_server(fn request ->
        authorization = request.headers["authorization"]
        send(test_pid, {:pool_attempt, authorization})

        case authorization do
          "Bearer sk-first" ->
            {:json, 429,
             [{"x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(reset_at))}],
             %{"error" => %{"code" => "rate_limited", "message" => "first key is limited"}}}

          "Bearer sk-second" ->
            {:json, 200,
             %{
               "id" => "resp_pool_rotation",
               "object" => "response",
               "status" => "completed",
               "output" => [],
               "usage" => %{}
             }}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-pool-rotation",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               },
               connection_options: %{
                 "transport" => %{}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-pool-rotation",
               model: "gpt-5.5"
             })

    assert {:ok, %{body: %{"id" => "resp_pool_rotation"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello"
             })

    assert_receive {:pool_attempt, "Bearer sk-first"}
    assert_receive {:pool_attempt, "Bearer sk-second"}
    refute_receive {:pool_attempt, _authorization}

    assert {:ok, projection} = ProviderConfigs.get_provider("openai-pool-rotation")
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "exhausted"
    assert by_id["first"]["provider_status"] == 429
    assert by_id["first"]["last_error_code"] == "rate_limited"
    assert by_id["second"]["status"] == "ok"
    assert by_id["first"]["request_count"] == 1
    assert by_id["second"]["request_count"] == 1
  end

  test "route failures retry the same credential once and leave the pool usable" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        authorization = request.headers["authorization"]
        input = request.body["input"]
        send(test_pid, {:route_attempt, input, authorization})

        case input do
          "second request" ->
            {:json, 200,
             %{
               "id" => "resp_after_route_failure",
               "object" => "response",
               "status" => "completed",
               "output" => [],
               "usage" => %{}
             }}

          "first request" ->
            {:json, 503,
             %{"error" => %{"code" => "provider_unavailable", "message" => "route unavailable"}}}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-route-retry",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-route-retry",
               model: "gpt-5.5"
             })

    assert {:error,
            %Ankole.AIGateway.ProviderFailure{
              kind: :status_rejected,
              provider_status: 503,
              provider_body: %{
                "error" => %{
                  "code" => "provider_unavailable",
                  "message" => "route unavailable"
                }
              }
            }} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "first request"},
               credential_retry_base_ms: 100,
               credential_retry_jitter: & &1,
               credential_retry_sleep: fn milliseconds ->
                 send(test_pid, {:credential_retry_delay, milliseconds})
               end
             )

    assert_receive {:route_attempt, "first request", "Bearer sk-first"}
    assert_receive {:credential_retry_delay, 100}
    assert_receive {:route_attempt, "first request", "Bearer sk-first"}
    refute_receive {:route_attempt, "first request", _authorization}
    refute_receive {:credential_retry_delay, _milliseconds}

    assert {:ok, projection} = ProviderConfigs.get_provider("openai-route-retry")
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first"]["status"] == "ok"
    assert by_id["second"]["status"] == "ok"

    assert {:ok, %{body: %{"id" => "resp_after_route_failure"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "second request"
             })

    assert_receive {:route_attempt, "second request", "Bearer sk-first"}
    refute_receive {:route_attempt, "second request", _authorization}
  end

  test "ChatGPT Cloudflare challenges preserve the safe header and fail with operator guidance" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 403, [{"cf-mitigated", "challenge"}],
         %{"error" => %{"code" => "forbidden", "message" => "challenge"}}}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-cloudflare-challenge",
               provider_kind: "chatgpt_subscription",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "enterprise",
                     "label" => "Enterprise",
                     "access_token" => "access-token",
                     "account_id" => "account-id",
                     "auth_type" => "enterprise_access_token"
                   }
                 ]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "chatgpt-cloudflare-challenge",
               model: "gpt-5.6-sol"
             })

    assert {:error,
            %Ankole.AIGateway.ProviderFailure{
              kind: :other,
              code: "chatgpt_cloudflare_challenge",
              provider_status: 403,
              provider_headers: [{"cf-mitigated", "challenge"}],
              retryable: false
            } = error} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "hello"
             })

    assert error.message =~ "originator and User-Agent"
    assert_receive {:gateway_request, request}
    assert request.path == "responses"
    refute_receive {:gateway_request, _request}

    assert {:ok, projection} =
             ProviderConfigs.get_provider("chatgpt-cloudflare-challenge")

    assert [entry] = projection["credential_pool"]["entries"]
    assert entry["status"] == "ok"
  end

  test "Jina multi-URL fetch does not reuse a credential cooled by an earlier URL" do
    %{principal: agent} = agent_fixture()
    reset_at = DateTime.utc_now(:second) |> DateTime.add(600) |> DateTime.to_unix()

    base_url =
      start_recording_upstream(self(), fn request ->
        case request.headers["authorization"] do
          "Bearer first-key" ->
            {:json, 429, [{"x-codex-primary-reset-at", Integer.to_string(reset_at)}],
             %{"error" => %{"code" => "rate_limit"}}}

          "Bearer second-key" ->
            {:json, 200,
             %{
               "data" => %{
                 "url" => request.body["url"],
                 "title" => "Fetched",
                 "content" => request.body["url"]
               }
             }}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-reader-pool",
               provider_kind: "jina_reader",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "first-key"},
                   %{"id" => "second", "label" => "Second", "api_key" => "second-key"}
                 ]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, %{body: %{"success" => true, "results" => results}}} =
             AIGateway.create_web_fetch(
               agent.uid,
               %{
                 "model" => "jina-reader-pool/default",
                 "urls" => ["https://example.com/one", "https://example.com/two"]
               },
               credential_retry_base_ms: 0,
               credential_retry_jitter: &Function.identity/1
             )

    assert Enum.map(results, & &1["url"]) == [
             "https://example.com/one",
             "https://example.com/two"
           ]

    assert_receive {:gateway_request, %{headers: %{"authorization" => "Bearer first-key"}}}
    assert_receive {:gateway_request, %{headers: %{"authorization" => "Bearer second-key"}}}
    assert_receive {:gateway_request, %{headers: %{"authorization" => "Bearer second-key"}}}
    refute_receive {:gateway_request, _request}, 100
  end

  test "a single-entry pool retries once and then preserves a non-quota failure" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:single_pool_attempt, request.headers["authorization"]})

        {:json, 503,
         %{"error" => %{"code" => "provider_unavailable", "message" => "still unavailable"}}}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-single-retry",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"id" => "only", "label" => "Only", "api_key" => "sk-only"}]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-single-retry",
               model: "gpt-5.5"
             })

    assert {:error,
            %Ankole.AIGateway.ProviderFailure{
              kind: :status_rejected,
              provider_status: 503,
              provider_body: %{
                "error" => %{
                  "code" => "provider_unavailable",
                  "message" => "still unavailable"
                }
              }
            }} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               credential_retry_base_ms: 0,
               credential_retry_jitter: & &1
             )

    assert_receive {:single_pool_attempt, "Bearer sk-only"}
    assert_receive {:single_pool_attempt, "Bearer sk-only"}
    refute_receive {:single_pool_attempt, _authorization}
  end

  test "one usable credential retries once and preserves a non-quota failure" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:single_usable_attempt, request.headers["authorization"]})

        {:json, 503,
         %{"error" => %{"code" => "provider_unavailable", "message" => "still unavailable"}}}
      end)

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-single-usable-retry",
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{"id" => "dead", "label" => "Dead", "api_key" => "sk-dead"},
                   %{"id" => "only", "label" => "Only usable", "api_key" => "sk-only"}
                 ]
               },
               connection_options: %{"transport" => %{}}
             })

    dead_entry = Enum.find(provider.credential_pool["entries"], &(&1["id"] == "dead"))
    :ok = CredentialPool.mark_dead(provider.id, dead_entry)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-single-usable-retry",
               model: "gpt-5.5"
             })

    assert {:error,
            %Ankole.AIGateway.ProviderFailure{
              kind: :status_rejected,
              provider_status: 503,
              provider_body: %{
                "error" => %{
                  "code" => "provider_unavailable",
                  "message" => "still unavailable"
                }
              }
            }} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "hello"},
               credential_retry_base_ms: 0,
               credential_retry_jitter: & &1
             )

    assert_receive {:single_usable_attempt, "Bearer sk-only"}
    assert_receive {:single_usable_attempt, "Bearer sk-only"}
    refute_receive {:single_usable_attempt, _authorization}
  end

  test "route and provider endpoint failures retry once without changing credential health" do
    %{principal: agent} = agent_fixture()

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-route-failure-classification",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               }
             })

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "openai-route-failure-classification/gpt-5.5"
             })

    context = %{
      runtime: runtime,
      build: fn _runtime, _request -> {:ok, %{marker: :same_request}} end,
      request: %{},
      attempt_number: 0,
      attempted_ids: MapSet.new(),
      route_retry_used?: false,
      refresh_used?: false
    }

    reasons = [
      %Ankole.AIGateway.ProviderFailure{
        kind: :status_rejected,
        provider_status: 502,
        provider_body: %{},
        provider_headers: []
      },
      %Ankole.AIGateway.ProviderFailure{
        kind: :status_rejected,
        provider_status: 503,
        provider_body: %{},
        provider_headers: []
      },
      %Ankole.AIGateway.ProviderFailure{
        kind: :status_rejected,
        provider_status: 504,
        provider_body: %{},
        provider_headers: []
      },
      %{"code" => "connect_timeout", "stage" => "connect"},
      %{"code" => "upstream_read_failed", "stage" => "read"},
      :stream_aborted
    ]

    retry_opts = [
      credential_retry_base_ms: 0,
      credential_retry_jitter: &Function.identity/1
    ]

    for reason <- reasons do
      assert {:retry, retried, %{marker: :same_request}, 0} =
               CredentialAttempts.plan_retry(
                 context,
                 %{marker: :same_request},
                 reason,
                 retry_opts
               )

      assert retried.runtime["credential_id"] == runtime["credential_id"]
      assert retried.route_retry_used?

      assert {:stop, ^reason, ^retried} =
               CredentialAttempts.plan_retry(
                 retried,
                 %{marker: :same_request},
                 reason,
                 retry_opts
               )
    end

    provider_failure =
      %Ankole.AIGateway.ProviderFailure{
        kind: :status_rejected,
        provider_status: 500,
        provider_body: %{"error" => %{"code" => "server_is_overloaded"}},
        provider_headers: []
      }

    assert {:stop, ^provider_failure, ^context} =
             CredentialAttempts.plan_retry(
               context,
               %{marker: :same_request},
               provider_failure,
               retry_opts
             )

    statuses = CredentialPool.statuses(provider.id, provider.credential_pool["entries"])
    assert statuses["first"]["status"] == "ok"
    assert statuses["second"]["status"] == "ok"
  end

  test "credential rotation does not reset the request route retry budget" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-route-retry-budget",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               }
             })

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "openai-route-retry-budget/gpt-5.5"
             })

    context = %{
      runtime: runtime,
      build: fn _runtime, _request -> {:ok, %{marker: :same_request}} end,
      request: %{},
      attempt_number: 1,
      attempted_ids: MapSet.new(),
      route_retry_used?: true,
      refresh_used?: false
    }

    retry_opts = [
      credential_retry_base_ms: 0,
      credential_retry_jitter: &Function.identity/1
    ]

    unauthorized =
      %Ankole.AIGateway.ProviderFailure{
        kind: :status_rejected,
        provider_status: 401,
        provider_body: %{"error" => %{"code" => "unauthorized"}},
        provider_headers: []
      }

    assert {:retry, rotated, %{marker: :same_request}, 0} =
             CredentialAttempts.plan_retry(
               context,
               %{marker: :same_request},
               unauthorized,
               retry_opts
             )

    assert rotated.runtime["credential_id"] != runtime["credential_id"]
    assert rotated.route_retry_used?

    route_failure = %Ankole.AIGateway.ProviderFailure{
      kind: :status_rejected,
      provider_status: 503,
      provider_body: %{},
      provider_headers: []
    }

    assert {:stop, ^route_failure, ^rotated} =
             CredentialAttempts.plan_retry(
               rotated,
               %{marker: :same_request},
               route_failure,
               retry_opts
             )
  end

  test "unattributed failures mark no credential and stop after one pool lap" do
    %{principal: agent} = agent_fixture()

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-unattributed-retry",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [
                   %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
                   %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
                 ]
               }
             })

    assert {:ok, runtime} =
             Ankole.AIGateway.Resolver.resolve_request_model(agent.uid, "llm", %{
               "model" => "openai-unattributed-retry/gpt-5.5"
             })

    context = %{
      runtime: Map.delete(runtime, "credential_id"),
      build: fn _runtime, _request -> {:ok, %{}} end,
      request: %{},
      attempt_number: 0,
      attempted_ids: MapSet.new(),
      route_retry_used?: false,
      refresh_used?: false
    }

    reason = %Ankole.AIGateway.ProviderFailure{
      kind: :status_rejected,
      provider_status: 401,
      provider_body: %{"error" => %{"code" => "unauthorized"}},
      provider_headers: []
    }

    retry_opts = [
      credential_retry_base_ms: 0,
      credential_retry_jitter: &Function.identity/1
    ]

    assert {:retry, first_retry, %{}, 0} =
             CredentialAttempts.plan_retry(context, %{}, reason, retry_opts)

    first_retry = update_in(first_retry.runtime, &Map.delete(&1, "credential_id"))

    assert {:retry, second_retry, %{}, 0} =
             CredentialAttempts.plan_retry(first_retry, %{}, reason, retry_opts)

    second_retry = update_in(second_retry.runtime, &Map.delete(&1, "credential_id"))

    assert {:stop, ^reason, ^second_retry} =
             CredentialAttempts.plan_retry(second_retry, %{}, reason, retry_opts)

    statuses =
      CredentialPool.statuses(
        provider.id,
        provider.credential_pool["entries"]
      )

    assert statuses["first"]["status"] == "ok"
    assert statuses["second"]["status"] == "ok"
  end
end
