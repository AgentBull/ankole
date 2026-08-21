defmodule Ankole.SignalsGateway.ActorRuntime.AIGatewayRetryCommandTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.StatefulResponses

  test "retry command replays a request and deletes its pre-conversation failure notice" do
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

    failure_notice = Repo.get_by!(OutboxEntry, source_actor_event_id: input.id)

    assert {:ok, %OutboxEntry{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(
               failure_notice.agent_uid,
               failure_notice.binding_name,
               failure_notice.outbound_key,
               outbox_adapter([:post_entry, :reply_entry], fn _outbox ->
                 {:ok, %{created_source_entry_id: "provider-profile-failure"}}
               end),
               now: DateTime.add(@base_time, 20, :second)
             )

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

    assert [
             %{
               "attachment_id" => attachment_id,
               "name" => "evidence.pdf",
               "provider_ref" => "lark:file:file-1"
             }
           ] = retry_entry["attachments"]

    assert attachment_id >= 10_000

    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    assert %OutboxEntry{
             target_source_entry_id: "provider-profile-failure",
             ai_message_id: nil,
             status: :created
           } =
             Repo.get_by!(OutboxEntry,
               source_actor_event_id: retry_command.id,
               operation: :delete
             )
  end

  test "retry command deletes a dead-letter card and preserves its error response" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating, turn_ref: turn_ref} =
      start_accepted_aigateway_run(agent.uid, "RETRY DEAD LETTER", @base_time)

    preview_source_entry_id = "provider-dead-letter-preview"

    input
    |> ActorEvent.changeset(%{reply_preview_source_entry_id: preview_source_entry_id})
    |> Repo.update!()

    assert {:ok, failed_response} =
             StatefulResponses.commit_error(
               generating,
               [
                 %{
                   "type" => "message",
                   "role" => "assistant",
                   "content" => [%{"type" => "output_text", "text" => "PARTIAL"}]
                 }
               ],
               %{"code" => "worker_loop_failed", "retryable" => false}
             )

    dead_letter_at = DateTime.add(@base_time, 2, :second)

    assert {:ok, %{status: :turn_dead_lettered}} =
             ActorRuntime.handle_turn_error(
               turn_error_payload(turn_ref, "worker_loop_failed", "worker loop failed", %{}),
               now: dead_letter_at
             )

    assert %OutboxEntry{
             operation: :edit,
             target_source_entry_id: ^preview_source_entry_id
           } = Repo.get_by!(OutboxEntry, source_actor_event_id: input.id)

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 3, :second)
             )

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

    terminal = Repo.get!(ActorEvent, input.id)
    assert terminal.input_state == "dead_letter"
    assert terminal.dead_letter_at == dead_letter_at
    assert is_nil(terminal.completed_at)

    retry_event = Repo.get!(ActorEvent, retry_event.id)
    assert retry_event.id != input.id
    assert retry_event.session_id == input.session_id
    assert retry_event.input_state == "open"
    assert retry_event.source_entry_id == retry_command.source_entry_id
    assert get_in(retry_event.payload, ["data", "entry", "text"]) == "RETRY DEAD LETTER"
    assert get_in(retry_event.payload, ["data", "entry", "retry_of_actor_event_id"]) == input.id

    assert get_in(retry_event.payload, ["data", "entry", "retry_of_message_id"]) ==
             failed_response.id

    assert get_in(retry_event.payload, ["data", "entry", "retry_reason"]) == "command.retry"
    assert Repo.get!(Ankole.AIGateway.Schemas.Message, failed_response.id).status == "error"

    assert Repo.aggregate(
             from(event in ActorEvent,
               where: event.source_event_id == ^"retry:#{retry_command.id}"
             ),
             :count
           ) == 1

    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    assert %OutboxEntry{
             target_source_entry_id: ^preview_source_entry_id,
             ai_message_id: nil,
             status: :created
           } =
             Repo.get_by!(OutboxEntry,
               source_actor_event_id: retry_command.id,
               operation: :delete
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert_receive {:actor_lane, retry_envelope}
    assert turn_start_payload!(retry_envelope).actor_event.actor_event_id == retry_event.id
  end

  test "retry command does not revive a withdrawn dead-lettered request" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    source_entry_id = "withdrawn-dead-letter"
    signal_channel_id = "lark:chat:group-a"

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "withdrawn-dead-letter-received",
                 source_entry_id: source_entry_id,
                 signal_channel_id: signal_channel_id,
                 text: "WITHDRAW BEFORE RETRY",
                 explicit: true
               }),
               now: @base_time
             )

    assert {:ok, %{turn_ref: turn_ref}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    assert turn_start_payload!(envelope).turn.actor_event_id == turn_ref.actor_event_id

    assert {:ok, %{status: :turn_dead_lettered}} =
             ActorRuntime.handle_turn_error(
               turn_error_payload(turn_ref, "worker_loop_failed", "worker loop failed", %{}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{status: :accepted}} =
             Ingress.emit_entry_removed(
               agent.uid,
               "bot",
               lifecycle_entry(%{
                 source_event_id: "withdrawn-dead-letter-removed",
                 source_entry_id: source_entry_id,
                 signal_channel_id: signal_channel_id
               }),
               now: DateTime.add(@base_time, 3, :second)
             )

    refute Repo.get_by(Entry,
             signal_channel_id: signal_channel_id,
             source_entry_id: source_entry_id
           )

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
    assert Repo.get!(ActorEvent, input.id).input_state == "dead_letter"

    refute Repo.exists?(
             from(event in ActorEvent,
               where: event.source_event_id == ^"retry:#{retry_command.id}"
             )
           )
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

  test "retry command retracts the completed response before appending a regeneration input" do
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

    assert {:ok, %Entry{}} =
             Ankole.SignalsGateway.Projection.mirror_receive_entry(
               Repo,
               %{
                 signal_channel_id: input.signal_channel_id,
                 source_entry_id: "provider-completed-reply",
                 reply_to_source_entry_id: input.source_entry_id,
                 provider_thread_id: input.provider_thread_id,
                 text: "OLD ANSWER",
                 formatted_content: %{},
                 attachments: [],
                 links: [],
                 author: %{"agent_uid" => agent.uid},
                 mentions: [],
                 metadata: %{"source" => "ai_gateway_final_reply"},
                 raw_payload: %{},
                 provider_time: DateTime.add(@base_time, 1, :second),
                 ai_message_id: completed.id
               },
               DateTime.add(@base_time, 1, :second)
             )

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

    retracted = Repo.get!(Ankole.AIGateway.Schemas.Message, completed.id)
    assert retracted.status == "retracted"
    assert retracted.metadata["retraction"]["reason"] == "command.retry"

    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    delete_outbox =
      Repo.get_by!(OutboxEntry,
        source_actor_event_id: retry_command.id,
        operation: :delete
      )

    assert delete_outbox.status == :created
    assert delete_outbox.target_source_entry_id == "provider-completed-reply"
    assert delete_outbox.ai_message_id == completed.id
    assert delete_outbox.reply_to_source_entry_id == nil

    assert {:ok, %OutboxEntry{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(
               delete_outbox.agent_uid,
               delete_outbox.binding_name,
               delete_outbox.outbound_key,
               outbox_adapter([:delete_entry], fn _outbox -> {:ok, %{}} end),
               now: DateTime.add(@base_time, 3, :second)
             )

    refute Repo.get_by(Entry,
             signal_channel_id: input.signal_channel_id,
             source_entry_id: "provider-completed-reply"
           )

    refute_receive {:actor_lane, _turn_control}, 50

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

    assert_receive {:actor_lane, retry_envelope}
    retry_actor_event = turn_start_payload!(retry_envelope).actor_event
    assert retry_actor_event.actor_event_id == retry_event.id
    assert decoded_json_bytes(retry_actor_event.payload_json)["data"]["entry"]["text"] == "PING"

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, input.session_id)
    assert is_nil(StatefulResponses.latest_visible_leaf(conversation.id))
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
    turn_ref = turn_start_payload!(envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, input.session_id)

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
    assert envelope_body_type(retry_control) == :turn_control
    assert envelope_body!(retry_control, :turn_control).command == "retry"
    assert envelope_body!(retry_control, :turn_control).turn.actor_event_id == input.id
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
    assert envelope_body_type(retry_control) == :turn_control
    assert envelope_body!(retry_control, :turn_control).command == "retry"
    assert envelope_body!(retry_control, :turn_control).turn.actor_event_id == input.id

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert_receive {:actor_lane, retry_envelope}
    retry_actor_event = turn_start_payload!(retry_envelope).actor_event
    assert retry_actor_event.actor_event_id == input.id
    assert decoded_json_bytes(retry_actor_event.payload_json)["data"]["entry"]["text"] == "PING"
  end

  test "a contiguous attachment retracts a safe partial turn and reruns the same actor event" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating} =
      start_accepted_aigateway_run(agent.uid, "Inspect the report", @base_time)

    observed_at = DateTime.add(@base_time, 2, :second)
    observed_at_text = DateTime.to_iso8601(observed_at)

    pending =
      group_entry(%{
        source_event_id: "active-supplement-file",
        source_entry_id: "active-supplement-file",
        text: nil,
        attachments: [
          %{
            provider_ref: "lark:file:report",
            source_message_id: "active-supplement-file",
            resource_type: "file",
            name: "report.pdf"
          }
        ],
        metadata: %{
          "attachment_materialization" => %{
            "state" => "pending",
            "observed_at" => observed_at_text
          }
        }
      })

    assert {:ok,
            %{
              status: :input_superseded,
              actor_event: superseded,
              retry_control_outcomes: [%{send_outcome: "sent_or_queued"}]
            }} =
             Ingress.emit_entry(agent.uid, "bot", pending, now: observed_at)

    assert superseded.id == input.id
    assert superseded.available_at == DateTime.add(observed_at, 4, :second)

    assert Repo.get!(Message, generating.id).status == "retracted"

    assert Repo.get!(Message, generating.id).metadata["retraction"]["reason"] ==
             "input_superseded"

    assert_receive {:actor_lane, retry_control}
    assert envelope_body_type(retry_control) == :turn_control
    assert envelope_body!(retry_control, :turn_control).command == "retry"
    assert envelope_body!(retry_control, :turn_control).turn.actor_event_id == input.id

    second_observed_at = DateTime.add(observed_at, 100, :millisecond)

    second_pending =
      group_entry(%{
        source_event_id: "active-supplement-image",
        source_entry_id: "active-supplement-image",
        text: nil,
        attachments: [
          %{
            provider_ref: "lark:image:chart",
            source_message_id: "active-supplement-image",
            resource_type: "image",
            name: "chart.png"
          }
        ],
        metadata: %{
          "attachment_materialization" => %{
            "state" => "pending",
            "observed_at" => DateTime.to_iso8601(second_observed_at)
          }
        }
      })

    assert {:ok, %{status: :input_superseded_refresh}} =
             Ingress.emit_entry(agent.uid, "bot", second_pending, now: second_observed_at)

    refute_receive {:actor_lane, _second_retry_control}, 50

    materialized_at = DateTime.add(observed_at, 1, :second)
    materialized_path = "/agents/#{agent.uid}/user-files/inbox/report.pdf"

    materialized =
      pending
      |> put_in([:metadata, "attachment_materialization", "state"], "complete")
      |> put_in(
        [:attachments, Access.at(0), :agent_computer_path],
        materialized_path
      )

    assert {:ok, %{status: :input_superseded_refresh, actor_event: refreshed}} =
             Ingress.emit_entry(agent.uid, "bot", materialized, now: materialized_at)

    assert refreshed.id == input.id
    assert refreshed.available_at == DateTime.add(second_observed_at, 4, :second)

    second_materialized_at = DateTime.add(materialized_at, 100, :millisecond)
    second_materialized_path = "/agents/#{agent.uid}/user-files/inbox/chart.png"

    second_materialized =
      second_pending
      |> put_in([:metadata, "attachment_materialization", "state"], "complete")
      |> put_in(
        [:attachments, Access.at(0), :agent_computer_path],
        second_materialized_path
      )

    assert {:ok, %{status: :input_superseded_refresh, actor_event: refreshed}} =
             Ingress.emit_entry(
               agent.uid,
               "bot",
               second_materialized,
               now: second_materialized_at
             )

    assert refreshed.available_at == second_materialized_at

    assert [
             %{
               "agent_computer_path" => ^materialized_path,
               "provider_ref" => "lark:file:report"
             },
             %{
               "agent_computer_path" => ^second_materialized_path,
               "provider_ref" => "lark:image:chart"
             }
           ] =
             get_in(refreshed.payload, ["data", "entry", "attachments"])
             |> Enum.map(&Map.take(&1, ["agent_computer_path", "provider_ref"]))

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: second_materialized_at,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, retry_envelope}
    retried_event = turn_start_payload!(retry_envelope).actor_event
    assert retried_event.actor_event_id == input.id

    assert [
             %{
               "agent_computer_path" => ^materialized_path
             },
             %{
               "agent_computer_path" => ^second_materialized_path
             }
           ] =
             retried_event.payload_json
             |> decoded_json_bytes()
             |> get_in(["data", "entry", "attachments"])
             |> Enum.map(&Map.take(&1, ["agent_computer_path"]))
  end

  test "a tool call guards the active turn and queues the attachment as the next turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating} =
      start_accepted_aigateway_run(agent.uid, "Send the report", @base_time)

    assert {:ok, tool_call_response} =
             StatefulResponses.commit_complete(generating, [
               %{
                 "type" => "function_call",
                 "call_id" => "call-send-report",
                 "name" => "send_report",
                 "arguments" => ~s({"channel":"finance"})
               }
             ])

    observed_at = DateTime.add(@base_time, 2, :second)

    pending =
      group_entry(%{
        source_event_id: "guarded-supplement-file",
        source_entry_id: "guarded-supplement-file",
        text: nil,
        attachments: [
          %{
            provider_ref: "lark:file:guarded-report",
            source_message_id: "guarded-supplement-file",
            resource_type: "file",
            name: "report.pdf"
          }
        ],
        metadata: %{
          "attachment_materialization" => %{
            "state" => "pending",
            "observed_at" => DateTime.to_iso8601(observed_at)
          }
        }
      })

    assert {:ok,
            %{
              status: :accepted,
              input_supersession_fallback: :external_side_effect_guard,
              inbound_batch: pending_batch
            }} =
             Ingress.emit_entry(agent.uid, "bot", pending, now: observed_at)

    assert pending_batch.mode == "addressed"
    assert Repo.get!(Message, tool_call_response.id).status == "complete"
    refute_receive {:actor_lane, _retry_control}, 50

    materialized_at = DateTime.add(observed_at, 1, :second)

    materialized =
      pending
      |> put_in([:metadata, "attachment_materialization", "state"], "complete")
      |> put_in(
        [:attachments, Access.at(0), :agent_computer_path],
        "/agents/#{agent.uid}/user-files/inbox/guarded-report.pdf"
      )

    assert {:ok, %{status: :accepted, inbound_batch: ready_batch}} =
             Ingress.emit_entry(agent.uid, "bot", materialized, now: materialized_at)

    assert ready_batch.id == pending_batch.id

    assert {:ok, [%{actor_event: next_input}]} =
             Ankole.SignalsGatewayFixtures.finalize_due_inbound_batch_events(
               now: ready_batch.available_at
             )

    assert next_input.id != input.id
    assert next_input.type == "im.message.addressed"
    assert next_input.source_entry_id == "guarded-supplement-file"
  end

  test "another group member's attachment does not supersede the active request" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{generating: generating} =
      start_accepted_aigateway_run(agent.uid, "Inspect the report", @base_time)

    observed_at = DateTime.add(@base_time, 2, :second)

    assert {:ok, %{status: :ignored, inbound_batch: batch}} =
             Ingress.emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "bob-unrelated-file",
                 source_entry_id: "bob-unrelated-file",
                 author: %{
                   principal_uid: "bob",
                   id: "provider-bob",
                   display_name: "Bob"
                 },
                 text: nil,
                 attachments: [
                   %{
                     provider_ref: "lark:file:bob",
                     source_message_id: "bob-unrelated-file",
                     resource_type: "file"
                   }
                 ],
                 metadata: %{
                   "attachment_materialization" => %{
                     "state" => "pending",
                     "observed_at" => DateTime.to_iso8601(observed_at)
                   }
                 }
               }),
               now: observed_at
             )

    assert batch.mode == "neutral"
    assert Repo.get!(Message, generating.id).status == "generating"
    refute_receive {:actor_lane, _retry_control}, 50
  end

  test "a completion that commits first makes the observed attachment the next turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating, turn_ref: turn_ref} =
      start_accepted_aigateway_run(agent.uid, "Inspect the report", @base_time)

    completed_response = complete_aigateway_run(generating, turn_ref)
    completed_event = Repo.get!(ActorEvent, input.id)
    observed_at = DateTime.add(completed_event.completed_at, -1, :millisecond)
    received_at = DateTime.add(completed_event.completed_at, 1, :millisecond)

    assert {:ok,
            %{
              status: :accepted,
              input_supersession_fallback: :completion_won,
              inbound_batch: next_batch
            }} =
             Ingress.emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "completion-won-file",
                 source_entry_id: "completion-won-file",
                 text: nil,
                 attachments: [
                   %{
                     provider_ref: "lark:file:completion-won",
                     source_message_id: "completion-won-file",
                     resource_type: "file"
                   }
                 ],
                 metadata: %{
                   "attachment_materialization" => %{
                     "state" => "pending",
                     "observed_at" => DateTime.to_iso8601(observed_at)
                   }
                 }
               }),
               now: received_at
             )

    assert next_batch.mode == "addressed"
    assert Repo.get!(Message, completed_response.id).status == "complete"
    refute_receive {:actor_lane, _retry_control}, 50
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
    turn_ref = turn_start_payload!(envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

    {:ok, conversation} = Conversations.ensure_conversation(agent_uid, input.session_id)

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
             ActorRuntime.handle_turn_completed(
               turn_completed_payload(turn_ref, "resp_#{completed.id}", "loop_finished")
             )

    completed
  end
end
