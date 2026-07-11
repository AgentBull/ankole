defmodule Ankole.SignalsGateway.AIGatewayLinkTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AIGatewayLink

  test "selects and fails only the explicit actor-correlated generating Response" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-cancel")

    {:ok, selected} =
      start_response(subject.uid, conversation.id, %{
        "actor_event_id" => "event-selected",
        "request_refs" => [%{"actor_event_id" => "event-steer"}]
      })

    {:ok, untouched} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-other"})

    actor_key = %{agent_uid: subject.uid, session_id: conversation.conversation_key}
    now = DateTime.utc_now(:microsecond)

    assert {:ok, failed} =
             Repo.transact(fn repo ->
               assert %{
                        response_id: response_id,
                        actor_event_id: "event-selected",
                        request_ref_actor_event_ids: ["event-steer"]
                      } = AIGatewayLink.generating_turn_in_tx(repo, actor_key, "event-selected")

               assert response_id == "resp_#{selected.id}"

               AIGatewayLink.cancel_generating_turn_in_tx(
                 repo,
                 actor_key,
                 "event-selected",
                 now,
                 "command.stop"
               )
             end)

    assert failed.id == selected.id
    assert failed.status == "error"
    assert failed.metadata["error"]["code"] == "command.stop"
    assert Repo.get!(Message, untouched.id).status == "generating"
  end

  test "finds retry source from opaque request metadata and user input" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-retry")

    {:ok, response} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "retry me"}]
          }
        ],
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, response} = StatefulResponses.commit_complete(response, [])

    assert {:ok, %{actor_event_id: "event-retry", message_id: message_id, text: "retry me"}} =
             Repo.transact(fn repo ->
               AIGatewayLink.retry_source_in_tx(
                 repo,
                 subject.uid,
                 conversation.conversation_key
               )
             end)

    assert message_id == response.id
  end

  test "selects an actor-correlated visible suffix before calling generic deletion" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-retraction")

    {:ok, first} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-tail"})

    {:ok, first} = StatefulResponses.commit_complete(first, [])

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-tail"}}
      })

    {:ok, second} = StatefulResponses.commit_complete(second, [])

    assert {:ok,
            %{
              status: :deleted,
              deleted_count: 2,
              failed_generating_count: 0,
              deleted_message_ids: deleted_ids
            }} =
             Repo.transact(fn repo ->
               AIGatewayLink.delete_visible_turn_suffix_in_tx(
                 repo,
                 subject.uid,
                 conversation.conversation_key,
                 "event-tail",
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert MapSet.new(deleted_ids) == MapSet.new([first.id, second.id])
    refute Repo.get(Message, first.id)
    refute Repo.get(Message, second.id)
  end

  defp start_response(subject_uid, conversation_id, request_metadata) do
    StatefulResponses.start_response_run(%{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      metadata: %{"request_metadata" => request_metadata}
    })
  end
end
