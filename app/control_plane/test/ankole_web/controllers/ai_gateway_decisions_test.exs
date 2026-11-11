defmodule AnkoleWeb.AIGatewayDecisionsTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.Tokens

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  @questions %{
    "urgent" => %{"type" => "noul", "instructions" => "Does `ticket.message` need a reply today?"},
    "team" => %{
      "type" => "choice",
      "instructions" => "Which team owns the ticket?",
      "criteria" => %{"billing" => "Payments and refunds", "support" => "Product questions"}
    },
    "severity" => %{
      "type" => "score",
      "instructions" => "How severe is the problem?",
      "criteria" => ["Cosmetic", "Degraded", "Outage"]
    }
  }

  setup %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    test_pid = self()

    upstream = fn response_fun ->
      start_upstream_server(fn request ->
        send(test_pid, {:gateway_request, request})
        response_fun.(request)
      end)
    end

    %{
      agent: agent,
      upstream: upstream,
      conn: put_req_header(conn, "authorization", "Bearer #{api_key.api_key}")
    }
  end

  defp cloudflare_provider(base_url) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "cloudflare-main",
               provider_kind: "cloudflare",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "cf-token"}]},
               connection_options: %{"account_id" => "acct-1"}
             })
  end

  # Gives the Agent a `primary` language model that answers with `output`.
  defp language_model(ctx, output) do
    base_url =
      ctx.upstream.(fn %{path: "v1/responses"} ->
        {:json, 200,
         %{
           "id" => "resp_decision",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => Ankole.JSON.encode!(output)}]
             }
           ],
           "usage" => %{"input_tokens" => 120, "output_tokens" => 30}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-main",
               provider_kind: "openai",
               base_url: base_url <> "/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "primary", %{
               provider_id: "openai-main",
               model: "gpt-5.5"
             })
  end

  defp decide(conn, request),
    do: post(conn, ~p"/api/v1/ai-gateway/decisions", Map.put_new(request, "model", "default"))

  test "web_search reaches Cloudflare Web Search through the account's gateway", ctx do
    base_url =
      ctx.upstream.(fn %{path: "accounts/acct-1/ai/websearch/"} ->
        {:json, 200,
         %{
           "items" => [
             %{
               "url" => "https://example.com/ankole",
               "title" => "Ankole docs",
               "description" => "RuntimeFabric and AIGateway"
             }
           ],
           "metadata" => %{"query" => "ankole web", "requestId" => "cf-1", "latencyMs" => 612}
         }}
      end)

    cloudflare_provider(base_url)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "web_search", %{
               provider_id: "cloudflare-main",
               model: "default",
               provider_options: %{"engine" => "exa"}
             })

    conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/web_search", %{
        "model" => "web_search.default",
        "query" => "ankole web",
        "limit" => 25
      })

    assert %{
             "items" => [
               %{
                 "url" => "https://example.com/ankole",
                 "title" => "Ankole docs",
                 "description" => "RuntimeFabric and AIGateway"
               }
             ],
             "metadata" => %{"query" => "ankole web"} = metadata
           } = json_response(conn, 200)

    # The gateway reports its own request, not Cloudflare's.
    refute Map.has_key?(metadata, "requestId")

    assert_receive {:gateway_request, request}
    assert request.headers["authorization"] == "Bearer cf-token"

    assert request.body == %{
             "query" => "ankole web",
             "limit" => 10,
             "provider" => "exa",
             "options" => %{"gateway" => %{"id" => "default"}}
           }
  end

  test "a configured decision profile sends the questions to the decision model", ctx do
    answers = %{
      "urgent" => %{"type" => "noul", "noul" => 0.93},
      "team" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.9, "support" => 0.1},
        "confidence" => 0.9
      }
    }

    base_url =
      ctx.upstream.(fn %{path: "accounts/acct-1/ai/run/@cf/cloudflare/clef"} ->
        {:json, 200,
         %{
           "success" => true,
           "result" => %{
             "model" => "clef",
             "answers" => answers,
             "usage" => %{"input_tokens" => 41, "output_tokens" => 0}
           }
         }}
      end)

    cloudflare_provider(base_url)

    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, "decision", %{
               provider_id: "cloudflare-main",
               model: "@cf/cloudflare/clef"
             })

    state = %{"ticket" => %{"message" => "I was charged twice."}}
    questions = Map.take(@questions, ["urgent", "team"])
    conn = decide(ctx.conn, %{"state" => state, "questions" => questions})

    assert json_response(conn, 200) == %{
             "model" => "clef",
             "answers" => answers,
             "usage" => %{"input_tokens" => 41, "output_tokens" => 0}
           }

    assert_receive {:gateway_request, request}
    assert request.headers["authorization"] == "Bearer cf-token"
    assert request.body == %{"model" => "clef", "state" => state, "questions" => questions}

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.origin} == {:decision, :agent}
    assert {row.input_tokens, row.output_tokens} == {41, 0}
    assert {row.model, row.provider_model} == {"cloudflare-main/@cf/cloudflare/clef", "clef"}
    assert {row.unit, row.quantity} == {nil, nil}
  end

  test "without a decision profile the light language model answers", ctx do
    language_model(ctx, %{
      # Positional keys follow the question ids in order: severity, team, urgent.
      "q1" => %{"answer" => 2, "confidence" => 0.8},
      "q2" => %{"answer" => "billing", "confidence" => 0.9},
      "q3" => %{"answer" => false, "confidence" => 0.75}
    })

    conn =
      decide(ctx.conn, %{
        "model" => "decision.default",
        "state" => "The checkout page is down for everyone.",
        "questions" => @questions
      })

    assert %{
             "model" => "openai-main/gpt-5.5",
             "answers" => %{"urgent" => urgent, "team" => team, "severity" => severity},
             "usage" => %{"input_tokens" => 120, "output_tokens" => 30}
           } = json_response(conn, 200)

    assert urgent == %{"type" => "noul", "noul" => 0.25}

    assert %{"type" => "choice", "choice" => "billing", "confidence" => 0.9} = team
    assert_in_delta team["probabilities"]["billing"], 0.9, 1.0e-9
    assert_in_delta team["probabilities"]["support"], 0.1, 1.0e-9

    assert %{"type" => "score", "confidence" => 0.8} = severity
    assert severity["legend"] == %{"0" => "Cosmetic", "1" => "Degraded", "2" => "Outage"}
    assert_in_delta severity["probabilities"]["1"], 0.2, 1.0e-9
    assert severity["probabilities"]["0"] == 0.0
    assert_in_delta severity["score"], 1.8, 1.0e-9

    assert_receive {:gateway_request, request}
    assert request.body["model"] == "gpt-5.5"

    # The language model's request is an ordinary language-model round.
    assert [%UsageRecord{capability: :llm, input_tokens: 120}] = Ankole.Repo.all(UsageRecord)

    schema = request.body["text"]["format"]["schema"]
    assert Enum.sort(schema["required"]) == ["q1", "q2", "q3"]
    assert schema["properties"]["q2"]["properties"]["answer"]["enum"] == ["billing", "support"]
    assert schema["properties"]["q1"]["properties"]["answer"]["enum"] == [0, 1, 2]
  end

  test "a low confidence leaves the picked answer the most probable one", ctx do
    language_model(ctx, %{
      "q1" => %{"answer" => 1, "confidence" => 0.1},
      "q2" => %{"answer" => "support", "confidence" => 0.1},
      "q3" => %{"answer" => true, "confidence" => 0.1}
    })

    conn = decide(ctx.conn, %{"state" => "Unclear.", "questions" => @questions})

    assert %{"answers" => %{"urgent" => urgent, "team" => team, "severity" => severity}} =
             json_response(conn, 200)

    assert urgent == %{"type" => "noul", "noul" => 0.1}

    assert team == %{
             "type" => "choice",
             "choice" => "support",
             "probabilities" => %{"billing" => 0.5, "support" => 0.5},
             "confidence" => 0.5
           }

    for level <- ["0", "1", "2"],
        do: assert_in_delta(severity["probabilities"][level], 1 / 3, 1.0e-9)

    assert_in_delta severity["score"], 1.0, 1.0e-9
    assert_in_delta severity["confidence"], 1 / 3, 1.0e-9
  end

  test "the decision model receives every image as a data URL", ctx do
    base_url =
      ctx.upstream.(fn %{path: "accounts/acct-1/ai/run/@cf/cloudflare/clef"} ->
        {:json, 200,
         %{
           "result" => %{
             "model" => "clef",
             "answers" => %{"urgent" => %{"type" => "noul", "noul" => 0.5}}
           }
         }}
      end)

    cloudflare_provider(base_url)

    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, "decision", %{
               provider_id: "cloudflare-main",
               model: "@cf/cloudflare/clef"
             })

    request = %{"state" => nil, "questions" => Map.take(@questions, ["urgent"])}
    data_url = "data:image/png;base64,#{@png_base64}"
    images = [data_url, %{"content_type" => "image/png", "base64" => @png_base64}]

    assert json_response(decide(ctx.conn, Map.put(request, "images", images)), 200)
    assert_receive {:gateway_request, %{body: %{"images" => [^data_url, ^data_url]}}}

    assert json_response(decide(ctx.conn, Map.put(request, "images", [])), 200)
    assert_receive {:gateway_request, %{body: body}}
    refute Map.has_key?(body, "images")
  end

  test "a decision request is validated before any model is called", ctx do
    options = Map.new(1..255, &{"option-#{&1}", "Option #{&1}"})
    wide = %{"type" => "choice", "instructions" => "Which one?", "criteria" => options}
    too_large = Base.encode64(:binary.copy(<<0>>, 4 * 1024 * 1024 + 1))

    for {request, param} <- [
          {%{"questions" => @questions}, "state"},
          {%{"state" => nil, "questions" => %{}}, "questions"},
          {%{"state" => nil, "questions" => %{"bad id" => @questions["urgent"]}}, "questions"},
          {%{
             "state" => nil,
             "questions" => %{"team" => %{"type" => "choice", "instructions" => "Which team?"}}
           }, "questions.team.criteria"},
          {%{
             "state" => nil,
             "questions" => %{"rank" => %{"type" => "rank", "instructions" => "Rank it."}}
           }, "questions.rank.type"},
          {%{
             "state" => nil,
             "questions" => @questions,
             "images" => ["https://example.com/a.png"]
           }, "images"},
          {%{
             "state" => nil,
             "questions" => @questions,
             "images" => ["data:image/png;base64,not base64"]
           }, "images"},
          {%{
             "state" => nil,
             "questions" => @questions,
             "images" => [%{"content_type" => "image/png", "base64" => too_large}]
           }, "images"},
          # No decision profile is configured, so a language model would answer.
          {%{"state" => nil, "questions" => %{"a" => wide, "b" => wide}}, "questions"}
        ] do
      conn = decide(ctx.conn, request)
      assert %{"error" => %{"param" => ^param}} = json_response(conn, 400)
    end

    refute_received {:gateway_request, _request}
  end
end
