defmodule Ankole.Sessions.ConversationInputDedupeTest do
  use Ankole.SessionsCase

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Sessions.{Admission, Model, Run}

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  test "a queued next turn reads only statements after the predecessor's actual model snapshot" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :record_only, adapter: "mock-provider")
    provider_id = "mock:chat:context-dedupe"

    assert {:ok, %{status: :recorded}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 provider_conversation_id: provider_id,
                 provider_message_id: "backdrop-1",
                 text: "backdrop one"
               }),
               now: @base_time
             )

    first = input(agent.uid, provider_id, "addressed-1", "first question", 1)
    assert {:ok, first_run} = Admission.admit(first, first)
    assert {:ok, {:preparing, prepared}} = Model.prepare(first_run)
    first_request = Model.request(prepared)
    first_ids = first_request["metadata"]["conversation_read"]["message_ids"]
    first_id = first.message_id
    assert first_id in first_ids
    [backdrop_id] = first_ids -- [first_id]
    refute Map.has_key?(first.data, "channel_context")

    assert {:ok, %{status: :recorded}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 provider_conversation_id: provider_id,
                 provider_message_id: "backdrop-2",
                 text: "backdrop two"
               }),
               now: DateTime.add(@base_time, 12, :second)
             )

    second = input(agent.uid, provider_id, "addressed-2", "second question", 13)
    original_data = second.data

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: first_run.conversation.id,
               round_state: first_run,
               metadata: %{"request_metadata" => first_request["metadata"]},
               request_items: first_request["input"]
             })

    assert {:ok, completed} =
             ResponseCommit.commit_complete(response, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "first answer"}]
               }
             ])

    assert {:ok, %{status: :completed}} = Run.finalize(%{first_run | anchor: completed.id})

    assert {:ok, second_run} = Admission.admit(second, second)
    assert {:ok, {:preparing, prepared}} = Model.prepare(second_run)
    request = Model.request(prepared)
    ids = request["metadata"]["conversation_read"]["message_ids"]
    refute backdrop_id in ids
    refute first_id in ids
    assert second.message_id in ids
    assert length(ids) == 2
    input_text = Ankole.JSON.encode!(request["input"])
    assert input_text =~ "backdrop two"
    assert input_text =~ "second question"
    refute input_text =~ "backdrop one"
    assert Repo.reload!(second).data == original_data
  end

  defp input(agent_uid, provider_id, message_id, text, seconds) do
    assert {:ok, %{signal: signal}} =
             emit_entry(
               agent_uid,
               "mock",
               group_entry(%{
                 provider_conversation_id: provider_id,
                 provider_message_id: message_id,
                 text: text,
                 explicit: true
               }),
               now: DateTime.add(@base_time, seconds, :second)
             )

    signal
  end
end
