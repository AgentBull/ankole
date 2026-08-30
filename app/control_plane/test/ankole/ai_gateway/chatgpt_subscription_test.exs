defmodule Ankole.AIGateway.ChatGPTSubscriptionTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.Providers

  test "SSE preparation preserves Codex identity, session, forwarded headers, and body rules" do
    runtime =
      runtime(%{
        "request_context" => %{
          "cache_key" => "job-thread-7",
          "affinity_key" => "job-thread-7",
          "downstream_transport" => "sse",
          "headers" => %{
            "originator" => "codex_cli_rs",
            "user-agent" => "codex_cli_rs/0.150.1 (Linux 6.8; x86_64) xterm",
            "x-codex-beta-features" => "feature-a,feature-b",
            "x-codex-turn-metadata" => "turn-meta",
            "x-codex-turn-state" => "turn-state",
            "x-client-request-id" => "request-from-codex",
            "x-responsesapi-include-timing-metrics" => "true",
            "version" => "0.150.1"
          }
        },
        "provider_options" => %{
          "reasoningEffort" => "max",
          "serviceTier" => "priority"
        }
      })

    request = %{
      "model" => "gpt-5.6-sol",
      "input" => [%{"type" => "message", "role" => "user", "content" => "hello"}],
      "stream" => true,
      "include" => [],
      "generate" => false
    }

    assert {:ok, attached_spec} =
             Providers.build_response_request(runtime, request, stream?: true)

    {attempt, spec} = CredentialAttempts.pop(attached_spec)
    assert attempt.runtime == runtime
    assert spec.upstream.url == "https://chatgpt.com/backend-api/codex/responses"
    assert spec.upstream.method == "POST"
    assert spec.upstream.kind == :http_sse

    headers = headers(spec)
    assert headers["authorization"] == "Bearer oauth-access"
    assert headers["chatgpt-account-id"] == "account-stored"
    assert headers["originator"] == "codex_cli_rs"
    assert headers["user-agent"] == "codex_cli_rs/0.150.1 (Linux 6.8; x86_64) xterm"
    assert headers["openai-beta"] == "responses=experimental"
    assert headers["content-type"] == "application/json"
    assert headers["accept"] == "text/event-stream"
    assert headers["connection"] == "Keep-Alive"
    assert headers["session_id"] == "job-thread-7"
    assert headers["x-client-request-id"] == "request-from-codex"
    assert headers["thread-id"] == "job-thread-7"
    assert headers["x-codex-window-id"] == "job-thread-7:0"
    assert headers["x-codex-beta-features"] == "feature-a,feature-b"
    assert headers["x-codex-turn-metadata"] == "turn-meta"
    assert headers["x-codex-turn-state"] == "turn-state"
    assert headers["x-responsesapi-include-timing-metrics"] == "true"
    assert headers["version"] == "0.150.1"

    provider_request = spec.response_context.request
    assert provider_request["store"] == false
    assert provider_request["instructions"] == ""
    assert provider_request["prompt_cache_key"] == "job-thread-7"
    assert provider_request["include"] == ["reasoning.encrypted_content"]
    refute Map.has_key?(provider_request, "generate")
    refute Map.has_key?(provider_request, "previous_response_id")

    assert spec.response_context.provider_options == %{
             "reasoning" => %{"effort" => "max"},
             "service_tier" => "priority"
           }
  end

  test "WebSocket preparation uses the native Codex endpoint and lite marker" do
    runtime =
      runtime(%{
        "request_context" => %{
          "cache_key" => "ws-thread-9",
          "affinity_key" => "ws-thread-9",
          "downstream_transport" => "websocket",
          "headers" => %{}
        },
        "provider_options" => %{"serviceTier" => "fast"}
      })

    request = %{
      "model" => "gpt-5.6-sol",
      "instructions" => "",
      "input" => [],
      "tools" => nil,
      "parallel_tool_calls" => false,
      "client_metadata" => %{
        "ws_request_header_x_openai_internal_codex_responses_lite" => "true"
      }
    }

    assert {:ok, attached_spec} =
             Providers.build_response_request(runtime, request, stream?: true)

    {_attempt, spec} = CredentialAttempts.pop(attached_spec)
    assert spec.upstream.url == "wss://chatgpt.com/backend-api/codex/responses"
    assert spec.upstream.method == "GET"
    assert spec.upstream.kind == :websocket_text

    headers = headers(spec)
    assert headers["openai-beta"] == "responses_websockets=2026-02-06"
    assert headers["session_id"] == "ws-thread-9"
    assert headers["conversation_id"] == "ws-thread-9"
    assert headers["x-openai-internal-codex-responses-lite"] == "true"
    refute Map.has_key?(headers, "connection")
    assert spec.response_context.request["tools"] == nil
    assert spec.response_context.request["parallel_tool_calls"] == false
    assert spec.response_context.provider_options["service_tier"] == "fast"
  end

  test "identity uses provider overrides, then inbound values, then the Codex default pair" do
    provider_override =
      runtime(%{
        "connection_options" => %{
          "base_url" => "https://chatgpt.com/backend-api/codex",
          "access_token" => "oauth-access",
          "account_id" => "account-stored",
          "auth_type" => "oauth",
          "originator" => "operator-origin",
          "user_agent" => "operator-agent/1.0"
        },
        "request_context" =>
          context("provider-priority", %{
            "originator" => "ankole_agent_computer",
            "user-agent" => "ankole_agent_computer/0.150.1 (Linux; x86_64)"
          })
      })

    assert {:ok, attached} =
             Providers.build_response_request(provider_override, %{"input" => []})

    {_attempt, spec} = CredentialAttempts.pop(attached)
    assert headers(spec)["originator"] == "operator-origin"
    assert headers(spec)["user-agent"] == "operator-agent/1.0"

    inbound =
      runtime(%{
        "request_context" =>
          context("inbound-priority", %{
            "originator" => "codex_cli_rs",
            "user-agent" => "codex_cli_rs/0.150.1 (Linux 6.8; x86_64) xterm"
          })
      })

    assert {:ok, attached} = Providers.build_response_request(inbound, %{"input" => []})
    {_attempt, spec} = CredentialAttempts.pop(attached)
    assert headers(spec)["originator"] == "codex_cli_rs"
    assert headers(spec)["user-agent"] == "codex_cli_rs/0.150.1 (Linux 6.8; x86_64) xterm"

    defaults = runtime(%{"request_context" => context("default-priority")})
    assert {:ok, attached} = Providers.build_response_request(defaults, %{"input" => []})
    {_attempt, spec} = CredentialAttempts.pop(attached)
    assert headers(spec)["originator"] == "codex_cli_rs"
    assert String.starts_with?(headers(spec)["user-agent"], "codex_cli_rs/0.150.1 (")
    refute String.contains?(headers(spec)["user-agent"], "openai-")
  end

  test "enterprise access tokens do not send subscription account or Codex identity headers" do
    runtime =
      runtime(%{
        "connection_options" => %{
          "base_url" => "https://chatgpt.com/backend-api/codex",
          "access_token" => "enterprise-access",
          "account_id" => "stored-but-not-sent",
          "auth_type" => "enterprise_access_token"
        },
        "request_context" => context("enterprise-thread")
      })

    assert {:ok, attached} =
             Providers.build_response_request(runtime, %{"input" => []})

    {_attempt, spec} = CredentialAttempts.pop(attached)
    headers = headers(spec)
    assert headers["authorization"] == "Bearer enterprise-access"
    refute Map.has_key?(headers, "chatgpt-account-id")
    refute Map.has_key?(headers, "originator")
    refute Map.has_key?(headers, "user-agent")
  end

  test "enterprise access tokens still require a stored account id" do
    runtime =
      runtime(%{
        "connection_options" => %{
          "base_url" => "https://chatgpt.com/backend-api/codex",
          "access_token" => "enterprise-access",
          "auth_type" => "enterprise_access_token"
        },
        "request_context" => context("enterprise-thread")
      })

    assert {:error, :chatgpt_account_id_required} =
             Providers.build_response_request(runtime, %{"input" => []})
  end

  test "explicit store true and leaked previous_response_id fail before transport" do
    runtime = runtime(%{"request_context" => context("rejection-thread")})

    assert {:error, :chatgpt_subscription_store_forbidden} =
             Providers.build_response_request(runtime, %{"input" => [], "store" => true})

    assert {:error, :chatgpt_subscription_previous_response_id_leaked} =
             Providers.build_response_request(runtime, %{
               "input" => [],
               "previous_response_id" => "resp_should_have_been_expanded"
             })
  end

  defp runtime(overrides) do
    defaults = %{
      "provider_kind" => "chatgpt_subscription",
      "provider_id" => "chatgpt-main",
      "model" => "gpt-5.6-sol",
      "connection_options" => %{
        "base_url" => "https://chatgpt.com/backend-api/codex",
        "access_token" => "oauth-access",
        "account_id" => "account-stored",
        "auth_type" => "oauth"
      },
      "provider_options" => %{},
      "request_context" => context("default-thread")
    }

    Map.merge(defaults, overrides)
  end

  defp context(cache_key, headers \\ %{}) do
    %{
      "cache_key" => cache_key,
      "affinity_key" => cache_key,
      "downstream_transport" => "sse",
      "headers" => headers
    }
  end

  defp headers(spec) do
    Map.new(spec.upstream.headers, fn {name, value} -> {String.downcase(name), value} end)
  end
end
