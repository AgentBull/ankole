defmodule Ankole.AIGateway.CompactionSummarizerTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.{CompactionSummarizer, CredentialPool}

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "rejects incomplete content_filter response even when partial text starts with ## heading" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_upstream_server(fn _request ->
        partial = "## Active Task\nPartial summary cut off by safety filter"

        events = [
          %{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_filtered_1",
              "object" => "response",
              "status" => "in_progress",
              "model" => "gpt-main",
              "output" => []
            }
          },
          %{
            "type" => "response.output_text.delta",
            "item_id" => "msg_1",
            "output_index" => 0,
            "content_index" => 0,
            "delta" => partial
          },
          %{
            "type" => "response.incomplete",
            "response" => %{
              "id" => "resp_filtered_1",
              "object" => "response",
              "status" => "incomplete",
              "model" => "gpt-main",
              "incomplete_details" => %{"reason" => "content_filter"},
              "output" => [
                %{
                  "id" => "msg_1",
                  "type" => "message",
                  "role" => "assistant",
                  "status" => "incomplete",
                  "content" => [%{"type" => "output_text", "text" => partial}]
                }
              ],
              "usage" => %{"input_tokens" => 10, "output_tokens" => 8, "total_tokens" => 18}
            }
          }
        ]

        {:sse, 200, events}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-content-filter-summary",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: "openai-content-filter-summary",
               model: "gpt-main"
             })

    items = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "Summarize earlier work."}]
      }
    ]

    assert {:error, :content_filtered_compaction_summary} =
             CompactionSummarizer.summarize(agent.uid, items, nil)
  end
end
