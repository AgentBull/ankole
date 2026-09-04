defmodule Ankole.SignalsGateway.ActorRuntime.AIGatewayRetryCommandTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.StatefulResponses

  test "reply retry replays its cron dead letter instead of a channel completion" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    session_id = "cron:#{Ecto.UUID.generate()}"

    assert {:ok, %{actor_event: unrelated_channel_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "UNRELATED CHANNEL WORK", explicit: true}),
               now: @base_time
             )

    assert {:ok, source} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent.uid,
               binding_name: "bot",
               session_id: session_id,
               source_event_id: "cron-fire-#{Ecto.UUID.generate()}",
               signal_channel_id: unrelated_channel_event.signal_channel_id,
               provider_thread_id: "scheduled-thread",
               source_entry_id: nil,
               ambient_asked_source_entry_id: "scheduled-anchor",
               type: "cron.fire",
               available_at: DateTime.add(@base_time, 1, :second),
               sender_key: "system:cron",
               payload: %{
                 "id" => "cron-payload",
                 "type" => "cron.fire",
                 "time" => DateTime.to_iso8601(@base_time),
                 "data" => %{"wake_payload" => %{"delivery" => %{"targets" => []}}}
               }
             })

    assert {:ok, %{source: dead_letter, outbox: dead_letter_outbox}} =
             Repo.transact(fn repo ->
               source = Actors.lock_actor_event_in_tx(repo, source.id)

               with {:ok, dead_letter} <-
                      Actors.mark_event_dead_letter_in_tx(
                        repo,
                        source,
                        DateTime.add(@base_time, 2, :second),
                        "cron_failed"
                      ),
                    {:ok, outbox} <-
                      Ankole.SignalsGateway.Outbox.commit_dead_letter_notice_outbox_in_tx(
                        repo,
                        dead_letter,
                        "CRON FAILED"
                      ) do
                 {:ok, %{source: dead_letter, outbox: outbox}}
               end
             end)

    assert dead_letter.input_state == "dead_letter"

    assert {:ok, %ActorEvent{}} =
             Repo.transact(fn repo ->
               unrelated = Actors.lock_actor_event_in_tx(repo, unrelated_channel_event.id)

               Actors.mark_event_completed_in_tx(
                 repo,
                 unrelated,
                 DateTime.add(@base_time, 3, :second)
               )
             end)

    provider_dead_letter_id = "provider-cron-dead-letter"

    assert {:ok, %OutboxEntry{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(
               dead_letter_outbox.agent_uid,
               dead_letter_outbox.binding_name,
               dead_letter_outbox.outbound_key,
               outbox_adapter(
                 [:post_entry, :reply_entry, :edit_entry, :card, :divider],
                 fn _outbox ->
                   {:ok, %{created_source_entry_id: provider_dead_letter_id}}
                 end
               ),
               now: DateTime.add(@base_time, 3, :second)
             )

    assert {:ok, %{actor_event: command_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_entry_id: "retry-command-entry",
                 provider_thread_id: "command-thread",
                 reply_to_source_entry_id: provider_dead_letter_id,
                 text: "/retry",
                 explicit: true
               }),
               now: DateTime.add(@base_time, 4, :second)
             )

    assert command_event.type == "command.retry"
    assert command_event.session_id == session_id

    assert get_in(command_event.payload, ["data", "command", "targetActorEventId"]) ==
             source.id

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    retry_event = Repo.get!(ActorEvent, retry_event.id)
    assert retry_event.agent_uid == source.agent_uid
    assert retry_event.binding_name == source.binding_name
    assert retry_event.session_id == source.session_id
    assert retry_event.signal_channel_id == source.signal_channel_id
    assert retry_event.provider_thread_id == source.provider_thread_id
    assert retry_event.source_entry_id == source.source_entry_id
    assert retry_event.ambient_asked_source_entry_id == source.ambient_asked_source_entry_id
    assert retry_event.type == source.type
    assert retry_event.sender_key == command_event.sender_key
    assert retry_event.available_at == DateTime.add(@base_time, 5, :second)
    assert retry_event.input_state == "open"
    assert is_nil(retry_event.completed_at)
    assert is_nil(retry_event.dead_letter_at)
    assert is_nil(retry_event.final_response_id)
    assert is_nil(retry_event.reply_preview_source_entry_id)

    assert get_in(retry_event.payload, ["data", "wake_payload"]) ==
             get_in(source.payload, ["data", "wake_payload"])

    assert get_in(retry_event.payload, ["data", "entry", "retry_of_actor_event_id"]) ==
             source.id

    assert retry_event.payload["id"] == "retry:#{command_event.id}"

    assert retry_event.payload["time"] ==
             DateTime.to_iso8601(DateTime.add(@base_time, 5, :second))

    assert Repo.get!(ActorEvent, source.id).input_state == "dead_letter"
    assert %DateTime{} = Repo.get!(ActorEvent, unrelated_channel_event.id).completed_at

    assert %OutboxEntry{target_source_entry_id: ^provider_dead_letter_id} =
             Repo.get_by!(OutboxEntry,
               source_actor_event_id: command_event.id,
               operation: :delete
             )
  end

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

    retry_command = target_retry_command!(retry_command, input.id)

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 22, :second))

    retry_event = Repo.get!(ActorEvent, retry_event.id)
    retry_entry = get_in(retry_event.payload, ["data", "entry"])

    assert retry_event.type == "im.message.addressed"
    assert retry_event.source_entry_id == input.source_entry_id
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
             fail_turn(turn_ref, "worker_loop_failed", "worker loop failed", %{},
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

    retry_command = target_retry_command!(retry_command, input.id)

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
    assert retry_event.source_entry_id == input.source_entry_id
    assert get_in(retry_event.payload, ["data", "entry", "text"]) == "RETRY DEAD LETTER"
    assert get_in(retry_event.payload, ["data", "entry", "retry_of_actor_event_id"]) == input.id

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

  test "targeted retry replays a provider failure before output" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating, turn_ref: turn_ref} =
      start_accepted_aigateway_run(agent.uid, "RETRY PROVIDER FAILURE", @base_time)

    assert {:ok, failed_response} =
             StatefulResponses.commit_error(
               generating,
               [
                 %{
                   "role" => "user",
                   "content" => [
                     %{"type" => "input_text", "text" => "RETRY PROVIDER FAILURE"}
                   ]
                 }
               ],
               %{
                 "code" => "upstream_response_failed",
                 "failure_kind" => "provider_response",
                 "provider_status" => 401,
                 "retryable" => false,
                 "stage" => "socket_open"
               }
             )

    assert {:ok, %{status: :turn_dead_lettered}} =
             fail_turn(turn_ref, "provider_response", "User not found.", %{},
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 3, :second)
             )

    _retry_command = target_retry_command!(retry_command, input.id)

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

    assert retry_event.id != input.id
    assert retry_event.source_entry_id == input.source_entry_id
    assert get_in(retry_event.payload, ["data", "entry", "retry_of_actor_event_id"]) == input.id
    assert Repo.get!(Ankole.AIGateway.Schemas.Message, failed_response.id).status == "error"
  end

  test "targeted retry refuses a dead-letter turn with an external tool effect" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating, turn_ref: turn_ref} =
      start_accepted_aigateway_run(agent.uid, "SEND REPORT", @base_time)

    assert {:ok, failed_response} =
             StatefulResponses.commit_error(
               generating,
               [
                 %{
                   "type" => "function_call",
                   "call_id" => "call-send-report",
                   "name" => "send_report",
                   "arguments" => ~s({"channel":"finance"})
                 }
               ],
               %{"code" => "worker_loop_failed", "retryable" => false}
             )

    assert {:ok, %{status: :turn_dead_lettered}} =
             fail_turn(turn_ref, "worker_loop_failed", "worker loop failed", %{},
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 3, :second)
             )

    retry_command = target_retry_command!(retry_command, input.id)

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_unavailable")
    assert Repo.get!(Ankole.AIGateway.Schemas.Message, failed_response.id).status == "error"

    refute Repo.exists?(
             from(event in ActorEvent,
               where: event.source_event_id == ^"retry:#{retry_command.id}"
             )
           )
  end

  test "targeted retry refuses a completed applied steer without a response anchor" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{actor_event: steer_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/steer use the correction", explicit: true}),
               now: @base_time
             )

    assert steer_event.type == "command.steer"

    assert {:ok, %ActorEvent{completed_at: %DateTime{}, final_response_id: nil}} =
             Repo.transact(fn repo ->
               steer_event = Actors.lock_actor_event_in_tx(repo, steer_event.id)

               Actors.complete_actor_event_in_tx(repo, steer_event,
                 completed_at: DateTime.add(@base_time, 1, :second)
               )
             end)

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    retry_command = target_retry_command!(retry_command, steer_event.id)

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_unavailable")

    refute Repo.exists?(
             from(event in ActorEvent,
               where: event.source_event_id == ^"retry:#{retry_command.id}"
             )
           )
  end

  test "targeted retry replays a standalone dead-letter steer" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{actor_event: steer_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/steer use the correction", explicit: true}),
               now: @base_time
             )

    assert steer_event.type == "command.steer"

    assert {:ok, %ActorEvent{input_state: "dead_letter", completed_at: nil}} =
             Repo.transact(fn repo ->
               steer_event = Actors.lock_actor_event_in_tx(repo, steer_event.id)

               Actors.mark_event_dead_letter_in_tx(
                 repo,
                 steer_event,
                 DateTime.add(@base_time, 1, :second),
                 "steer_failed"
               )
             end)

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    retry_command = target_retry_command!(retry_command, steer_event.id)

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert retry_event.type == "command.steer"
    assert retry_event.sender_key == retry_command.sender_key

    assert get_in(retry_event.payload, ["data", "entry", "retry_of_actor_event_id"]) ==
             steer_event.id
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
             fail_turn(turn_ref, "worker_loop_failed", "worker loop failed", %{},
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

    retry_command = target_retry_command!(retry_command, input.id)

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_unavailable")
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

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_required")
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

  test "a failed bare retry does not stale a later exact retry in the same session" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "RETRY THIS EXACT REQUEST", explicit: true}),
               now: @base_time
             )

    assert {:ok, %ActorEvent{completed_at: %DateTime{}}} =
             Repo.transact(fn repo ->
               input = Actors.lock_actor_event_in_tx(repo, input.id)

               Actors.complete_actor_event_in_tx(repo, input,
                 completed_at: DateTime.add(@base_time, 1, :second)
               )
             end)

    assert {:ok, %{actor_event: bare_retry}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_required")
    assert %DateTime{} = Repo.get!(ActorEvent, bare_retry.id).completed_at

    assert {:ok, %{actor_event: exact_retry}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 4, :second)
             )

    exact_retry = target_retry_command!(exact_retry, input.id)
    assert exact_retry.session_id == input.session_id

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert retry_event.session_id == input.session_id
    assert retry_event.sender_key == exact_retry.sender_key

    assert get_in(retry_event.payload, ["data", "entry", "retry_of_actor_event_id"]) ==
             input.id
  end

  test "retry command does not cross an empty new-conversation boundary" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating, turn_ref: turn_ref} =
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

    retry_command = target_retry_command!(retry_command, input.id)

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_unavailable")
    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at

    refute Repo.exists?(
             from(event in ActorEvent,
               where:
                 event.agent_uid == ^agent.uid and event.session_id == ^retry_command.session_id and
                   event.queue_sequence > ^retry_command.queue_sequence
             )
           )
  end

  test "targeted retry never substitutes a newer terminal ActorEvent" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: old_input, generating: generating, turn_ref: turn_ref} =
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

    retry_command = target_retry_command!(retry_command, old_input.id)

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 5, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_unavailable")

    refute Repo.exists?(
             from(event in ActorEvent,
               where: event.source_event_id == ^"retry:#{retry_command.id}"
             )
           )

    assert %DateTime{} = Repo.get!(ActorEvent, latest_input.id).completed_at
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

    retry_command = target_retry_command!(retry_command, input.id)

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    retry_event = Repo.get!(ActorEvent, retry_event.id)
    assert retry_event.type == "im.message.addressed"
    assert retry_event.payload["type"] == "im.message.addressed"

    retry_entry = get_in(retry_event.payload, ["data", "entry"])
    assert retry_entry["text"] == "PING"
    assert retry_entry["retry_of_actor_event_id"] == input.id
    refute Map.has_key?(retry_entry, "retry_of_message_id")

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
      start_response_run(%{
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

  test "an unresolved targeted retry never falls back to the live turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{input: input, generating: generating} =
      start_accepted_aigateway_run(agent.uid, "KEEP RUNNING", @base_time)

    assert {:ok, %{actor_event: retry_command}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "/retry", explicit: true}),
               now: DateTime.add(@base_time, 2, :second)
             )

    retry_command = target_retry_command!(retry_command, nil)

    assert {:ok, %{status: :command_consumed, feedback: feedback}} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert feedback == Ankole.I18n.t("signals_gateway.reply.retry_target_required")
    assert Repo.get!(Message, generating.id).status == "generating"
    assert Repo.get!(ActorEvent, input.id).input_state == "open"
    assert %DateTime{} = Repo.get!(ActorEvent, retry_command.id).completed_at
    refute_receive {:actor_lane, _retry_control}, 50
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
              control_outcomes: [%{send_outcome: "sent_or_queued"}]
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

  test "a DM attachment with a reply edge queues the next turn instead of joining the live one" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    dm_entry = fn overrides ->
      group_entry(
        Map.merge(
          %{
            signal_channel_id: "lark:dm:alice-agent",
            channel: %{kind: :im_dm, reply_mode: :entry, name: "DM"}
          },
          overrides
        )
      )
    end

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent.uid,
               "bot",
               dm_entry.(%{source_entry_id: "dm-request", text: "Inspect the report"}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 2, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    turn_ref = turn_start_payload!(envelope).turn
    assert turn_ref.actor_event_id == input.id

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

    generating = start_aigateway_run_for_turn!(turn_ref)

    observed_at = DateTime.add(@base_time, 3, :second)

    pending =
      dm_entry.(%{
        source_event_id: "dm-reply-edge-file",
        source_entry_id: "dm-reply-edge-file",
        reply_to_source_entry_id: "dm-request",
        text: nil,
        attachments: [
          %{
            provider_ref: "lark:file:dm-report",
            source_message_id: "dm-reply-edge-file",
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

    assert {:ok, %{status: :accepted, inbound_batch: pending_batch}} =
             Ingress.emit_entry(agent.uid, "bot", pending, now: observed_at)

    assert Repo.get!(Message, generating.id).status == "generating"
    refute_receive {:actor_lane, _retry_control}, 50

    materialized_at = DateTime.add(observed_at, 1, :second)

    materialized =
      pending
      |> put_in([:metadata, "attachment_materialization", "state"], "complete")
      |> put_in(
        [:attachments, Access.at(0), :agent_computer_path],
        "/agents/#{agent.uid}/user-files/inbox/report.pdf"
      )

    assert {:ok, %{status: :accepted, inbound_batch: ready_batch}} =
             Ingress.emit_entry(agent.uid, "bot", materialized, now: materialized_at)

    assert ready_batch.id == pending_batch.id
    assert Repo.get!(Message, generating.id).status == "generating"

    assert {:ok, [%{actor_event: next_input}]} =
             Ankole.SignalsGatewayFixtures.finalize_due_inbound_batch_events(
               now: ready_batch.available_at
             )

    assert next_input.id != input.id
    assert next_input.type == "im.message.addressed"
    assert next_input.source_entry_id == "dm-reply-edge-file"
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
      start_response_run(%{
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
             commit_turn_completion(turn_ref, "resp_#{completed.id}", "loop_finished")

    completed
  end

  defp target_retry_command!(%ActorEvent{} = command_event, target_actor_event_id) do
    payload =
      put_in(
        command_event.payload,
        ["data", "command", "targetActorEventId"],
        target_actor_event_id
      )

    command_event
    |> ActorEvent.changeset(%{payload: payload})
    |> Repo.update!()
  end
end
