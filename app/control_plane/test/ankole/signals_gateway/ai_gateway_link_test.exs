defmodule Ankole.SignalsGateway.AIGatewayLinkTest do
  use Ankole.DataCase, async: true

  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.Schemas.{Conversation, Message}
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AuthZ.Group
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.BindingMembership
  alias Ankole.SignalsGateway.Channel

  test "records a tool result and completes its BackgroundAgentJob lifecycle event atomically" do
    %{principal: subject} = agent_fixture()
    session_id = "tool-result-handoff-#{Ecto.UUID.generate()}"
    current_event = append_current_actor_event!(subject.uid, session_id)
    job = insert_waiting_job!(subject.uid, session_id, current_event)
    lifecycle_event = append_waiting_lifecycle_event!(job)
    {conversation, anchor} = tool_result_anchor!(subject.uid, session_id, current_event.id)
    request = tool_result_request(anchor, current_event.id, lifecycle_event.id, "call_send")

    assert {:ok, %{body: %{"id" => response_id}}} =
             AIGatewayLink.record_tool_results(subject.uid, request)

    journal = Repo.get!(Message, String.replace_prefix(response_id, "resp_", ""))
    assert journal.metadata["completed_actor_event_ids"] == [lifecycle_event.id]

    assert %DateTime{} =
             Repo.get!(Ankole.SignalsGateway.ActorEvent, lifecycle_event.id).completed_at

    assert StatefulResponses.latest_visible_leaf(conversation.id) == journal.id

    assert {:ok, %{body: %{"id" => ^response_id}}} =
             AIGatewayLink.record_tool_results(subject.uid, request)

    assert Repo.aggregate(
             from(message in Message,
               where:
                 fragment("?->>'tool_result_idempotency_key'", message.metadata) ==
                   ^journal.metadata["tool_result_idempotency_key"]
             ),
             :count
           ) == 1
  end

  test "rolls back lifecycle completion when the tool result is quarantined" do
    %{principal: subject} = agent_fixture()
    session_id = "tool-result-rollback-#{Ecto.UUID.generate()}"
    current_event = append_current_actor_event!(subject.uid, session_id)
    job = insert_waiting_job!(subject.uid, session_id, current_event)
    lifecycle_event = append_waiting_lifecycle_event!(job)
    {_conversation, anchor} = tool_result_anchor!(subject.uid, session_id, current_event.id)
    request = tool_result_request(anchor, current_event.id, lifecycle_event.id, "missing_call")

    assert {:error, {:tool_results_quarantined, _details}} =
             AIGatewayLink.record_tool_results(subject.uid, request)

    assert Repo.get!(Ankole.SignalsGateway.ActorEvent, lifecycle_event.id).completed_at == nil

    refute Message
           |> Repo.all()
           |> Enum.any?(&(&1.metadata["completed_actor_event_ids"] == [lifecycle_event.id]))
  end

  test "selects and fails only the explicit actor-correlated generating Response" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-cancel")

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
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-retry")

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

    assert {:ok,
            %{
              actor_event_id: "event-retry",
              message_id: message_id,
              status: "complete",
              text: "retry me"
            }} =
             Repo.transact(fn repo ->
               AIGatewayLink.retry_source_in_tx(
                 repo,
                 subject.uid,
                 conversation.conversation_key
               )
             end)

    assert message_id == response.id
  end

  test "retracts only the current actor-correlated visible suffix" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-retry-retract")

    {:ok, predecessor} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-before"})

    {:ok, predecessor} = StatefulResponses.commit_complete(predecessor, [])

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{predecessor.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, first} = StatefulResponses.commit_complete(first, [])

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, second} = StatefulResponses.commit_complete(second, [])

    assert {:ok, %{status: :retracted, retracted_count: 2}} =
             Repo.transact(fn repo ->
               AIGatewayLink.retract_visible_turn_suffix_in_tx(
                 repo,
                 subject.uid,
                 conversation.conversation_key,
                 "event-retry",
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert Repo.get!(Message, predecessor.id).status == "complete"
    assert Repo.get!(Message, first.id).status == "retracted"
    assert Repo.get!(Message, second.id).status == "retracted"
    assert StatefulResponses.latest_visible_leaf(conversation.id) == predecessor.id
  end

  test "selects an actor-correlated visible suffix before calling generic deletion" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-retraction")

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

  test "declares a DM conversation origin from the mirrored channel" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()
    now = DateTime.utc_now(:microsecond)
    channel_id = "dm:#{Ecto.UUID.generate()}"

    Repo.insert!(%Channel{
      id: channel_id,
      kind: :im_dm,
      reply_mode: :entry,
      metadata: %{"dm_peer_principal_uid" => peer.uid},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })

    {:ok, actor_event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent.uid,
        binding_name: "test",
        session_id: "dm-session",
        source_event_id: "event-#{Ecto.UUID.generate()}",
        signal_channel_id: channel_id,
        source_entry_id: "message-1",
        type: "im.message.addressed",
        available_at: now,
        sender_key: peer.uid,
        payload: %{"data" => %{"entry" => %{"author" => %{"principal_uid" => peer.uid}}}}
      })

    assert {:ok, conversation} =
             Repo.transact(fn repo ->
               AIGatewayLink.ensure_and_lock_conversation_in_tx(
                 repo,
                 agent.uid,
                 actor_event.session_id,
                 actor_event
               )
             end)

    assert conversation.metadata["origin"] == %{
             "peer_uid" => peer.uid,
             "channel_id" => channel_id,
             "channel_kind" => "im_dm"
           }

    assert %{"origin" => successor_origin} =
             AIGatewayLink.successor_origin_metadata(conversation)

    assert successor_origin == conversation.metadata["origin"]
  end

  test "conversation origin is recorded once and never re-verified against later channel changes" do
    %{principal: agent} = agent_fixture()
    binding_name = "scope-rollover"
    session_id = "group-scope-rollover"
    now = DateTime.utc_now(:microsecond)

    assert {:ok, binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: binding_name,
               adapter: "lark",
               config_ref: "app-config://scope-rollover",
               unaddressed_group_message_policy: :record_only,
               unmatched_sender_policy: :create_standalone,
               confidential_memory: false
             })

    group =
      %Group{}
      |> Group.changeset(%{
        name: binding_name,
        display_name: binding_name,
        domain: :im_group,
        metadata:
          BindingMembership.project(
            %{},
            AdapterContext.new(
              agent_uid: agent.uid,
              binding_name: binding_name,
              adapter: "lark",
              user_name: "Lark"
            ),
            :joined,
            now
          )
      })
      |> Repo.insert!()

    channel =
      %Channel{}
      |> Channel.changeset(%{
        id: "lark:chat:scope-rollover",
        kind: :im_group,
        reply_mode: :entry,
        name: binding_name,
        principal_group_id: group.id,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
      |> Repo.insert!()

    first_event =
      append_group_actor_event!(agent.uid, binding_name, channel.id, session_id, "shared", now)

    assert {:ok, conversation} =
             Repo.transact(fn repo ->
               AIGatewayLink.ensure_and_lock_conversation_in_tx(
                 repo,
                 agent.uid,
                 session_id,
                 first_event
               )
             end)

    assert conversation.metadata["origin"] == %{
             "channel_id" => channel.id,
             "channel_kind" => "im_group"
           }

    binding
    |> Ecto.Changeset.change(confidential_memory: true)
    |> Repo.update!()

    second_event =
      append_group_actor_event!(agent.uid, binding_name, channel.id, session_id, "channel", now)

    assert {:ok, same_conversation} =
             Repo.transact(fn repo ->
               AIGatewayLink.ensure_and_lock_conversation_in_tx(
                 repo,
                 agent.uid,
                 session_id,
                 second_event
               )
             end)

    assert same_conversation.id == conversation.id
    assert same_conversation.metadata["origin"] == conversation.metadata["origin"]
    refute Repo.get!(Conversation, conversation.id).ended_at
  end

  test "missing schedule delivery channels leave the conversation origin undeclared" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    for type <- ["check_back_later.wakeup", "cron.fire"] do
      {:ok, actor_event} =
        SignalsGateway.append_actor_event(%{
          agent_uid: agent.uid,
          binding_name: "schedule",
          session_id: "#{type}-#{Ecto.UUID.generate()}",
          source_event_id: "event-#{Ecto.UUID.generate()}",
          signal_channel_id: "missing:schedule:channel",
          source_entry_id: "schedule-#{Ecto.UUID.generate()}",
          type: type,
          available_at: now,
          sender_key: "schedule",
          payload: %{}
        })

      assert {:ok, conversation} =
               Repo.transact(fn repo ->
                 AIGatewayLink.ensure_and_lock_conversation_in_tx(
                   repo,
                   agent.uid,
                   actor_event.session_id,
                   actor_event
                 )
               end)

      refute Map.has_key?(conversation.metadata, "origin")
    end
  end

  test "missing ingress channels remain a hard conversation-origin error" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)
    channel_id = "missing:ingress:channel"

    {:ok, actor_event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent.uid,
        binding_name: "test",
        session_id: "missing-ingress-channel",
        source_event_id: "event-#{Ecto.UUID.generate()}",
        signal_channel_id: channel_id,
        source_entry_id: "message-#{Ecto.UUID.generate()}",
        type: "im.message.addressed",
        available_at: now,
        sender_key: "human-one",
        payload: %{}
      })

    assert {:error, {:conversation_origin_channel_not_found, ^channel_id}} =
             Repo.transact(fn repo ->
               AIGatewayLink.ensure_and_lock_conversation_in_tx(
                 repo,
                 agent.uid,
                 actor_event.session_id,
                 actor_event
               )
             end)
  end

  defp start_response(subject_uid, conversation_id, request_metadata) do
    StatefulResponses.start_response_run(%{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      metadata: %{"request_metadata" => request_metadata}
    })
  end

  defp append_current_actor_event!(agent_uid, session_id) do
    assert {:ok, event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent_uid,
               binding_name: "test",
               session_id: session_id,
               source_event_id: "current-#{Ecto.UUID.generate()}",
               type: "im.message.addressed",
               available_at: DateTime.utc_now(:microsecond),
               payload: %{"data" => %{"text" => "continue"}}
             })

    event
  end

  defp insert_waiting_job!(agent_uid, session_id, current_event) do
    now = DateTime.utc_now(:microsecond)

    %{rows: [[job_id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('background_agent_jobs', 'id'))")

    %Job{id: job_id}
    |> Job.creation_changeset(%{
      agent_uid: agent_uid,
      owner_session_id: session_id,
      source_actor_event_id: current_event.id,
      source_tool_call_id: "create-#{Ecto.UUID.generate()}",
      workspace_owner_job_id: job_id,
      runtime_thread_id: "thread-#{Ecto.UUID.generate()}",
      title: "Waiting Job",
      task: "Wait for input.",
      reply_route: %{"binding_name" => "test"},
      attempts: 1,
      status: "waiting_on_user",
      queued_at: now,
      started_at: now,
      result: %{},
      error: %{},
      metadata: %{"pending_user_input" => %{"questions" => []}}
    })
    |> Repo.insert!()
  end

  defp append_waiting_lifecycle_event!(job) do
    assert {:ok, event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: job.agent_uid,
               binding_name: "test",
               session_id: job.owner_session_id,
               source_event_id: "background_agent_job:#{job.id}:waiting:#{job.attempts}",
               type: "background_agent_job.waiting",
               available_at: DateTime.utc_now(:microsecond),
               payload: %{
                 "data" => %{
                   "job_id" => job.id,
                   "attempts" => job.attempts,
                   "status" => job.status
                 }
               }
             })

    event
  end

  defp tool_result_anchor!(subject_uid, session_id, current_event_id) do
    {:ok, conversation} = Conversations.ensure_conversation(subject_uid, session_id)

    {:ok, anchor} =
      start_response(subject_uid, conversation.id, %{"actor_event_id" => current_event_id})

    {:ok, anchor} =
      StatefulResponses.commit_complete(anchor, [
        %{
          "type" => "function_call",
          "call_id" => "call_send",
          "name" => "send_message_to_background_job",
          "arguments" => "{}"
        }
      ])

    {conversation, anchor}
  end

  defp tool_result_request(anchor, current_event_id, lifecycle_event_id, call_id) do
    %{
      "previous_response_id" => "resp_#{anchor.id}",
      "input" => [
        %{
          "type" => "function_call_output",
          "call_id" => call_id,
          "output" => "Last turn trajectory:\n{}"
        }
      ],
      "metadata" => %{"actor_event_id" => current_event_id},
      "complete_actor_event_ids" => [lifecycle_event_id]
    }
  end

  defp append_group_actor_event!(
         agent_uid,
         binding_name,
         channel_id,
         session_id,
         suffix,
         now
       ) do
    assert {:ok, actor_event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent_uid,
               binding_name: binding_name,
               session_id: session_id,
               source_event_id: "event-#{suffix}-#{Ecto.UUID.generate()}",
               signal_channel_id: channel_id,
               source_entry_id: "message-#{suffix}",
               type: "im.message.addressed",
               available_at: now,
               sender_key: "human-one",
               payload: %{}
             })

    actor_event
  end
end
