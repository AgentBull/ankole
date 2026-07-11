defmodule Ankole.SignalsGateway.ActorRuntime.SubagentDelegationBrokerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.SubagentDelegations
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor

  test "parent turn creates a durable delegation with server-frozen identity and reply route" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "subagent-create-envelope",
                 "method" => "subagent.delegation.create",
                 "payload_json" => %{
                   "request_id" => "subagent-create-1",
                   "turn" => turn_ref,
                   "agent_uid" => "spoofed-agent",
                   "session_id" => "spoofed-session",
                   "actor_event_id" => Ecto.UUID.generate(),
                   "tool_call_id" => "tool-subagent-1",
                   "title" => "Prepare launch brief",
                   "prompt" => "Write and verify the launch brief.",
                   "reply_route" => %{"binding_name" => "spoofed"}
                 }
               },
               route
             )

    payload = rpc_payload(envelope)
    delegation = SubagentDelegations.get_delegation_for_agent(payload["delegation_id"], agent.uid)

    assert payload["request_id"] == "subagent-create-1"
    assert delegation.agent_uid == agent.uid
    assert delegation.session_id == get_in(turn_ref, ["actor", "session_id"])
    assert delegation.actor_event_id == turn_ref["actor_event_id"]
    assert delegation.reply_route["binding_name"] == "bot"
    refute delegation.reply_route["binding_name"] == "spoofed"
    assert delegation.metadata["worker_route"] == route
  end

  test "RPC authorization rejects an unassigned route and delegation-turn mutations from a parent turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    wrong_route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)
    assert {:ok, _worker} = admit_worker(wrong_route)

    create_request = %{
      "request_id" => "subagent-create-auth",
      "method" => "subagent.delegation.create",
      "payload_json" => %{
        "turn" => turn_ref,
        "tool_call_id" => "tool-auth",
        "title" => "Authorized work",
        "prompt" => "Do the authorized work."
      }
    }

    assert {:ok, rejected} = RPCLane.handle_request(create_request, wrong_route)
    assert rpc_error(rejected)["code"] == "worker_not_assigned_to_turn"

    assert {:ok, created} = RPCLane.handle_request(create_request, route)
    delegation_id = rpc_payload(created)["delegation_id"]

    for {method, extra} <- [
          {"subagent.delegation.event.append", %{"events" => [audit_event(0)]}},
          {"subagent.delegation.status.update", %{"status" => "running"}}
        ] do
      assert {:ok, mutation_rejected} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "mutation-#{method}",
                   "method" => method,
                   "payload_json" =>
                     Map.merge(extra, %{"turn" => turn_ref, "delegation_id" => delegation_id})
                 },
                 route
               )

      assert rpc_error(mutation_rejected)["code"] == "subagent_delegation_turn_mismatch"
    end
  end

  test "delegation memory reads use only the server-validated parent session and channel scope" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    parent_turn = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               %{
                 "request_id" => "subagent-create-memory",
                 "method" => "subagent.delegation.create",
                 "payload_json" => %{
                   "turn" => parent_turn,
                   "tool_call_id" => "tool-memory",
                   "title" => "Research prior decisions",
                   "prompt" => "Search memory for prior decisions."
                 }
               },
               route
             )

    delegation_id = rpc_payload(created)["delegation_id"]
    delegation = SubagentDelegations.get_delegation_for_agent(delegation_id, agent.uid)
    actor_key = %{agent_uid: agent.uid, session_id: "subagent:#{delegation_id}"}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(delegation.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, dispatch_envelope}, 200
    turn_start = dispatch_envelope["body"]["turn_start"]
    delegation_turn = turn_start["turn"]

    base_payload = %{
      "turn" => delegation_turn,
      "actor_event" => turn_start["actor_event"],
      "delegation_id" => delegation_id,
      "query" => "prior decisions"
    }

    assert {:ok, rejected} =
             RPCLane.handle_request(
               %{
                 "request_id" => "memory-wrong-scope",
                 "method" => "memory_search",
                 "payload_json" =>
                   Map.put(base_payload, "delegation_scope", %{
                     "session_id" => delegation.session_id,
                     "signal_channel_id" => "another-channel"
                   })
               },
               route
             )

    assert rpc_error(rejected)["code"] == "subagent_memory_scope_mismatch"

    assert {:ok, accepted} =
             RPCLane.handle_request(
               %{
                 "request_id" => "memory-correct-scope",
                 "method" => "memory_search",
                 "payload_json" =>
                   Map.put(base_payload, "delegation_scope", %{
                     "session_id" => delegation.session_id,
                     "signal_channel_id" => delegation.reply_route["signal_channel_id"]
                   })
               },
               route
             )

    assert rpc_payload(accepted)["status"] == "ok"
  end

  test "delegation turn resolves its frozen Codex account and writes back refreshed auth" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    account_id = "account-rpc"
    initial_auth = auth_json(account_id, "initial-token")

    assert {:ok, account} =
             CodexAccounts.create_account(%{
               "name" => "RPC account",
               "auth_json" => initial_auth
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               "codex_account_id" => account.account_id
             })

    route = unique_route()
    parent_turn = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               %{
                 "request_id" => "subagent-create-codex-account",
                 "method" => "subagent.delegation.create",
                 "payload_json" => %{
                   "turn" => parent_turn,
                   "tool_call_id" => "tool-codex-account",
                   "title" => "Use the subscription account",
                   "prompt" => "Complete the delegated coding task."
                 }
               },
               route
             )

    delegation_id = rpc_payload(created)["delegation_id"]
    delegation = SubagentDelegations.get_delegation_for_agent(delegation_id, agent.uid)
    assert delegation.codex_account_id == account_id

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: agent.uid, session_id: "subagent:#{delegation_id}"},
               now: DateTime.add(delegation.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, dispatch_envelope}, 200
    delegation_turn = get_in(dispatch_envelope, ["body", "turn_start", "turn"])

    assert {:ok, resolved} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-account-resolve",
                 "method" => "codex.account.resolve",
                 "payload_json" => %{
                   "turn" => delegation_turn,
                   "delegation_id" => delegation_id
                 }
               },
               route
             )

    resolved_payload = rpc_payload(resolved)
    assert resolved_payload["account_id"] == account_id
    assert resolved_payload["auth_json"] == initial_auth
    assert resolved_payload["auth_hash"] == NativeKernel.generic_hash(initial_auth)

    refreshed_auth = auth_json(account_id, "refreshed-token")

    assert {:ok, updated} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-account-update",
                 "method" => "codex.account.auth.update",
                 "payload_json" => %{
                   "turn" => delegation_turn,
                   "delegation_id" => delegation_id,
                   "auth_json" => refreshed_auth
                 }
               },
               route
             )

    updated_payload = rpc_payload(updated)
    refute Map.has_key?(updated_payload, "auth_hash")

    assert {:ok, %{auth_json: ^refreshed_auth, auth_hash: refreshed_hash}} =
             CodexAccounts.resolve_auth(account_id)

    assert refreshed_hash == NativeKernel.generic_hash(refreshed_auth)
  end

  defp start_parent_turn!(agent_uid, route) do
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(%{text: "Delegate this work", explicit: true}),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 200
    assert envelope["body"]["turn_start"]["turn"]["actor_event_id"] == input.id
    envelope["body"]["turn_start"]["turn"]
  end

  defp audit_event(seq) do
    %{
      "seq" => seq,
      "direction" => "process",
      "event_type" => "test",
      "payload" => %{"ok" => true}
    }
  end

  defp auth_json(account_id, access_token) do
    Ankole.JSON.encode!(%{
      "tokens" => %{
        "access_token" => access_token,
        "account_id" => account_id,
        "id_token" => "id-token",
        "refresh_token" => "refresh-token"
      }
    })
  end

  defp rpc_payload(envelope) do
    assert get_in(envelope, ["body", "type"]) == "rpc_response"
    get_in(envelope, ["body", "rpc_response", "payload_json"])
  end

  defp rpc_error(envelope) do
    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    get_in(envelope, ["body", "rpc_error"])
  end
end
