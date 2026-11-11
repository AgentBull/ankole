defmodule Ankole.Pod.AppletDecideTest do
  use Ankole.AIGatewayCase

  alias Ankole.Pod.{Applets.Capabilities, Pages}

  test "ai.decide answers through the Pod decision profile and rejects a malformed request" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: owner.uid})
    test_pid = self()

    answers = %{"urgent" => %{"type" => "noul", "noul" => 0.93}}

    base_url =
      start_upstream_server(fn %{path: "accounts/acct-1/ai/run/@cf/cloudflare/clef"} = request ->
        send(test_pid, {:decision_request, request.body})

        {:json, 200,
         %{
           "result" => %{
             "model" => "clef",
             "answers" => answers,
             "usage" => %{"input_tokens" => 41, "output_tokens" => 0}
           }
         }}
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "cloudflare-main",
        provider_kind: "cloudflare",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "cf-token"}]},
        connection_options: %{"account_id" => "acct-1"}
      })

    {:ok, _} =
      ModelProfiles.put_default_model_profile(:tenant, "decision", %{
        provider_id: "cloudflare-main",
        model: "@cf/cloudflare/clef"
      })

    ctx = %{"applet" => %{"pageId" => page.id, "revision" => 1}, "method" => "GET"}

    questions = %{
      "urgent" => %{"type" => "noul", "instructions" => "Does it need a reply today?"}
    }

    assert {:ok,
            %{
              "model" => "clef",
              "answers" => ^answers,
              "usage" => %{"inputTokens" => 41, "outputTokens" => 0}
            }} =
             Capabilities.call(ctx, actor, "ai.decide", [
               %{"state" => "I was charged twice.", "questions" => questions}
             ])

    assert_receive {:decision_request, %{"model" => "clef", "questions" => ^questions}}

    assert {:error, %{status: 400, code: "invalid_request", message: message}} =
             Capabilities.call(ctx, actor, "ai.decide", [%{"state" => nil, "questions" => %{}}])

    assert message =~ "questions"

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Capabilities.call(ctx, actor, "ai.decide", [
               %{"state" => nil, "questions" => questions, "model" => "primary"}
             ])

    refute_received {:decision_request, _body}
  end

  test "Gateway.error preserves deterministic 413 and 422 OpenAIError codes and messages" do
    alias Ankole.AIGateway.OpenAIError
    alias Ankole.Pod.Applets.Gateway

    assert %{status: 413, code: "file_too_large", message: "Audio exceeds 25 MB"} =
             Gateway.error(:ai, %OpenAIError{
               status: 413,
               type: "invalid_request_error",
               code: "payload_too_large",
               message: "Audio exceeds 25 MB"
             })

    assert %{
             status: 422,
             code: "upstream_decision_refusal",
             message: "Question schema unsupported"
           } =
             Gateway.error(:ai, %OpenAIError{
               status: 422,
               type: "invalid_request_error",
               code: "upstream_decision_refusal",
               message: "Question schema unsupported"
             })
  end
end
