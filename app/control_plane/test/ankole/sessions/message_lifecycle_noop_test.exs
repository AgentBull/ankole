defmodule Ankole.Sessions.MessageLifecycleNoopTest do
  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ResponseChain
  use Ankole.SessionsCase

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Revisions
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.MessageLifecycle

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.Conversations.Delivery.ReplyPresentation

  setup do
    %{principal: agent} = agent_fixture()
    {:ok, agent: agent}
  end

  test "tail entry removal hard deletes current visible actor-event rows", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "tail-source-event",
        provider_message_id: "tail-source-message",
        text: "tail request",
        explicit: true
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, input.session_id)

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

    assert %DateTime{} = Repo.get!(Signal, input.id).completed_at
    assert ResponseChain.latest_visible_leaf(conversation.id) == final.id

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
             MessageLifecycle.process(lifecycle_event, now: DateTime.add(@base_time, 2, :second))

    assert processed_input.id == lifecycle_event.id
    assert MapSet.new(deleted_message_ids) == MapSet.new([first.id, final.id])
    refute Repo.get(Message, first.id)
    refute Repo.get(Message, final.id)
    assert ResponseChain.latest_visible_leaf(conversation.id) == nil
    assert ResponseChain.expand_history(conversation.id) == []
    assert %DateTime{} = Repo.get!(Signal, lifecycle_event.id).completed_at
    refute_retracted_note("tail-remove-event")
  end

  test "tail entry removal terminalizes generating descendants before hard delete", %{
    agent: agent
  } do
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "tail-generating-source-event",
        provider_message_id: "tail-generating-source-message",
        text: "tail request with stale child",
        explicit: true
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, input.session_id)

    anchor =
      start_and_commit_round!(
        agent.uid,
        input.id,
        conversation_id: conversation.id,
        request_items: [user_item("tail request with stale child")],
        terminal_items: [assistant_item("tail answer")],
        complete_turn: true
      )

    assert %DateTime{} = Repo.get!(Signal, input.id).completed_at

    assert {:ok, stale_child} =
             start_response_run(%{
               subject_uid: agent.uid,
               previous_response_id: "resp_#{anchor.id}",
               metadata: %{"request_metadata" => %{"signal_id" => input.id}},
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
             MessageLifecycle.process(lifecycle_event, now: DateTime.add(@base_time, 2, :second))

    assert processed_input.id == lifecycle_event.id
    assert deleted_message_id == anchor.id
    assert failed_message_id == stale_child.id
    refute Repo.get(Message, anchor.id)

    failed_child = Repo.get!(Message, stale_child.id)
    assert failed_child.status == :error
    assert failed_child.previous_message_id == nil
    assert get_in(failed_child.metadata, ["error", "code"]) == "source_entry_removed"

    assert {:ok, :already_terminal} =
             ResponseCommit.commit_complete(stale_child.id, [
               %{
                 "type" => "function_call",
                 "call_id" => "call_after_tail_late",
                 "name" => "lookup",
                 "arguments" => "{}"
               }
             ])

    assert ResponseChain.latest_visible_leaf(conversation.id) == nil
    assert %DateTime{} = Repo.get!(Signal, lifecycle_event.id).completed_at
  end

  test "historical entry removal leaves later AIGateway rows untouched", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :ignore)

    old_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "historical-source-event",
        provider_message_id: "historical-source-message",
        text: "old fact",
        explicit: true
      })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, old_input.session_id)

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
        provider_message_id: "newer-source-message",
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
             MessageLifecycle.process(lifecycle_event, now: DateTime.add(@base_time, 3, :second))

    assert processed_input.id == lifecycle_event.id
    assert deletion_targets(agent.uid, lifecycle_event.id) == []
    assert Repo.get(Message, old_message.id)
    assert Repo.get(Message, new_message.id)
    assert ResponseChain.latest_visible_leaf(conversation.id) == new_message.id

    assert Enum.map(ResponseChain.expand_history(conversation.id), & &1.id) == [
             old_message.id,
             new_message.id
           ]

    refute_retracted_note("historical-remove-event")
  end

  test "compaction-covered entry removal leaves derived history untouched", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :ignore)

    old_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "covered-source-event",
        provider_message_id: "covered-source-message",
        text: "covered fact",
        explicit: true
      })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, old_input.session_id)

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
        provider_message_id: "tail-after-covered-message",
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
      ResponseChain.create_compaction_checkpoint(%{
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
                  reason: :signal_not_visible,
                  deleted_message_ids: [],
                  deleted_count: 0
                }
              ]
            }} =
             MessageLifecycle.process(lifecycle_event, now: DateTime.add(@base_time, 3, :second))

    assert processed_input.id == lifecycle_event.id
    assert Repo.get(Message, old_message.id)
    assert Repo.get(Message, tail_message.id)
    assert Repo.get(Message, compaction.id)
    assert ResponseChain.latest_visible_leaf(conversation.id) == compaction.id

    assert Enum.map(ResponseChain.expand_history(conversation.id), & &1.id) == [
             compaction.id
           ]

    refute_retracted_note("covered-remove-event")
  end

  test "removing the source entry supersedes its pending clarification", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "clarification-source-event",
        provider_message_id: "clarification-source-message",
        text: "request needing clarification",
        explicit: true
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, input.session_id)

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
             MessageLifecycle.process(lifecycle_event, now: DateTime.add(@base_time, 2, :second))

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, input.id)).checkpoint

    interaction = checkpoint["interactions"]["clarify:call-1"]

    assert interaction["state"] == "superseded"
    assert interaction["superseded_by_signal_id"] == lifecycle_event.id
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])
  end

  test "removing an unrelated source entry preserves a pending clarification", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :ignore)

    old_input =
      create_signal_input!(agent.uid, %{
        source_event_id: "unrelated-source-event",
        provider_message_id: "unrelated-source-message",
        text: "an older completed request",
        explicit: true
      })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, old_input.session_id)

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
        provider_message_id: "current-clarification-message",
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
    lifecycle_event = emit_removed_lifecycle!(agent.uid, old_input, "unrelated-recalled")

    assert {:ok, %{status: :entry_lifecycle_ignored}} =
             MessageLifecycle.process(lifecycle_event, now: DateTime.add(@base_time, 4, :second))

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, clarification_input.id)).checkpoint

    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
    assert checkpoint["presentation"]["interaction_status"] == "pending"
    refute Enum.any?(checkpoint["presentation"]["actions"], & &1["disabled"])
  end

  test "recalling the source entry mid turn deletes the cards that turn opened", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "open-card-source-event",
        provider_message_id: "open-card-source-message",
        text: "request answered by a still open card",
        explicit: true
      })

    open_card_chain!(input, ["card-message-1", "card-message-2"])

    assert {:ok, %{canceled_signals: 0}} =
             remove_source_entry!(agent.uid, input, "open-card-recalled")

    revision =
      Repo.get_by!(Signal,
        agent_uid: agent.uid,
        session_id: input.session_id,
        type: "input.revised"
      )

    assert {:ok, :stopped} = Revisions.apply(Process.get({__MODULE__, input.id}), revision)
    refute Repo.get(Signal, input.id)

    assert deletion_targets(agent.uid, input.id) == ["card-message-1", "card-message-2"]
  end

  test "removing the source entry deletes the delivered reply it produced", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :ignore)

    input =
      create_signal_input!(agent.uid, %{
        source_event_id: "delivered-reply-source-event",
        provider_message_id: "delivered-reply-source-message",
        text: "request answered in full",
        explicit: true
      })

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, input.session_id)

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
             MessageLifecycle.process(lifecycle_event, now: DateTime.add(@base_time, 2, :second))

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

    assert {:ok, _updated} =
             PreviewStates.put_checkpoint(input.id, checkpoint)
  end

  defp mirror_delivered_reply!(input, provider_message_id, ai_message_id) do
    assert {:ok, _message} =
             Repo.transact(fn repo ->
               Ankole.Conversations.External.record_delivery_in_tx(
                 repo,
                 input.conversation_id,
                 %{
                   provider_message_id: provider_message_id,
                   reply_to_provider_message_id: input.provider_message_id,
                   provider_thread_id: input.provider_thread_id,
                   text: "the answer",
                   author: %{principal_uid: input.agent_uid},
                   session_id: input.session_id,
                   signal_id: input.id,
                   ai_message_id: ai_message_id
                 },
                 @base_time
               )
             end)
  end

  defp deletion_targets(agent_uid, lifecycle_event_id) do
    Intent
    |> where([intent], intent.agent_uid == ^agent_uid)
    |> where([intent], intent.operation == :delete)
    |> where([intent], intent.source_signal_id == ^lifecycle_event_id)
    |> select([intent], intent.target_provider_message_id)
    |> Repo.all()
    |> Enum.sort()
  end

  defp create_signal_input!(agent_uid, overrides) do
    assert {:ok, %{signal: input}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(overrides),
               now: Map.get(overrides, :provider_time, @base_time)
             )

    assert {:ok, run} =
             Admission.admit(
               %{agent_uid: agent_uid, session_id: input.session_id},
               input
             )

    Process.put({__MODULE__, input.id}, run)

    input
  end

  defp emit_removed_lifecycle!(agent_uid, input, source_event_id, opts \\ []) do
    assert {:ok, %{canceled_signals: 0, lifecycle_events: [lifecycle_event]}} =
             remove_source_entry!(agent_uid, input, source_event_id, opts)

    lifecycle_event
  end

  defp remove_source_entry!(agent_uid, input, source_event_id, opts \\ []) do
    Observe.emit_entry_removed(
      agent_uid,
      "bot",
      lifecycle_entry(%{
        source_event_id: source_event_id,
        provider_conversation_id:
          Repo.get_by!(Ankole.Conversations.Conversation, id: input.conversation_id).provider_conversation_id,
        provider_message_id: Keyword.get(opts, :provider_message_id, input.provider_message_id),
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
            "source_signal_id" => input.id,
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

    assert {:ok, _updated} =
             PreviewStates.put_checkpoint(input.id, checkpoint)
  end

  defp start_and_commit_round!(agent_uid, signal_id, opts) do
    attrs =
      %{
        subject_uid: agent_uid,
        metadata: %{"request_metadata" => %{"signal_id" => signal_id}},
        request_items: Keyword.fetch!(opts, :request_items)
      }
      |> maybe_put(:conversation_id, Keyword.get(opts, :conversation_id))
      |> maybe_put(:previous_response_id, Keyword.get(opts, :previous_response_id))

    assert {:ok, run} = start_response_run(attrs)

    assert {:ok, complete} =
             ResponseCommit.commit_complete(run, Keyword.fetch!(opts, :terminal_items))

    if Keyword.get(opts, :complete_turn, false) do
      run = Process.get({__MODULE__, signal_id})

      assert {:ok, _} =
               Run.finalize(
                 %{run | anchor: complete.id, model_response: complete},
                 :loop_finished
               )
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
