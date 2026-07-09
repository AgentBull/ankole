defmodule Ankole.ActorRuntime.SubagentDispatchTest do
  use Ankole.ActorRuntimeCase

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.ActorRuntime.ReadyEventProcessor
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.ActorRuntime.WorkerSubagentConfig
  alias Ankole.AppConfigure
  alias Ankole.SubagentDelegations

  test "dispatch starts a fenced non-conversation turn and increments attempts once" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "dispatch")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_start = envelope["body"]["turn_start"]
    assert turn_start["turn"]["actor"]["session_id"] == actor_key.session_id
    assert turn_start["request_context"]["turn_mode"] == "subagent_delegation"
    assert turn_start["request_context"]["delegation_id"] == delegation.id
    assert turn_start["request_context"]["parent_session_id"] == delegation.session_id
    assert turn_start["request_context"]["attempts"] == 1

    refute Repo.get_by(Conversation,
             agent_uid: agent.uid,
             conversation_key: actor_key.session_id
           )

    persisted = SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid)
    assert persisted.status == "running"
    assert persisted.attempts == 1
  end

  test "worker placement applies the configurable delegation-only capacity" do
    %{principal: agent} = agent_fixture()
    definition = WorkerSubagentConfig.definition()
    :ok = AppConfigure.delete_global(definition)
    on_exit(fn -> AppConfigure.delete_global(definition) end)
    assert {:ok, 1} = AppConfigure.put_global(definition, 1)

    first_route = unique_route()
    second_route = unique_route()
    assert {:ok, first_worker} = admit_worker(first_route)
    assert {:ok, second_worker} = admit_worker(second_route)

    assert {:ok, first_assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: "subagent:#{Ecto.UUID.generate()}"
             })

    assert {:ok, second_assignment} =
             WorkerPool.assign_worker(%{
               agent_uid: agent.uid,
               session_id: "subagent:#{Ecto.UUID.generate()}"
             })

    assert first_assignment.worker_id == first_worker.worker_id
    assert second_assignment.worker_id == second_worker.worker_id
  end

  test "running cancellation commits stopped before the fenced worker is interrupted" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    delegation = create_delegation!(agent.uid, "running-stop")
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation.id}"}
    now = DateTime.add(delegation.queued_at, 1, :second)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: now,
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, turn_envelope}, 200
    turn_ref = turn_envelope["body"]["turn_start"]["turn"]

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(%{"turn_accepted" => %{"turn" => turn_ref}})

    assert {:ok, %{delegation: stopped, command_event: stop_event}} =
             SubagentDelegations.request_stop(delegation.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:test",
               "reason" => "Stop the background task"
             })

    assert stopped.status == "stopped"
    assert stopped.metadata["cancel_requested_by"] == "operator:test"
    assert stop_event.type == "command.stop"

    assert {:ok, %{status: :command_consumed, command: "command.stop"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(now, 1, :second)
             )

    assert_receive {:actor_lane, stop_control}, 200
    assert stop_control["body"]["turn_control"]["command"] == "stop"

    assert stop_control["body"]["turn_control"]["turn"]["actor_event_id"] ==
             turn_ref["actor_event_id"]

    assert SubagentDelegations.get_delegation_for_agent(delegation.id, agent.uid).status ==
             "stopped"

    assert %DateTime{} =
             Repo.get!(Ankole.Actors.ActorEvent, turn_ref["actor_event_id"]).completed_at

    assert %DateTime{} = Repo.get!(Ankole.Actors.ActorEvent, stop_event.id).completed_at

    refute Repo.get_by(Ankole.SignalsGateway.OutboxEntry,
             source_actor_event_id: stop_event.id
           )
  end

  defp create_delegation!(agent_uid, suffix) do
    assert {:ok, %{delegation: delegation}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "session_id" => "parent-session-#{suffix}",
               "tool_call_id" => "tool-subagent-#{suffix}",
               "title" => "Delegation #{suffix}",
               "prompt" => "Complete delegation #{suffix}.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "chat-#{suffix}"
               }
             })

    delegation
  end
end
