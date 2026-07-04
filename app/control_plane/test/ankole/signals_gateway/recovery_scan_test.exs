defmodule Ankole.SignalsGateway.RecoveryScanTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures
  import ExUnit.CaptureLog

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Actors.ActorEvent
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockSignalProviderOutbox
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.RecoveryScan
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  setup :use_mock_signal_provider_plugin

  describe "find_orphaned_terminals/0" do
    test "does not depend on hard-coded SQL aliases" do
      assert [] = RecoveryScan.find_orphaned_terminals()
    end

    test "finds only IM-visible complete terminal rows without function calls or mirrors" do
      %{principal: agent} = agent_fixture()
      {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, "recovery-scan")
      event = actor_event_fixture(agent.uid, conversation.conversation_key)
      channel_fixture("recovery-scan-channel")

      complete = message_fixture(agent.uid, conversation.id, event, status: "complete")
      error = message_fixture(agent.uid, conversation.id, event, status: "error")

      empty =
        message_fixture(agent.uid, conversation.id, event,
          status: "complete",
          content: [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "   "}]
            }
          ]
        )

      silent_success =
        message_fixture(agent.uid, conversation.id, event,
          status: "complete",
          content: [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "<silent_success/>"}]
            }
          ]
        )

      input_only =
        message_fixture(agent.uid, conversation.id, event,
          status: "complete",
          content: [
            %{"role" => "user", "content" => "prompt only"}
          ]
        )

      input_plus_output =
        message_fixture(agent.uid, conversation.id, event,
          status: "complete",
          content: [
            %{"role" => "user", "content" => "prompt"},
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "visible answer"}]
            }
          ]
        )

      function_call =
        message_fixture(agent.uid, conversation.id, event,
          status: "complete",
          content: [%{"type" => "function_call", "call_id" => "call-1"}]
        )

      mirrored = message_fixture(agent.uid, conversation.id, event, status: "complete")
      signal_entry_fixture("recovery-scan-channel", "provider-final", mirrored.id)

      mark_stale([
        complete.id,
        error.id,
        empty.id,
        silent_success.id,
        input_only.id,
        input_plus_output.id,
        function_call.id,
        mirrored.id
      ])

      ids = RecoveryScan.find_orphaned_terminals() |> Enum.map(& &1.id)

      assert complete.id in ids
      assert input_plus_output.id in ids
      refute error.id in ids
      refute empty.id in ids
      refute silent_success.id in ids
      refute input_only.id in ids
      refute function_call.id in ids
      refute mirrored.id in ids
    end

    test "non-visible terminal rows cannot starve the bounded scan window" do
      %{principal: agent} = agent_fixture()
      {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, "recovery-starve")
      visible_event = actor_event_fixture(agent.uid, conversation.conversation_key)

      internal_event =
        actor_event_fixture(agent.uid, conversation.conversation_key, signal_channel_id: nil)

      channel_fixture("recovery-scan-channel")

      non_visible_ids =
        for index <- 1..30 do
          {event, status, content} =
            case rem(index, 3) do
              0 ->
                {visible_event, "error",
                 [
                   %{
                     "type" => "message",
                     "role" => "assistant",
                     "content" => [%{"type" => "output_text", "text" => "failed"}]
                   }
                 ]}

              1 ->
                {visible_event, "complete",
                 [
                   %{
                     "type" => "message",
                     "role" => "assistant",
                     "content" => [%{"type" => "output_text", "text" => "   "}]
                   }
                 ]}

              2 ->
                {internal_event, "complete",
                 [
                   %{
                     "type" => "message",
                     "role" => "assistant",
                     "content" => [%{"type" => "output_text", "text" => "internal"}]
                   }
                 ]}
            end

          message_fixture(agent.uid, conversation.id, event, status: status, content: content).id
        end

      visible = message_fixture(agent.uid, conversation.id, visible_event, status: "complete")
      mark_stale([visible.id | non_visible_ids])

      ids = RecoveryScan.find_orphaned_terminals() |> Enum.map(& &1.id)

      assert visible.id in ids
      refute Enum.any?(non_visible_ids, &(&1 in ids))
    end

    test "retry-suppressed terminal rows cannot starve the bounded scan window" do
      %{principal: agent} = agent_fixture()
      {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, "recovery-retry")
      channel_fixture("recovery-scan-channel")

      retried_ids =
        for _index <- 1..30 do
          retried_event = actor_event_fixture(agent.uid, conversation.conversation_key)

          actor_event_fixture(agent.uid, conversation.conversation_key,
            payload: %{
              "type" => "im.message.addressed",
              "data" => %{
                "entry" => %{
                  "retry_of_actor_event_id" => retried_event.id
                }
              }
            }
          )

          message_fixture(agent.uid, conversation.id, retried_event, status: "complete").id
        end

      visible_event = actor_event_fixture(agent.uid, conversation.conversation_key)
      visible = message_fixture(agent.uid, conversation.id, visible_event, status: "complete")
      mark_stale([visible.id | retried_ids])

      ids = RecoveryScan.find_orphaned_terminals() |> Enum.map(& &1.id)

      assert visible.id in ids
      refute Enum.any?(retried_ids, &(&1 in ids))
    end

    test "self-retry metadata does not suppress recovery for the same event" do
      %{principal: agent} = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.uid, "recovery-self-retry")

      channel_fixture("recovery-scan-channel")

      event = actor_event_fixture(agent.uid, conversation.conversation_key)

      event
      |> ActorEvent.changeset(%{
        payload: %{
          "type" => "im.message.addressed",
          "data" => %{
            "entry" => %{
              "retry_of_actor_event_id" => event.id,
              "retry_reason" => "command.retry"
            }
          }
        }
      })
      |> Repo.update!()

      message = message_fixture(agent.uid, conversation.id, event, status: "complete")
      mark_stale([message.id])

      ids = RecoveryScan.find_orphaned_terminals() |> Enum.map(& &1.id)

      assert message.id in ids
    end

    test "failed deliveries are deferred so later rows can enter the bounded scan window" do
      %{principal: agent} = agent_fixture()
      {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, "recovery-failures")
      channel_fixture("recovery-scan-channel")

      messages =
        for index <- 1..30 do
          event =
            actor_event_fixture(agent.uid, conversation.conversation_key,
              source_entry_id: "recovery-failure-entry-#{index}"
            )

          message_fixture(agent.uid, conversation.id, event, status: "complete")
        end

      mark_stale_in_order(Enum.map(messages, & &1.id))

      first_scan_ids = RecoveryScan.find_orphaned_terminals() |> Enum.map(& &1.id)
      assert length(first_scan_ids) == 25

      capture_log(fn ->
        assert RecoveryScan.run_once() == 25
      end)

      second_scan_ids = RecoveryScan.find_orphaned_terminals() |> Enum.map(& &1.id)
      assert length(second_scan_ids) == 5
      refute Enum.any?(first_scan_ids, &(&1 in second_scan_ids))
    end

    test "run_once delivers orphaned terminal replies and mirrors only after provider success" do
      MockSignalProviderOutbox.put_recipient(self())
      on_exit(fn -> MockSignalProviderOutbox.delete_recipient() end)

      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.uid, "recovery-action-path")

      signal_channel_id = "mock:chat:recovery-action-path"
      channel_fixture(signal_channel_id)

      event =
        actor_event_fixture(agent.uid, conversation.conversation_key,
          binding_name: "mock",
          signal_channel_id: signal_channel_id,
          source_event_id: "recovery-action-event",
          source_entry_id: "human-recovery-action",
          provider_thread_id: "mock-thread-recovery-action"
        )

      message =
        message_fixture(agent.uid, conversation.id, event,
          status: "complete",
          content: [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => " recovered answer "}]
            }
          ]
        )

      mark_stale([message.id])

      assert RecoveryScan.run_once() == 1

      assert_receive {:mock_provider_outbox_sent, outbox}
      assert outbox.operation == :reply
      assert outbox.ai_message_id == message.id
      assert outbox.outbound_key == "ai-reply:#{message.id}"
      assert outbox.idempotency_key == "ai-reply:#{message.id}"
      assert outbox.reply_to_source_entry_id == event.source_entry_id
      assert outbox.fallback_visible_text == "recovered answer"

      mirror = Repo.get_by!(SignalEntry, ai_message_id: message.id)
      assert mirror.signal_channel_id == signal_channel_id
      assert mirror.source_entry_id =~ "mock-reply-"
      assert mirror.text == "recovered answer"
      assert mirror.raw_payload == %{"provider" => "mock-signal-provider"}
      assert mirror.metadata["actor_event_id"] == event.id
      assert mirror.metadata["source"] == "ai_gateway_final_reply"
      assert mirror.metadata["provider_thread_id"] == event.provider_thread_id
      assert String.starts_with?(mirror.document_id, "signal-entry:")
      refute mirror.document_id == mirror.source_entry_id
      assert mirror.metadata_text =~ "ai_gateway_final_reply"
      assert mirror.content_hash && mirror.content_hash != ""

      assert RecoveryScan.run_once() == 0
      refute_receive {:mock_provider_outbox_sent, _outbox}, 100
    end
  end

  describe "final reply mirrors" do
    test "do not synthesize provider source ids" do
      %{principal: agent} = agent_fixture()
      {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, "final-mirror")
      event = actor_event_fixture(agent.uid, conversation.conversation_key)
      message = message_fixture(agent.uid, conversation.id, event, status: "complete")

      assert {:error, :final_reply_entry_id_missing} =
               AIReplyPreview.mirror_final_reply(event, message.id, "final text")

      refute Repo.exists?(
               from(entry in SignalEntry,
                 where: entry.ai_message_id == ^message.id
               )
             )

      channel_fixture(event.signal_channel_id)

      assert :ok =
               AIReplyPreview.mirror_final_reply(event, message.id, "final text",
                 source_entry_id: "provider-final"
               )

      assert Repo.get_by!(SignalEntry,
               signal_channel_id: event.signal_channel_id,
               source_entry_id: "provider-final"
             ).ai_message_id == message.id
    end
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        disabled_ids: MapSet.new()
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp actor_event_fixture(agent_uid, session_id, opts \\ []) do
    now = DateTime.utc_now(:microsecond)

    attrs =
      %{
        agent_uid: agent_uid,
        binding_name: "bot",
        session_id: session_id,
        source_event_id: "source-#{System.unique_integer([:positive])}",
        signal_channel_id: "recovery-scan-channel",
        provider_thread_id: "thread-1",
        source_entry_id: "incoming-1",
        type: "im.message.addressed",
        available_at: now,
        queue_sequence: System.unique_integer([:positive]),
        input_state: "open",
        payload: %{"text" => "hello"}
      }
      |> Map.merge(Map.new(opts))

    %ActorEvent{}
    |> ActorEvent.changeset(attrs)
    |> Repo.insert!()
  end

  defp message_fixture(agent_uid, conversation_id, %ActorEvent{} = event, opts) do
    attrs =
      %{
        agent_uid: agent_uid,
        conversation_id: conversation_id,
        role: "assistant",
        type: "message",
        status: Keyword.fetch!(opts, :status),
        content:
          Keyword.get(opts, :content, [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "hello"}]
            }
          ]),
        metadata: %{"actor_event_id" => event.id}
      }

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert!()
  end

  defp channel_fixture(id) do
    now = DateTime.utc_now(:microsecond)

    %SignalChannel{}
    |> SignalChannel.changeset(%{
      id: id,
      kind: :im_group,
      reply_mode: :entry,
      metadata: %{},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: :id
    )
  end

  defp signal_entry_fixture(signal_channel_id, source_entry_id, ai_message_id) do
    now = DateTime.utc_now(:microsecond)

    %SignalEntry{}
    |> SignalEntry.changeset(%{
      signal_channel_id: signal_channel_id,
      source_entry_id: source_entry_id,
      text: "already mirrored",
      fallback_visible_text: "already mirrored",
      formatted_content: %{},
      attachments: [],
      links: [],
      author: %{},
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: source_entry_id,
      first_seen_at: now,
      last_seen_at: now,
      ai_message_id: ai_message_id
    })
    |> Repo.insert!()
  end

  defp mark_stale(message_ids) do
    stale_at = DateTime.utc_now(:microsecond) |> DateTime.add(-120, :second)

    from(message in Message, where: message.id in ^message_ids)
    |> Repo.update_all(set: [updated_at: stale_at])
  end

  defp mark_stale_in_order(message_ids) do
    base = DateTime.utc_now(:microsecond) |> DateTime.add(-300, :second)

    message_ids
    |> Enum.with_index()
    |> Enum.each(fn {message_id, index} ->
      stale_at = DateTime.add(base, index, :second)

      from(message in Message, where: message.id == ^message_id)
      |> Repo.update_all(set: [updated_at: stale_at])
    end)
  end
end
