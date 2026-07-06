defmodule Ankole.ActorRuntime.SkillRegistryBrokerTest do
  use Ankole.ActorRuntimeCase

  import Ecto.Query, only: [from: 2]

  alias Ankole.AIAgent.Library.Schemas.AgentSkill

  describe "skills.installed.replace RPC" do
    test "authorized worker route replaces installed skill observations" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      turn_ref =
        agent.uid
        |> start_turn!(route)
        |> put_in(["actor", "agent_uid"], " #{String.upcase(agent.uid)} ")

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "rpc-installed-skills-1",
                   "method" => "skills.installed.replace",
                   "payload_json" => %{
                     "request_id" => "installed-skills-1",
                     "turn" => turn_ref,
                     "observations" => [
                       %{
                         "skill_name" => "agent-notes",
                         "relative_path" => "agent-notes",
                         "description" => "Agent installed notes.",
                         "default_enabled" => true,
                         "metadata" => %{"category" => "custom"},
                         "xxh3_128" => "7b16fe7c3e492b87d9615265f0856cec",
                         "file_count" => 2
                       }
                     ]
                   }
                 },
                 route
               )

      payload = get_in(envelope, ["body", "rpc_response", "payload_json"])
      assert payload["request_id"] == "installed-skills-1"
      assert payload["agent_uid"] == agent.uid

      assert payload["skills"] ==
               Repo.aggregate(
                 from(skill in AgentSkill, where: skill.agent_uid == ^agent.uid),
                 :count
               )

      assert payload["files"] >= 4

      assert %AgentSkill{source_kind: "installed", enabled: true} =
               Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "agent-notes")
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
                 %{
                   "request_id" => "rpc-installed-skills-rejected",
                   "method" => "skills.installed.replace",
                   "payload_json" => %{
                     "request_id" => "installed-skills-rejected",
                     "turn" => turn_ref,
                     "observations" => []
                   }
                 },
                 wrong_route
               )

      error = get_in(envelope, ["body", "rpc_error"])
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
      pre_context_turn_ref = Map.update!(turn_ref, "revision", &(&1 + 1))

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "rpc-installed-skills-stale",
                   "method" => "skills.installed.replace",
                   "payload_json" => %{
                     "request_id" => "installed-skills-stale",
                     "turn" => pre_context_turn_ref,
                     "observations" => []
                   }
                 },
                 route
               )

      error = get_in(envelope, ["body", "rpc_error"])
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
                 %{
                   "request_id" => "rpc-installed-skills-invalid",
                   "method" => "skills.installed.replace",
                   "payload_json" => %{
                     "request_id" => "installed-skills-invalid",
                     "turn" => turn_ref,
                     "observations" => [
                       %{
                         "skill_name" => "bad-skill",
                         "description" => "",
                         "xxh3_128" => "not-a-fingerprint"
                       }
                     ]
                   }
                 },
                 route
               )

      error = get_in(envelope, ["body", "rpc_error"])
      assert error["request_id"] == "installed-skills-invalid"
      assert error["code"] in ["invalid_skill_fingerprint", "skill_description_missing"]
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
    assert envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id

    # Keep the route registered until the RPC under test performs auth.
    assert is_binary(route)
    envelope["body"]["turn_start"]["turn"]
  end
end
