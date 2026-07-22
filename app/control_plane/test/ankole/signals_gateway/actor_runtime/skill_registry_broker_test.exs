defmodule Ankole.SignalsGateway.ActorRuntime.SkillRegistryBrokerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill

  describe "skills.installed.replace RPC" do
    test "authorized worker route replaces installed skill observations" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      turn_ref = start_turn!(agent.uid, route)

      mixed_case_turn = %{
        turn_ref
        | actor: %{turn_ref.actor | agent_uid: " #{String.upcase(agent.uid)} "}
      }

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 rpc_request(
                   "installed-skills-1",
                   "skills.installed.replace",
                   %FabricProto.InstalledSkillReplaceRequest{
                     observations: [
                       %FabricProto.InstalledSkillObservation{
                         skill_name: "agent-notes",
                         description: "Agent installed notes.",
                         default_enabled: true,
                         tags: ["notes"],
                         category: "custom",
                         disable_model_invocation: false,
                         ankole_runtime: "background_job"
                       }
                     ]
                   },
                   turn: mixed_case_turn
                 ),
                 route
               )

      payload = rpc_response_payload!(envelope, FabricProto.InstalledSkillReplaceResponse)
      assert envelope_body!(envelope, :rpc_response).request_id == "installed-skills-1"
      assert %FabricProto.InstalledSkillReplaceResponse{} = payload

      assert %AgentSkill{source_kind: "installed", enabled_override: nil, default_enabled: true} =
               Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "agent-notes")

      assert {:ok, enabled_skills} = Library.enabled_skills_for_agent(agent.uid)

      assert Enum.any?(enabled_skills, fn skill ->
               skill["skill_name"] == "agent-notes" and skill["effective_enabled"]
             end)
    end

    test "rejects an unassigned worker route" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()
      wrong_route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)
      assert {:ok, _wrong_worker} = admit_worker(wrong_route)

      turn_ref = start_turn!(agent.uid, route)

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 rpc_request(
                   "installed-skills-rejected",
                   "skills.installed.replace",
                   %FabricProto.InstalledSkillReplaceRequest{observations: []},
                   turn: turn_ref
                 ),
                 wrong_route
               )

      error = rpc_error_payload!(envelope)
      assert error["request_id"] == "installed-skills-rejected"
      assert error["code"] == "worker_not_assigned_to_turn"
    end

    test "rejects stale write revisions" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      turn_ref = start_turn!(agent.uid, route)
      pre_context_turn_ref = %{turn_ref | revision: turn_ref.revision + 1}

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 rpc_request(
                   "installed-skills-stale",
                   "skills.installed.replace",
                   %FabricProto.InstalledSkillReplaceRequest{observations: []},
                   turn: pre_context_turn_ref
                 ),
                 route
               )

      error = rpc_error_payload!(envelope)
      assert error["request_id"] == "installed-skills-stale"
      assert error["code"] == "stale_revision"
    end

    test "returns a typed error for invalid observations" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      turn_ref = start_turn!(agent.uid, route)

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 rpc_request(
                   "installed-skills-invalid",
                   "skills.installed.replace",
                   %FabricProto.InstalledSkillReplaceRequest{
                     observations: [
                       %FabricProto.InstalledSkillObservation{
                         skill_name: "bad-skill",
                         description: "Invalid Skill.",
                         tags: [""]
                       }
                     ]
                   },
                   turn: turn_ref
                 ),
                 route
               )

      error = rpc_error_payload!(envelope)
      assert error["request_id"] == "installed-skills-invalid"
      assert error["code"] == "invalid_skill_tags"
    end
  end

  defp start_turn!(agent_uid, route) do
    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(%{text: "PING", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    assert turn_start_payload!(envelope).turn.actor_event_id == input.id

    # Keep the route registered until the RPC under test performs auth.
    assert is_binary(route)
    turn_start_payload!(envelope).turn
  end
end
