defmodule Ankole.ActorRuntime.AmbientTest do
  use Ankole.ActorRuntimeCase

  describe "ambient input turns" do
    test "ambient silence consumes merged observation without visible output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "The deploy finished.", explicit: false}),
                 now: @base_time
               )

      assert {:ok, %{status: :idle}} =
               ActorRuntime.process_ready_inputs_once(now: DateTime.add(@base_time, 1, :second))

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: recognizer_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 15_001, :millisecond),
                 lease_seconds: @long_lease_seconds
               )

      assert %LlmTurn{kind: "generation", profile: "primary", status: "started"} =
               Repo.get!(LlmTurn, recognizer_turn.id)

      assert %Message{role: "im_ambient", kind: "normal", metadata: metadata} =
               Repo.one!(
                 from(message in Message,
                   where: message.metadata["actor_input_id"] == ^input.id
                 )
               )

      assert get_in(metadata, ["message_context", "room", "label"]) == "group chat \"Ops\""

      assert_receive {:actor_lane, envelope}
      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      refute Map.has_key?(turn_start, "turn_kind")
      assert turn_start["model_ref"]["profile"] == "primary"
      assert input_ids == [input.id]

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, %{status: :ambient_silent}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => nil
                 }
               })

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(ActorInputDelivery, :count) == 0
      assert Repo.aggregate(OutboxEntry, :count) == 0

      refute Repo.exists?(
               from(message in Message,
                 where: message.role == "assistant"
               )
             )
    end

    test "ambient intervention proposal writes runtime watermark and visible output" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   text: "Can someone ask agent for the release summary?",
                   explicit: false
                 }),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: ambient_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 15_001, :millisecond),
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, ambient_envelope}
      ambient_start = ambient_envelope["body"]["turn_start"]
      ambient_ref = ambient_start["turn"]
      ambient_input_ids = Enum.map(ambient_start["inputs"], & &1["actor_input_id"])

      assert Repo.get!(LlmTurn, ambient_turn.id).kind == "generation"
      refute Map.has_key?(ambient_start, "turn_kind")

      assert [%{"type" => "im.message.may_intervene", "payload_json" => payload}] =
               ambient_start["inputs"]

      assert [%{"speaker" => "Alice", "text" => text}] =
               get_in(payload, ["data", "observed_messages"])

      assert text =~ "release summary"

      assert {:ok, [_delivery]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => ambient_ref,
                   "accepted_actor_input_ids" => ambient_input_ids
                 }
               })

      assert {:ok, %{status: :committed, assistant_message: assistant_message}} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => ambient_ref,
                   "messages" => [
                     %{
                       "role" => "im_ambient",
                       "content_json" => [
                         %{
                           "type" => "text",
                           "text" =>
                             "<chat_segment format=\"yaml\">\nmessages:\n  - speaker: Alice\n    text: release summary\n</chat_segment>"
                         }
                       ],
                       "metadata_json" => %{
                         "kind" => "introspection",
                         "event_source" => "agent_computer.ambient",
                         "event_id" => "ambient-intervention:#{ambient_turn.id}",
                         "control" => %{
                           "type" => "ambient_intervention",
                           "reason" => "The group is implicitly asking the agent to answer."
                         },
                         "message_context" => %{
                           "speaker" => %{
                             "injected" => true,
                             "display_name" => agent.uid,
                             "role" => "agent",
                             "trigger" => "introspection"
                           }
                         }
                       }
                     }
                   ],
                   "reply" => %{
                     "text" => "Here is the release summary.",
                     "content_json" => [
                       %{"type" => "text", "text" => "Here is the release summary."}
                     ]
                   }
                 }
               })

      assert %LlmTurn{kind: "generation", status: "succeeded"} =
               Repo.get!(LlmTurn, ambient_turn.id)

      assert %Message{
               role: "im_ambient",
               kind: "introspection",
               content: content,
               metadata: metadata
             } =
               Repo.one!(
                 from(message in Message,
                   where: message.kind == "introspection",
                   where: message.role == "im_ambient"
                 )
               )

      assert [%{"text" => text}] = content
      assert text =~ "<chat_segment"
      assert text =~ "release summary"
      assert get_in(metadata, ["control", "type"]) == "ambient_intervention"
      assert get_in(metadata, ["message_context", "speaker", "trigger"]) == "introspection"

      assert Repo.get!(Message, assistant_message.id).content == [
               %{"type" => "text", "text" => "Here is the release summary."}
             ]

      refute Repo.get(ActorInput, input.id)
      assert Repo.aggregate(OutboxEntry, :count) == 1
    end
  end
end
