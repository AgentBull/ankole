defmodule Ankole.Pod.AppletAITest do
  use Ankole.AIGatewayCase
  alias Ankole.Pod.Applets.AI
  alias Ankole.AIGateway.Schemas.UsageRecord

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "AI uses the configured Agent's light fallback, attributes usage, and does not apply its token quota" do
    agent = agent_fixture().principal.uid
    test_pid = self()

    upstream =
      start_upstream_server(fn request ->
        send(test_pid, {:applet_ai_request, request})
        {:json, 200, response("completed", "Summary", nil)}
      end)

    configure(agent, upstream)

    {:ok, _} =
      Ankole.AIAgent.TokenQuota.put(agent, %{
        "period_days" => 1,
        "period_start_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "limit_tokens" => 1
      })

    Repo.insert!(
      UsageRecord.changeset(%UsageRecord{}, %{
        subject_uid: agent,
        origin: "agent",
        model: "prior/model",
        input_tokens: 1,
        output_tokens: 0
      })
    )

    assert {:error, {:agent_token_quota_exceeded, _}} =
             Ankole.AIAgent.TokenQuota.ensure_available(agent)

    assert {:ok,
            %{text: "Summary", finishReason: "stop", usage: %{inputTokens: 7, outputTokens: 3}}} =
             AI.generate_text(%{
               "model" => "light",
               "prompt" => "Summarize",
               "system" => "Be concise",
               "effort" => "low"
             })

    assert_receive {:applet_ai_request, %{body: request}}
    assert request["model"] == "gpt-5.5"
    assert request["reasoning"]["effort"] == "low"
    assert request["instructions"] == "Be concise"

    assert [%{subject_uid: ^agent, input_tokens: 7, output_tokens: 3}] =
             Repo.all(from r in UsageRecord, where: r.model == "applet-ai-test/gpt-5.5")
  end

  test "AI returns partial or empty output on length exhaustion" do
    agent = agent_fixture().principal.uid

    configure(
      agent,
      start_upstream_server(fn _ ->
        {:json, 200, response("incomplete", "", %{"reason" => "max_output_tokens"})}
      end)
    )

    assert {:ok, %{text: "", finishReason: "length"}} =
             AI.generate_text(%{"model" => "primary", "prompt" => "Think"})
  end

  test "missing identity, raw models, unavailable profiles and invalid efforts fail before provider dispatch" do
    assert {:error, %{status: 422, code: "ai_not_configured"}} =
             AI.generate_text(%{"model" => "primary", "prompt" => "Hello"})

    agent = agent_fixture().principal.uid
    test_pid = self()

    configure(
      agent,
      start_upstream_server(fn request ->
        send(test_pid, {:unexpected_ai, request})
        {:json, 500, %{}}
      end)
    )

    for model <- ["applet-ai-test/gpt-5.5", "nonexistent-profile", "embedding"] do
      assert {:error, %{status: 422, code: "invalid_model"}} =
               AI.generate_text(%{"model" => model, "prompt" => "Hello"})
    end

    assert {:error, %{status: 422, code: "invalid_effort"}} =
             AI.generate_text(%{"model" => "primary", "prompt" => "Hello", "effort" => "extreme"})

    refute_receive {:unexpected_ai, _}

    Repo.get!(Ankole.Principals.Principal, agent)
    |> Ankole.Principals.Principal.status_changeset(%{status: :disabled})
    |> Repo.update!()

    assert {:error, %{code: "ai_not_configured"}} =
             AI.generate_text(%{"model" => "primary", "prompt" => "Hello"})
  end

  defp configure(agent, upstream) do
    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "applet-ai-test",
        provider_kind: "openai",
        base_url: upstream <> "/v1",
        credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "test"}]},
        connection_options: %{"transport" => %{}}
      })

    {:ok, _} =
      ModelProfiles.put_model_profile(agent, "primary", %{
        provider_id: "applet-ai-test",
        model: "gpt-5.5"
      })

    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.applet.ai_agent_uid", agent)
  end

  defp response(status, text, incomplete),
    do: %{
      "id" => "resp_applet_ai",
      "object" => "response",
      "status" => status,
      "output" => [
        %{
          "id" => "msg_applet_ai",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ],
      "incomplete_details" => incomplete,
      "usage" => %{"input_tokens" => 7, "output_tokens" => 3}
    }
end
