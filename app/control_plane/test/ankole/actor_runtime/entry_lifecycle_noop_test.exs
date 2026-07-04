defmodule Ankole.ActorRuntime.EntryLifecycleNoopTest do
  use Ankole.ActorRuntimeCase

  alias Ankole.AIGateway.StatefulResponses

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

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, input.session_id)

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
        terminal_items: [assistant_item("tail answer")]
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

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, input.session_id)

    anchor =
      start_and_commit_round!(
        agent.uid,
        input.id,
        conversation_id: conversation.id,
        request_items: [user_item("tail request with stale child")],
        terminal_items: [assistant_item("tail answer")]
      )

    assert %DateTime{} = Repo.get!(ActorEvent, input.id).completed_at

    assert {:ok, stale_child} =
             StatefulResponses.start_response_run(%{
               agent_uid: agent.uid,
               previous_response_id: "resp_#{anchor.id}",
               actor_event_id: input.id,
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

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, old_input.session_id)

    old_message =
      start_and_commit_round!(
        agent.uid,
        old_input.id,
        conversation_id: conversation.id,
        request_items: [user_item("old fact")],
        terminal_items: [assistant_item("old answer")]
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
        terminal_items: [assistant_item("new answer")]
      )

    lifecycle_event = emit_removed_lifecycle!(agent.uid, old_input, "historical-remove-event")

    assert {:ok,
            %{
              status: :entry_lifecycle_ignored,
              lifecycle_event: processed_input,
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

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, old_input.session_id)

    old_message =
      start_and_commit_round!(
        agent.uid,
        old_input.id,
        conversation_id: conversation.id,
        request_items: [user_item("covered fact")],
        terminal_items: [assistant_item("covered answer")]
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
        terminal_items: [assistant_item("tail after covered answer")]
      )

    {:ok, compaction} =
      StatefulResponses.compact_history_prefix(
        agent.uid,
        "resp_#{tail_message.id}",
        "resp_#{old_message.id}",
        %{"type" => "compaction", "summary" => "covered prefix"},
        %{"test" => "entry_lifecycle"}
      )

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
             compaction.id,
             tail_message.id
           ]

    refute_retracted_note("covered-remove-event")
  end

  defp create_signal_input!(agent_uid, overrides) do
    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(overrides),
               now: Map.get(overrides, :provider_time, @base_time)
             )

    input
  end

  defp emit_removed_lifecycle!(agent_uid, input, source_event_id) do
    assert {:ok, %{canceled_actor_events: 0, lifecycle_events: [lifecycle_event]}} =
             SignalsGateway.emit_entry_removed(
               agent_uid,
               "bot",
               lifecycle_entry(%{
                 source_event_id: source_event_id,
                 signal_channel_id: input.signal_channel_id,
                 source_entry_id: input.source_entry_id,
                 provider_thread_id: input.provider_thread_id
               }),
               provider_lifecycle_kind: :recalled,
               now: DateTime.add(@base_time, 1, :second)
             )

    lifecycle_event
  end

  defp start_and_commit_round!(agent_uid, actor_event_id, opts) do
    attrs =
      %{
        agent_uid: agent_uid,
        actor_event_id: actor_event_id,
        request_items: Keyword.fetch!(opts, :request_items)
      }
      |> maybe_put(:conversation_id, Keyword.get(opts, :conversation_id))
      |> maybe_put(:previous_response_id, Keyword.get(opts, :previous_response_id))

    assert {:ok, run} = StatefulResponses.start_response_run(attrs)

    assert {:ok, complete} =
             StatefulResponses.commit_complete(run, Keyword.fetch!(opts, :terminal_items))

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
