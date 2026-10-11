defmodule AnkoleWeb.AIGatewayToolHistoryControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Tokens

  test "the public response endpoint rejects bad search and program history before dispatch" do
    %{principal: agent} = agent_fixture()

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "history-rejection",
        provider_kind: "openrouter",
        base_url: "http://127.0.0.1:1",
        credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
      })

    {:ok, _profile} =
      ModelProfiles.put_model_profile(agent.uid, "primary", %{
        provider_id: "history-rejection",
        model: "test",
        provider_options: %{}
      })

    {:ok, credential} = Tokens.mint_for_agent(agent.uid)

    for {code, declaration, output} <- [
          {"invalid_tool_search_history", %{"type" => "tool_search", "execution" => "client"},
           %{
             "type" => "tool_search_output",
             "execution" => "client",
             "call_id" => "missing",
             "status" => "completed",
             "tools" => []
           }},
          {"invalid_program", %{"type" => "programmatic_tool_calling"},
           %{
             "type" => "program_output",
             "call_id" => "missing",
             "status" => "completed",
             "result" => "x"
           }}
        ] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{credential.api_key}")
        |> post("/api/v1/ai-gateway/responses", %{
          "model" => "primary",
          "tools" => [declaration],
          "input" => [output]
        })

      assert json_response(conn, 400) == %{
               "error" => %{
                 "code" => code,
                 "type" => "invalid_request_error",
                 "param" => nil,
                 "message" => "The Responses tool declaration or tool-call history is invalid."
               }
             }
    end
  end
end
