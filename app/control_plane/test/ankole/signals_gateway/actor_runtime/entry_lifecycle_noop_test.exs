defmodule Ankole.SignalsGateway.ActorRuntime.EntryLifecycleNoopTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.ReplyPresentation

  setup do
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    :ok
  end

  test "tail entry removal hard deletes current visible actor-event rows" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "tail-source-event",
        source_entry_id: "tail-source-message",
        text: "tail request",
        explicit: true
      })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, input.session_id)

    first =
      start_and_commit_round!(
        agent.uid,
        input.id,
        conversation_id: conversation.id,
        request_items: [user_item("tail request")],
        terminal_items: [
          %{
            "type" => "function_call",
            "call_id" => "call_tail",
            "name" => "lookup",
            "arguments" => "{}"
          }
        ]
      )

    final =
      start_and_commit_round!(
        agent.uid,
        input.id,
        previous_response_id: "resp_#{first.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_tail",
            "output" => "ok"
          }
        ],
        terminal_items: [assistant_item("tail answer")],
        complete_turn: true
      )

    assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at
    assert StatefulResponses.latest_visible_leaf(conversation.id) == final.id

    lifecycle_event = emit_removed_lifecycle!(agent.uid, input, "tail-remove-event")

    assert {:ok,
            %{
              status: :entry_lifecycle_ignored,
              lifecycle_event: processed_input,
              aigateway_deletions: [
                %{
                  status: :deleted,
                  deleted_message_ids: deleted_message_ids,
                  deleted_count: 2
                }
              ]
            }} =
             process_ready_events_once(now: DateTime.add(@base_time, 2, :second))

    assert processed_input.id == lifecycle_event.id
    assert MapSet.new(deleted_message_ids) == MapSet.new([first.id, final.id])
    refute Repo.get(Message, first.id)
    refute Repo.get(Message, final.id)
    assert StatefulResponses.latest_visible_leaf(conversation.id) == nil
    assert StatefulResponses.expand_history(conversation.id) == []
    assert %DateTime{} = Repo.get!(ActorEvent, lifecycle_event.id).completed_at
    refute_retracted_note("tail-remove-event")
  end

  test "tail entry removal terminalizes generating descendants before hard delete" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "tail-generating-source-event",
        source_entry_id: "tail-generating-source-message",
        text: "tail request with stale child",
        explicit: true
      })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, input.session_id)

    anchor =
      start_and_commit_round!(
        agent.uid,
        input.id,
        conversation_id: conversation.id,
        request_items: [user_item("tail request with stale child")],
        terminal_items: [assistant_item("tail answer")],
        complete_turn: true
      )

    assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at

    assert {:ok, stale_child} =
             start_response_run(%{
               subject_uid: agent.uid,
               previous_response_id: "resp_#{anchor.id}",
               metadata: %{"request_metadata" => %{"actor_event_id" => input.id}},
               request_items: [
                 %{
                   "type" => "function_call_output",
                   "call_id" => "call_after_tail",
                   "output" => "late"
                 }
               ]
             })

    assert stale_child.previous_message_id == anchor.id

    lifecycle_event = emit_removed_lifecycle!(agent.uid, input, "tail-generating-remove-event")

    assert {:ok,
            %{
              status: :entry_lifecycle_ignored,
              lifecycle_event: processed_input,
              aigateway_deletions: [
                %{
                  status: :deleted,
                  deleted_message_ids: [deleted_message_id],
                  deleted_count: 1,
                  failed_generating_message_ids: [failed_message_id],
                  failed_generating_count: 1
                }
              ]
            }} =
             process_ready_events_once(now: DateTime.add(@base_time, 2, :second))

    assert processed_input.id == lifecycle_event.id
    assert deleted_message_id == anchor.id
    assert failed_message_id == stale_child.id
    refute Repo.get(Message, anchor.id)

    failed_child = Repo.get!(Message, stale_child.id)
    assert failed_child.status == "error"
    assert failed_child.previous_message_id == nil
    assert get_in(failed_child.metadata, ["error", "code"]) == "source_entry_removed"

    assert {:ok, :already_terminal} =
             StatefulResponses.commit_complete(stale_child.id, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_after_tail_late",
                 "name" => "lookup",
                 "arguments" => "{}"
               }
             ])

    assert StatefulResponses.latest_visible_leaf(conversation.id) == nil
    assert %DateTime{} = Repo.get!(ActorEvent, lifecycle_event.id).completed_at
  end

  test "historical entry removal leaves later AIGateway rows untouched" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    old_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "historical-source-event",
        source_entry_id: "historical-source-message",
        text: "old fact",
        explicit: true
      })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, old_input.session_id)

    old_message =
      start_and_commit_round!(
        agent.uid,
        old_input.id,
        conversation_id: conversation.id,
        request_items: [user_item("old fact")],
        terminal_items: [assistant_item("old answer")],
        complete_turn: true
      )

    new_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "newer-source-event",
        source_entry_id: "newer-source-message",
        text: "new fact",
        explicit: true,
        provider_time: DateTime.add(@base_time, 1, :second)
      })

    new_message =
      start_and_commit_round!(
        agent.uid,
        new_input.id,
        previous_response_id: "resp_#{old_message.id}",
        request_items: [user_item("new fact")],
        terminal_items: [assistant_item("new answer")],
        complete_turn: true
      )

    open_card_chain!(old_input, ["historical-card-message"])
    lifecycle_event = emit_removed_lifecycle!(agent.uid, old_input, "historical-remove-event")

    assert {:ok,
            %{
              status: :entry_lifecycle_ignored,
              lifecycle_event: processed_input,
              reply_deletions: 0,
              aigateway_deletions: [
                %{
                  status: :noop,
                  reason: :not_visible_tail,
                  deleted_message_ids: [],
                  deleted_count: 0
                }
              ]
            }} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert processed_input.id == lifecycle_event.id
    assert deletion_targets(agent.uid, lifecycle_event.id) == []
    assert Repo.get(Message, old_message.id)
    assert Repo.get(Message, new_message.id)
    assert StatefulResponses.latest_visible_leaf(conversation.id) == new_message.id

    assert Enum.map(StatefulResponses.expand_history(conversation.id), & &1.id) == [
             old_message.id,
             new_message.id
           ]

    refute_retracted_note("historical-remove-event")
  end

  test "compaction-covered entry removal leaves derived history untouched" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    old_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "covered-source-event",
        source_entry_id: "covered-source-message",
        text: "covered fact",
        explicit: true
      })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, old_input.session_id)

    old_message =
      start_and_commit_round!(
        agent.uid,
        old_input.id,
        conversation_id: conversation.id,
        request_items: [user_item("covered fact")],
        terminal_items: [assistant_item("covered answer")],
        complete_turn: true
      )

    tail_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "tail-after-covered-event",
        source_entry_id: "tail-after-covered-message",
        text: "tail after covered fact",
        explicit: true,
        provider_time: DateTime.add(@base_time, 1, :second)
      })

    tail_message =
      start_and_commit_round!(
        agent.uid,
        tail_input.id,
        previous_response_id: "resp_#{old_message.id}",
        request_items: [user_item("tail after covered fact")],
        terminal_items: [assistant_item("tail after covered answer")],
        complete_turn: true
      )

    {:ok, artifact} =
      CompactionArtifacts.insert_artifact(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        summary_text: "covered prefix",
        retained_items: tail_message.content,
        retention: %{"strategy" => "tail_rows", "requested" => 1, "actual" => 1},
        usage: %{}
      })

    {:ok, compaction} =
      StatefulResponses.create_compaction_checkpoint(%{
        subject_uid: agent.uid,
        previous_response_id: "resp_#{tail_message.id}",
        artifact: artifact,
        metadata: %{"test" => "entry_lifecycle"}
      })

    lifecycle_event = emit_removed_lifecycle!(agent.uid, old_input, "covered-remove-event")

    assert {:ok,
            %{
              status: :entry_lifecycle_ignored,
              lifecycle_event: processed_input,
              aigateway_deletions: [
                %{
                  status: :noop,
                  reason: :actor_event_not_visible,
                  deleted_message_ids: [],
                  deleted_count: 0
                }
              ]
            }} =
             process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

    assert processed_input.id == lifecycle_event.id
    assert Repo.get(Message, old_message.id)
    assert Repo.get(Message, tail_message.id)
    assert Repo.get(Message, compaction.id)
    assert StatefulResponses.latest_visible_leaf(conversation.id) == compaction.id

    assert Enum.map(StatefulResponses.expand_history(conversation.id), & &1.id) == [
             compaction.id
           ]

    refute_retracted_note("covered-remove-event")
  end

  test "removing the source entry supersedes its pending clarification" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "clarification-source-event",
        source_entry_id: "clarification-source-message",
        text: "request needing clarification",
        explicit: true
      })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, input.session_id)

    _answer =
      start_and_commit_round!(
        agent.uid,
        input.id,
        conversation_id: conversation.id,
        request_items: [user_item("request needing clarification")],
        terminal_items: [assistant_item("Please choose one option")],
        complete_turn: true
      )

    open_pending_interaction!(input)
    lifecycle_event = emit_removed_lifecycle!(agent.uid, input, "clarification-recalled")

    assert {:ok, %{status: :entry_lifecycle_ignored}} =
             process_ready_events_once(now: DateTime.add(@base_time, 2, :second))

    checkpoint = Repo.get!(ActorEvent, input.id).reply_preview_checkpoint
    interaction = checkpoint["interactions"]["clarify:call-1"]

    assert interaction["state"] == "superseded"
    assert interaction["superseded_by_actor_event_id"] == lifecycle_event.id
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])
  end

  test "removing an unrelated source entry preserves a pending clarification" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    old_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "unrelated-source-event",
        source_entry_id: "unrelated-source-message",
        text: "an older completed request",
        explicit: true
      })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, old_input.session_id)

    old_answer =
      start_and_commit_round!(
        agent.uid,
        old_input.id,
        conversation_id: conversation.id,
        request_items: [user_item("an older completed request")],
        terminal_items: [assistant_item("older answer")],
        complete_turn: true
      )

    clarification_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "current-clarification-event",
        source_entry_id: "current-clarification-message",
        text: "a later request needing clarification",
        explicit: true,
        provider_time: DateTime.add(@base_time, 2, :second)
      })

    _clarification_answer =
      start_and_commit_round!(
        agent.uid,
        clarification_input.id,
        previous_response_id: "resp_#{old_answer.id}",
        request_items: [user_item("a later request needing clarification")],
        terminal_items: [assistant_item("Please choose one option")],
        complete_turn: true
      )

    open_pending_interaction!(clarification_input)
    _lifecycle_event = emit_removed_lifecycle!(agent.uid, old_input, "unrelated-recalled")

    assert {:ok, %{status: :entry_lifecycle_ignored}} =
             process_ready_events_once(now: DateTime.add(@base_time, 4, :second))

    checkpoint = Repo.get!(ActorEvent, clarification_input.id).reply_preview_checkpoint
    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
    assert checkpoint["presentation"]["interaction_status"] == "pending"
    refute Enum.any?(checkpoint["presentation"]["actions"], & &1["disabled"])
  end

  test "recalling the source entry mid turn deletes the cards that turn opened" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "open-card-source-event",
        source_entry_id: "open-card-source-message",
        text: "request answered by a still open card",
        explicit: true
      })

    open_card_chain!(input, ["card-message-1", "card-message-2"])

    assert {:ok, %{canceled_actor_events: 1, runtime_retractions: retractions}} =
             remove_source_entry!(agent.uid, input, "open-card-recalled")

    assert [%{status: :canceled, reply_deletions: 2}] = retractions.results
    assert retractions.canceled_actor_event_ids == [input.id]
    refute Repo.get(ActorEvent, input.id)

    assert deletion_targets(agent.uid, input.id) == ["card-message-1", "card-message-2"]
  end

  test "removing the source entry deletes the delivered reply it produced" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "delivered-reply-source-event",
        source_entry_id: "delivered-reply-source-message",
        text: "request answered in full",
        explicit: true
      })

    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, input.session_id)

    answer =
      start_and_commit_round!(
        agent.uid,
        input.id,
        conversation_id: conversation.id,
        request_items: [user_item("request answered in full")],
        terminal_items: [assistant_item("the answer")],
        complete_turn: true
      )

    mirror_delivered_reply!(input, "delivered-reply-message", answer.id)

    lifecycle_event = emit_removed_lifecycle!(agent.uid, input, "delivered-reply-recalled")

    assert {:ok, %{status: :entry_lifecycle_ignored, reply_deletions: 1}} =
             process_ready_events_once(now: DateTime.add(@base_time, 2, :second))

    assert deletion_targets(agent.uid, lifecycle_event.id) == ["delivered-reply-message"]
  end

  defp open_card_chain!(input, message_ids) do
    cards =
      message_ids
      |> Enum.with_index()
      |> Enum.map(fn {message_id, index} ->
        %{
          "index" => index,
          "card_id" => "card-#{index}-#{input.id}",
          "message_id" => message_id,
          "state" => "open",
          "streaming_state" => "open"
        }
      end)

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "cards" => cards,
      "active_index" => length(cards) - 1,
      "streaming_state" => "open"
    }

    assert {:ok, _updated} = Actors.put_reply_preview_checkpoint(input.id, checkpoint)
  end

  defp mirror_delivered_reply!(input, source_entry_id, ai_message_id) do
    assert {:ok, _entry} =
             %Entry{}
             |> Entry.changeset(%{
               signal_channel_id: input.signal_channel_id,
               source_entry_id: source_entry_id,
               reply_to_source_entry_id: input.source_entry_id,
               provider_thread_id: input.provider_thread_id,
               text: "the answer",
               ai_message_id: ai_message_id,
               document_id:
                 Projection.entry_document_id(input.signal_channel_id, source_entry_id),
               content_hash: Projection.entry_content_hash(["the answer"]),
               first_seen_at: @base_time,
               last_seen_at: @base_time
             })
             |> Repo.insert()
  end

  defp deletion_targets(agent_uid, lifecycle_event_id) do
    OutboxEntry
    |> where([outbox], outbox.agent_uid == ^agent_uid)
    |> where([outbox], outbox.operation == :delete)
    |> where([outbox], outbox.source_actor_event_id == ^lifecycle_event_id)
    |> select([outbox], outbox.target_source_entry_id)
    |> Repo.all()
    |> Enum.sort()
  end

  defp create_signal_input!(agent_uid, overrides) do
    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(overrides),
               now: Map.get(overrides, :provider_time, @base_time)
             )

    now = Map.get(overrides, :provider_time, @base_time)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(now, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    turn_ref = turn_start_payload!(envelope).turn

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(turn_ref))

    Process.put({__MODULE__, input.id}, turn_ref)

    input
  end

  defp emit_removed_lifecycle!(agent_uid, input, source_event_id, opts \\ []) do
    assert {:ok, %{canceled_actor_events: 0, lifecycle_events: [lifecycle_event]}} =
             remove_source_entry!(agent_uid, input, source_event_id, opts)

    lifecycle_event
  end

  defp remove_source_entry!(agent_uid, input, source_event_id, opts \\ []) do
    Ingress.emit_entry_removed(
      agent_uid,
      "bot",
      lifecycle_entry(%{
        source_event_id: source_event_id,
        signal_channel_id: input.signal_channel_id,
        source_entry_id: Keyword.get(opts, :source_entry_id, input.source_entry_id),
        provider_thread_id: input.provider_thread_id
      }),
      provider_lifecycle_kind: :recalled,
      now: DateTime.add(@base_time, 1, :second)
    )
  end

  defp open_pending_interaction!(input) do
    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => "Which option should I use?",
        "controls" => [
          %{
            "id" => "operators",
            "type" => "button",
            "label" => "Operators",
            "interaction_id" => "clarify:call-1",
            "source_actor_event_id" => input.id,
            "control_id" => "clarify-choice",
            "selected_option_id" => "operators",
            "option_value" => "Operators",
            "revision" => 1
          }
        ]
      })

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-#{input.id}",
      "message_id" => "card-message-#{input.id}",
      "streaming_state" => "closed",
      "presentation" => ReplyPresentation.checkpoint(presentation),
      "interactions" => %{
        "clarify:call-1" => %{
          "interaction_id" => "clarify:call-1",
          "state" => "pending",
          "opened_at" => DateTime.to_iso8601(@base_time)
        }
      }
    }

    assert {:ok, _updated} = Actors.put_reply_preview_checkpoint(input.id, checkpoint)
  end

  defp start_and_commit_round!(agent_uid, actor_event_id, opts) do
    attrs =
      %{
        subject_uid: agent_uid,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}},
        request_items: Keyword.fetch!(opts, :request_items)
      }
      |> maybe_put(:conversation_id, Keyword.get(opts, :conversation_id))
      |> maybe_put(:previous_response_id, Keyword.get(opts, :previous_response_id))

    assert {:ok, run} = start_response_run(attrs)

    assert {:ok, complete} =
             StatefulResponses.commit_complete(run, Keyword.fetch!(opts, :terminal_items))

    if Keyword.get(opts, :complete_turn, false) do
      turn_ref = Process.get({__MODULE__, actor_event_id})

      assert {:ok, %{status: :turn_completed}} =
               commit_turn_completion(turn_ref, "resp_#{complete.id}", "loop_finished")
    end

    complete
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp user_item(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp assistant_item(text) do
    %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
  end

  defp refute_retracted_note(source_event_id) do
    refute Repo.exists?(
             from(message in Message,
               where: fragment("?->>'event_id'", message.metadata) == ^source_event_id
             )
           )
  end
end
