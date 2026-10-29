defmodule Ankole.Pod.AppletAITest do
  use Ankole.AIGatewayCase
  alias Ankole.Pod.{Pages, Applets.AI, Applets.Capabilities}
  alias Ankole.AIGateway.Schemas.UsageRecord

  setup do
    :ok
  end

  test "Applet text keeps original whitespace and Provider citation bytes" do
    agent = agent_fixture().principal.uid
    page = applet(agent)
    text = "\n  first\nsecond " <> <<0xE200::utf8>> <> "cite" <> <<0xE201::utf8>> <> "\n"

    configure(
      agent,
      start_upstream_server(fn _ -> {:json, 200, response("completed", text, nil)} end)
    )

    assert {:ok, %{text: ^text}} =
             AI.generate_text(page, %{"model" => "primary", "prompt" => "Write"})
  end

  test "AI uses the creator Agent profile and quota when a Human invokes the Applet" do
    agent = agent_fixture().principal.uid
    page = applet(agent)
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
        "limit_tokens" => 100
      })

    assert {:ok, _record} =
             Ankole.Ash.create(UsageRecord, :record_round, %{
               subject_uid: agent,
               origin: "agent",
               model: "prior/model",
               input_tokens: 1,
               output_tokens: 0
             })

    assert :ok = Ankole.AIAgent.TokenQuota.ensure_available(agent)

    assert {:ok,
            %{
              "text" => "Summary",
              "finishReason" => "stop",
              "usage" => %{"inputTokens" => 7, "outputTokens" => 3}
            }} =
             Capabilities.call(
               %{"applet" => %{"pageId" => page.id}, "method" => "POST"},
               viewer(page),
               "ai.generateText",
               [
                 %{
                   "model" => "light",
                   "prompt" => "Summarize",
                   "system" => "Be concise",
                   "effort" => "low"
                 }
               ]
             )

    assert_receive {:applet_ai_request, %{body: request}}
    assert request["model"] == "gpt-5.5"
    assert request["reasoning"]["effort"] == "low"
    assert request["instructions"] == "Be concise"

    assert [%{subject_uid: ^agent, input_tokens: 7, output_tokens: 3}] =
             Repo.all(from(r in UsageRecord, where: r.model == "applet-ai-test/gpt-5.5"))

    {:ok, _} =
      Ankole.AIAgent.TokenQuota.put(agent, %{
        "period_days" => 1,
        "period_start_at" =>
          DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3600, :second)),
        "limit_tokens" => 1
      })

    assert {:error, %{status: 429, code: "agent_token_quota_exceeded"}} =
             Capabilities.call(
               %{"applet" => %{"pageId" => page.id}, "method" => "POST"},
               viewer(page),
               "ai.generateText",
               [%{"model" => "light", "prompt" => "Over quota"}]
             )

    refute_receive {:applet_ai_request, _}
  end

  test "AI returns partial or empty output on length exhaustion" do
    agent = agent_fixture().principal.uid
    page = applet(agent)

    configure(
      agent,
      start_upstream_server(fn _ ->
        {:json, 200, response("incomplete", "", %{"reason" => "max_output_tokens"})}
      end)
    )

    assert {:ok, %{text: "", finishReason: "length"}} =
             AI.generate_text(page, %{"model" => "primary", "prompt" => "Think"})
  end

  test "missing identity, raw models, unavailable profiles and invalid efforts fail before provider dispatch" do
    {:ok, page} = Pages.create(actor_fixture(human_fixture().principal.uid), %{type: "applet"})

    assert {:error, %{status: 422, code: "ai_not_configured"}} =
             AI.generate_text(page, %{"model" => "primary", "prompt" => "Hello"})

    agent = agent_fixture().principal.uid
    page = applet(agent)
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
               AI.generate_text(page, %{"model" => model, "prompt" => "Hello"})
    end

    assert {:error, %{status: 422, code: "invalid_effort"}} =
             AI.generate_text(page, %{
               "model" => "primary",
               "prompt" => "Hello",
               "effort" => "extreme"
             })

    refute_receive {:unexpected_ai, _}

    {:ok, _} = Ankole.PrincipalsFixtures.disable_principal_fixture(agent)

    assert {:error, %{code: "ai_not_configured"}} =
             AI.generate_text(page, %{"model" => "primary", "prompt" => "Hello"})
  end

  defp applet(agent) do
    owner = human_fixture().principal.uid
    {:ok, parent} = Pages.create(actor_fixture(owner), %{private_owner_uid: owner})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner, parent.id, %{
        grants: [%{principal_uid: agent, role: "edit"}]
      })

    {:ok, page} = Pages.create(actor_fixture(agent), %{type: "applet", parent_id: parent.id})
    page
  end

  defp viewer(page) do
    {:ok, parent} = Pages.fetch(page.parent_id)
    actor_fixture(parent.created_by.uid)
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
