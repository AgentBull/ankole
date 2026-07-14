defmodule Ankole.SignalsGateway.ActorRuntime.AIGatewayRetryCommandTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.StatefulResponses

  test "retry command replays a completed request that failed before conversation creation" do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    assert {:ok, _worker} = admit_worker(unique_route())

    attachment = %{
      provider_ref: "lark:file:file-1",
      name: "evidence.pdf"
    }

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "PING", explicit: true, attachments: [attachment]}),
               now: @base_time
             )

    assert {:ok, %{status: :model_profile_unavailable}} =
             process_ready_events_once(now: DateTime.add(@base_time, 20, :second))

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 21, :second)
             )

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 22, :second))

    retry_event = Repo.get!(ActorEvent, retry_event.id)
    retry_entry = get_in(retry_event.payload, ["data", "entry"])

    assert retry_event.type == "im.message.addressed"
    assert retry_event.source_entry_id == retry_command.source_entry_id
    assert retry_entry["text"] == "PING"
    assert retry_entry["retry_of_actor_event_id"] == input.id
    assert retry_entry["retry_reason"] == "command.retry"

    assert retry_entry["attachments"] == [
             %{"name" => "evidence.pdf", "provider_ref" => "lark:file:file-1"}
           ]

    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at
  end

  test "retry command without a prior request is consumed with visible feedback" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 1, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.nothing_to_retry")
    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    assert %OutboxEntry{payload: %{"text" => ^feedback}} =
             Repo.get_by!(OutboxEntry, source_actor_event_id: retry_command.id)

    refute Repo.exists?(
             from(event in ActorEvent,
               where:
                 event.agent_uid == ^agent.uid and event.session_id == ^retry_command.session_id and
                   event.queue_sequence > ^retry_command.queue_sequence
             )
           )
  end

  test "retry command does not cross an empty new-conversation boundary" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{generating: generating, turn_ref: turn_ref} =
      start_accepted_aigateway_run(agent.uid, "OLD REQUEST", @base_time)

    complete_aigateway_run(generating, turn_ref)

    assert {:ok, %{actor_event: new_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/new", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{status: :command_consumed}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert %DateTime{} = Repo.get!(ActorEvent, new_command.id).completed_at

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 4, :second)
             )

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.nothing_to_retry")
    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    refute Repo.exists?(
             from(event in ActorEvent,
               where:
                 event.agent_uid == ^agent.uid and event.session_id == ^retry_command.session_id and
                   event.queue_sequence > ^retry_command.queue_sequence
             )
           )
  end

  test "retry command prefers a newer completed ActorEvent over an older AIGateway response" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{generating: generating, turn_ref: turn_ref} =
      start_accepted_aigateway_run(agent.uid, "OLD REQUEST", @base_time)

    complete_aigateway_run(generating, turn_ref)

    assert {:ok, %{actor_event: latest_input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "LATEST REQUEST", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %ActorEvent{}} =
             Repo.transact(fn repo ->
               latest_input = Actors.lock_actor_event_in_tx(repo, latest_input.id)

               Actors.complete_actor_event_in_tx(repo, latest_input,
                 completed_at: DateTime.add(@base_time, 3, :second)
               )
             end)

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 4, :second)
             )

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    retry_entry = get_in(Repo.get!(ActorEvent, retry_event.id).payload, ["data", "entry"])
    assert retry_entry["text"] == "LATEST REQUEST"
    assert retry_entry["retry_of_actor_event_id"] == latest_input.id
    refute Map.has_key?(retry_entry, "retry_of_message_id")
    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at
  end

  test "retry command after a completed response appends a retry input without command feedback" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating, turn_ref: turn_ref} =
      start_accepted_aigateway_run(agent.uid, "PING", @base_time,
        request_text: "<agent_environment_info>injected</agent_environment_info>\nPING"
      )

    completed = complete_aigateway_run(generating, turn_ref)

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
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => input.id}},
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
    assert cancelled.metadata["error"]["code"] == "command.retry"
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
    assert cancelled.metadata["error"]["code"] == "command.retry"

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

  defp start_accepted_aigateway_run(agent_uid, text, now, opts \\ []) do
    request_text = Keyword.get(opts, :request_text, text)

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
        subject_uid: agent_uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => input.id}},
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => request_text
          }
        ]
      })

    %{input: input, generating: generating, turn_ref: turn_ref}
  end

  defp complete_aigateway_run(generating, turn_ref) do
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

    assert {:ok, %{status: :turn_completed}} =
             ActorRuntime.handle_turn_completed(%{
               "turn_completed" => %{
                 "turn" => turn_ref,
                 "final_response_id" => "resp_#{completed.id}",
                 "outcome" => "loop_finished"
               }
             })

    completed
  end
end
