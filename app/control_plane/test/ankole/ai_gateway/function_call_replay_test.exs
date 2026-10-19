defmodule Ankole.AIGateway.FunctionCallReplayTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.{Conversations, ResponseCommit, ResponseStream}
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Sessions.ToolArguments

  test "native provider replay explains lost arguments without changing the stored call or result" do
    %{principal: agent} = agent_fixture()
    parent = self()

    base_url =
      start_upstream_server(fn request ->
        send(parent, {:provider_input, request.body["input"]})

        {:sse, 200,
         openai_response_stream_events(
           "resp_replay_note",
           "gpt-test",
           "The recorded result is clear."
         )}
      end)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: "replay-note",
               provider_kind: "openai",
               base_url: base_url <> "/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Local fixture", "api_key" => "sk-test"}]
               }
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "replay-note",
               model: "gpt-test"
             })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, "replay-note")
    arguments = "```JSON\n{\"path\":\"/workspace/report.txt\"\n```"

    assert {:ok, %{"path" => "/workspace/report.txt"}, :incomplete_container} =
             ToolArguments.parse(arguments)

    call = %{
      "type" => "function_call",
      "call_id" => "call_read",
      "name" => "read_file",
      "arguments" => arguments,
      "status" => "completed"
    }

    output = %{
      "type" => "function_call_output",
      "call_id" => "call_read",
      "output" => "Recorded file content"
    }

    {:ok, original} =
      start_response_run(%{subject_uid: agent.uid, conversation_id: conversation.id})

    {:ok, original} = ResponseCommit.commit_complete(original, [call])

    assert {:ok, %{message: journal}} =
             Repo.transact(fn repo ->
               AIGateway.record_tool_results_in_tx(
                 repo,
                 agent.uid,
                 %{"previous_response_id" => "resp_#{original.id}", "input" => [output]},
                 %{}
               )
             end)

    assert {:ok, stream, meta} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "conversation" => "conv_#{conversation.id}",
               "store" => true,
               "input" => "Explain the recorded result."
             })

    assert {:ok, %{terminal_response: %{"status" => "completed"}}, _} =
             ResponseStream.await_terminal(stream, meta, 5_000)

    assert_receive {:provider_input, input}
    projected_call = Enum.find(input, &(&1["type"] == "function_call"))
    projected_output = Enum.find(input, &(&1["type"] == "function_call_output"))
    assert projected_call["arguments"] == "{}"
    assert projected_call["call_id"] == projected_output["call_id"]
    assert projected_output["output"] =~ "The original tool-call arguments could not be recovered"
    assert projected_output["output"] =~ "does not mean the tool ran with {}"
    assert projected_output["output"] =~ "Recorded file content"
    assert Repo.get!(Message, original.id).content == [call]
    assert Repo.get!(Message, journal.id).content == [output]
  end
end
