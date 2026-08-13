defmodule Ankole.AIGateway.ChatGPTSubscriptionRealLLMTest do
  @moduledoc """
  Real ChatGPT subscription verification through AIGateway.

  Run with:

      ANKOLE_REAL_LLM_E2E=1 \
      ANKOLE_CHATGPT_AUTH_JSON='...' \
      mix test --only chatgpt_subscription_real_llm

  The pool-switch test also requires `ANKOLE_CHATGPT_AUTH_JSON_SECONDARY`.
  Environment values must use the Codex auth JSON shape and are never printed.
  """

  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.CredentialPool

  @moduletag :real_llm
  @moduletag :chatgpt_subscription_real_llm
  @moduletag timeout: 300_000

  @model System.get_env("ANKOLE_CHATGPT_MODEL", "gpt-5.6-sol")

  setup do
    %{principal: agent} = agent_fixture()
    provider_id = "chatgpt-real-#{Ecto.UUID.generate()}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "chatgpt_subscription",
               credential_pool: %{
                 "entries" => [
                   credential_from_env!("ANKOLE_CHATGPT_AUTH_JSON", "primary-real")
                 ]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: @model,
               provider_options: %{"reasoningEffort" => "high"}
             })

    %{agent: agent, provider_id: provider_id}
  end

  test "two turns replay encrypted reasoning through the subscription provider", %{agent: agent} do
    request = %{
      "model" => "primary",
      "stream" => true,
      "reasoning" => %{"effort" => "high", "summary" => "auto"},
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "Remember the marker ANKOLE_SUBSCRIPTION_REASONING_729 and reply briefly."
            }
          ]
        }
      ]
    }

    {_events, first} = stream!(agent, request)
    assert first.terminal_error == nil

    assert Enum.any?(first.public_items, fn
             %{"type" => "reasoning", "encrypted_content" => encrypted}
             when is_binary(encrypted) and encrypted != "" ->
               true

             _item ->
               false
           end)

    follow_up =
      Map.put(
        request,
        "input",
        request["input"] ++
          first.public_items ++
          [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [
                %{
                  "type" => "input_text",
                  "text" => "What exact marker did I ask you to remember?"
                }
              ]
            }
          ]
      )

    {_events, second} = stream!(agent, follow_up)
    assert second.terminal_error == nil
    assert output_text(second.public_items) =~ "ANKOLE_SUBSCRIPTION_REASONING_729"
  end

  test "the main agent path receives a real function call", %{agent: agent} do
    request = %{
      "model" => "primary",
      "stream" => true,
      "input" => "Call subscription_marker exactly once with marker ANKOLE_MAIN_TOOL_729.",
      "tools" => [
        %{
          "type" => "function",
          "name" => "subscription_marker",
          "description" => "Records one exact verification marker.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"marker" => %{"type" => "string"}},
            "required" => ["marker"],
            "additionalProperties" => false
          },
          "strict" => true
        }
      ],
      "tool_choice" => %{"type" => "function", "name" => "subscription_marker"}
    }

    {_events, outcome} = stream!(agent, request)
    assert outcome.terminal_error == nil

    assert [call] =
             Enum.filter(
               outcome.public_items,
               &(&1["type"] == "function_call" and &1["name"] == "subscription_marker")
             )

    assert %{"marker" => "ANKOLE_MAIN_TOOL_729"} = Ankole.JSON.decode!(call["arguments"])
  end

  test "a cooled first account causes the second account to complete the request", %{
    agent: agent
  } do
    provider_id = "chatgpt-real-pool-#{Ecto.UUID.generate()}"

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "chatgpt_subscription",
               credential_pool: %{
                 "entries" => [
                   credential_from_env!("ANKOLE_CHATGPT_AUTH_JSON", "first-real"),
                   credential_from_env!(
                     "ANKOLE_CHATGPT_AUTH_JSON_SECONDARY",
                     "second-real"
                   )
                 ]
               }
             })

    reset_at = DateTime.utc_now(:second) |> DateTime.add(600)
    first_entry = Enum.find(provider.credential_pool["entries"], &(&1["id"] == "first-real"))

    :ok =
      CredentialPool.mark_exhausted(
        provider.id,
        first_entry,
        429,
        %{"x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(reset_at))},
        %{"code" => "verification_cooldown"}
      )

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: @model,
               provider_options: %{"reasoningEffort" => "medium"}
             })

    {_events, outcome} =
      stream!(agent, %{
        "model" => "primary",
        "stream" => true,
        "input" => "Reply exactly ANKOLE_SECOND_CREDENTIAL_729."
      })

    assert outcome.terminal_error == nil
    assert output_text(outcome.public_items) =~ "ANKOLE_SECOND_CREDENTIAL_729"

    assert {:ok, projection} = ProviderConfigs.get_provider(provider_id)
    by_id = Map.new(projection["credential_pool"]["entries"], &{&1["id"], &1})
    assert by_id["first-real"]["status"] == "exhausted"
    assert by_id["first-real"]["request_count"] == 0
    assert by_id["second-real"]["request_count"] == 1
  end

  defp stream!(agent, request) do
    {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
    collect_events(stream, [])
  end

  defp collect_events(stream, events) do
    case AIGateway.read_response_stream(stream, 1) do
      :ok -> await_batch(stream, events, 180_000)
      {:error, _reason} -> await_batch(stream, events, 1_000)
    end
  end

  defp await_batch(stream, events, timeout) do
    receive do
      {:ai_gateway_response_stream, _ref, :events, batch, :continue} ->
        collect_events(stream, events ++ batch)

      {:ai_gateway_response_stream, _ref, :events, batch, {:terminal, outcome}} ->
        {events ++ batch, outcome}
    after
      timeout -> raise "real ChatGPT subscription stream ended without a terminal event"
    end
  end

  defp output_text(items) do
    items
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.flat_map(&List.wrap(&1["content"]))
    |> Enum.map(&(&1["text"] || ""))
    |> Enum.join(" ")
  end

  defp credential_from_env!(name, id) do
    encoded =
      System.get_env(name) ||
        raise "#{name} is required; ChatGPT subscription verification is unverified"

    auth =
      case Ankole.JSON.decode(encoded) do
        {:ok, %{} = value} -> value
        _error -> raise "#{name} must contain valid Codex auth JSON; verification is unverified"
      end

    tokens =
      case Map.get(auth, "tokens") do
        %{} = value -> value
        _value -> raise "#{name} has no tokens object; verification is unverified"
      end

    %{
      "id" => id,
      "label" => id,
      "source" => "real_e2e_fixture",
      "access_token" => required_token!(tokens, "access_token", name),
      "refresh_token" => required_token!(tokens, "refresh_token", name),
      "id_token" => required_token!(tokens, "id_token", name),
      "account_id" => required_token!(tokens, "account_id", name),
      "last_refresh" => Map.get(auth, "last_refresh"),
      "auth_type" => "oauth"
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp required_token!(tokens, key, env_name) do
    case Map.get(tokens, key) do
      value when is_binary(value) and value != "" -> value
      _value -> raise "#{env_name} has no #{key}; verification is unverified"
    end
  end
end
