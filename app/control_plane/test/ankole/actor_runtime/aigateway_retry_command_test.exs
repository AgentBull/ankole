defmodule Ankole.ActorRuntime.AIGatewayRetryCommandTest do
  use Ankole.ActorRuntimeCase

  alias Ankole.AIGateway.StatefulResponses

  test "retry command after a completed response appends a retry input without command feedback" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating} =
      start_accepted_aigateway_run(agent.uid, "PING", @base_time)

    assert {:ok, completed} =
             StatefulResponses.commit_complete(
               generating,
               [
                 %{
                   "type" => "message",
                   "content" => [%{"type" => "output_text", "text" => "PONG"}]
                 }
               ],
               %{}
             )

    assert completed.status == "complete"
    assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    retry_event = Repo.get!(ActorEvent, retry_event.id)
    assert retry_event.type == "im.message.addressed"
    assert retry_event.payload["type"] == "im.message.addressed"

    retry_entry = get_in(retry_event.payload, ["data", "entry"])
    assert retry_entry["text"] == "PING"
    assert retry_entry["retry_of_actor_event_id"] == input.id
    assert retry_entry["retry_of_message_id"] == completed.id

    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    refute Repo.exists?(
             from(outbox in OutboxEntry,
               where: outbox.source_actor_event_id == ^retry_command.id
             )
           )

    refute_receive {:actor_lane, _turn_control}, 50

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

    assert_receive {:actor_lane, retry_envelope}
    retry_actor_event = retry_envelope["body"]["turn_start"]["actor_event"]
    assert retry_actor_event["actor_event_id"] == retry_event.id
    assert retry_actor_event["payload_json"]["data"]["entry"]["text"] == "PING"
  end

  test "retry command cancels the active AIGateway generating row and retries the actor event" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "PING", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    turn_ref = envelope["body"]["turn_start"]["turn"]

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{
                 "turn" => turn_ref
               }
             })

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, input.session_id)

    {:ok, generating} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: input.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "PING"}]
          }
        ]
      })

    assert generating.status == "generating"

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{status: :command_consumed, retry_actor_events: [retry_event]}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert retry_event.id == input.id
    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    cancelled = Repo.get!(Message, generating.id)
    assert cancelled.status == "error"
    assert cancelled.metadata["response"]["cancel_code"] == "command.retry"
    assert cancelled.metadata["error"]["stage"] == "actor_runtime_cancel"

    retried = Repo.get!(ActorEvent, input.id)
    assert is_nil(retried.completed_at)
    assert get_in(retried.payload, ["data", "entry", "retry_of_actor_event_id"]) == input.id
    assert get_in(retried.payload, ["data", "entry", "retry_reason"]) == "command.retry"

    assert Repo.one!(
             from(delivery in ActorEventDelivery,
               where: delivery.actor_event_id == ^input.id,
               select: delivery.state
             )
           ) == "superseded"

    assert_receive {:actor_lane, retry_control}
    assert retry_control["body"]["type"] == "turn_control"
    assert retry_control["body"]["turn_control"]["command"] == "retry"
    assert retry_control["body"]["turn_control"]["turn"]["actor_event_id"] == input.id
  end

  test "retry command bypasses ordinary queued input while AIGateway generation is active" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating} =
      start_accepted_aigateway_run(agent.uid, "PING", @base_time)

    assert {:ok, %{actor_event: ordinary_input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ordinary-before-retry",
                 source_entry_id: "ordinary-before-retry",
                 text: "handle this after retry",
                 explicit: true
               }),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 3, :second)
             )

    assert ordinary_input.queue_sequence < retry_command.queue_sequence

    assert {:ok, %{status: :command_consumed, retry_actor_events: [retry_event]}} =
             process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

    assert retry_event.id == input.id
    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at
    assert is_nil(Repo.get!(ActorEvent, ordinary_input.id).completed_at)
    assert Repo.get!(ActorEvent, ordinary_input.id).input_state == "open"

    cancelled = Repo.get!(Message, generating.id)
    assert cancelled.status == "error"
    assert cancelled.metadata["response"]["cancel_code"] == "command.retry"

    assert_receive {:actor_lane, retry_control}
    assert retry_control["body"]["type"] == "turn_control"
    assert retry_control["body"]["turn_control"]["command"] == "retry"
    assert retry_control["body"]["turn_control"]["turn"]["actor_event_id"] == input.id

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert_receive {:actor_lane, retry_envelope}
    retry_actor_event = retry_envelope["body"]["turn_start"]["actor_event"]
    assert retry_actor_event["actor_event_id"] == input.id
    assert retry_actor_event["payload_json"]["data"]["entry"]["text"] == "PING"
  end

  defp start_accepted_aigateway_run(agent_uid, text, now) do
    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(%{text: text, explicit: true}),
               now: now
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(now, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    turn_ref = envelope["body"]["turn_start"]["turn"]

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{
                 "turn" => turn_ref
               }
             })

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent_uid, input.session_id)

    {:ok, generating} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent_uid,
        conversation_id: conversation.id,
        actor_event_id: input.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => text
          }
        ]
      })

    %{input: input, generating: generating}
  end
end
