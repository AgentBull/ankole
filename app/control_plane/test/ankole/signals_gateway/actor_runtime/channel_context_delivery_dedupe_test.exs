defmodule Ankole.SignalsGateway.ActorRuntime.ChannelContextDeliveryDedupeTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Conversations
  alias Ankole.Conversations.{Admission, Run}

  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.SignalsGateway.ChannelContext

  setup :use_mock_signal_provider_plugin

  describe "drop_visible_messages/2" do
    test "keeps a payload without channel context unchanged" do
      payload = %{"data" => %{"entries" => []}}

      assert ChannelContext.drop_visible_messages(payload, MapSet.new([{"c", "m"}])) == payload
    end

    test "drops only the visible messages and keeps the rest" do
      payload = context_payload([message("c1", "seen"), message("c1", "fresh")])

      filtered = ChannelContext.drop_visible_messages(payload, MapSet.new([{"c1", "seen"}]))

      assert [%{"source_entry_id" => "fresh"}] =
               get_in(filtered, ["data", "channel_context", "messages"])
    end

    test "removes the whole block when every message is visible" do
      payload = context_payload([message("c1", "seen")])

      filtered = ChannelContext.drop_visible_messages(payload, MapSet.new([{"c1", "seen"}]))

      refute Map.has_key?(filtered["data"], "channel_context")
    end

    test "keeps a message that lacks the reference fields" do
      payload = context_payload([%{"text" => "no ids"}])

      assert ChannelContext.drop_visible_messages(payload, MapSet.new([{"c1", "seen"}])) ==
               payload
    end
  end

  test "a queued consecutive turn is delivered without the quotes its predecessor already carried" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :record_only,
      adapter: "mock-provider"
    )

    channel_id = "mock:chat:context-dedupe"

    assert {:ok, %{status: :recorded}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 signal_channel_id: channel_id,
                 source_entry_id: "backdrop-1",
                 text: "backdrop one",
                 explicit: false,
                 provider_time: @base_time
               }),
               now: @base_time
             )

    {:ok, %{actor_event: first_event}} =
      emit_entry(
        agent.uid,
        "mock",
        group_entry(%{
          signal_channel_id: channel_id,
          source_entry_id: "addressed-1",
          text: "first question",
          explicit: true,
          provider_time: DateTime.add(@base_time, 1, :second)
        }),
        now: DateTime.add(@base_time, 1, :second)
      )

    assert {:ok, first_run} =
             Admission.admit(
               %{agent_uid: agent.uid, session_id: first_event.session_id},
               first_event
             )

    assert ["backdrop-1"] = delivered_context_entry_ids(first_run)

    # While the first turn is still generating, one more backdrop message and
    # the next addressed message arrive. The appended event quotes everything,
    # because the racing append-time exclusion cannot see an unfinished turn.
    assert {:ok, %{status: :recorded}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 signal_channel_id: channel_id,
                 source_entry_id: "backdrop-2",
                 text: "backdrop two",
                 explicit: false,
                 provider_time: DateTime.add(@base_time, 12, :second)
               }),
               now: DateTime.add(@base_time, 12, :second)
             )

    {:ok, %{actor_event: second_event}} =
      emit_entry(
        agent.uid,
        "mock",
        group_entry(%{
          signal_channel_id: channel_id,
          source_entry_id: "addressed-2",
          text: "second question",
          explicit: true,
          provider_time: DateTime.add(@base_time, 13, :second)
        }),
        now: DateTime.add(@base_time, 13, :second)
      )

    stored_ids = stored_context_entry_ids(second_event.id)
    assert "backdrop-1" in stored_ids
    assert "addressed-1" in stored_ids
    assert "backdrop-2" in stored_ids

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, first_event.session_id)

    {:ok, round} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => first_event.id}},
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "first question"}]
          }
        ]
      })

    assert {:ok, committed} =
             ResponseCommit.commit_complete(round, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "first answer"}]
               }
             ])

    assert {:ok, %{status: :completed}} = Run.finalize(%{first_run | anchor: committed.id})

    assert {:ok, second_run} =
             Admission.admit(
               %{agent_uid: agent.uid, session_id: second_event.session_id},
               second_event
             )

    assert second_run.actor_event_id == second_event.id
    assert ["backdrop-2"] = delivered_context_entry_ids(second_run)

    # The stored event keeps its full payload; only the delivered copy shrinks.
    assert stored_context_entry_ids(second_event.id) == stored_ids
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp context_payload(messages) do
    %{"data" => %{"channel_context" => %{"messages" => messages}}}
  end

  defp message(channel_id, source_entry_id) do
    %{
      "signal_channel_id" => channel_id,
      "source_entry_id" => source_entry_id,
      "text" => "text #{source_entry_id}"
    }
  end

  defp delivered_context_entry_ids(run) do
    run.delivered_event.payload
    |> get_in(["data", "channel_context", "messages"])
    |> List.wrap()
    |> Enum.map(& &1["source_entry_id"])
  end

  defp stored_context_entry_ids(actor_event_id) do
    Repo.get!(ActorEvent, actor_event_id).payload
    |> get_in(["data", "channel_context", "messages"])
    |> List.wrap()
    |> Enum.map(& &1["source_entry_id"])
  end
end
