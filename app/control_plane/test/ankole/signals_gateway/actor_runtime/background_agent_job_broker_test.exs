defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBrokerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor

  test "parent turn creates a durable job with server-frozen identity and reply route" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-envelope",
                 "background_agent_job.create",
                 %{
                   "request_id" => "background-agent-job-create-1",
                   "turn" => turn_ref,
                   "agent_uid" => "spoofed-agent",
                   "owner_session_id" => "spoofed-session",
                   "source_actor_event_id" => Ecto.UUID.generate(),
                   "source_tool_call_id" => "tool-background-agent-job-1",
                   "title" => "Prepare launch brief",
                   "task" => "Write and verify the launch brief.",
                   "background" => "The brief is for operators.",
                   "notes" => "Keep the result concise.",
                   "reply_route" => %{"binding_name" => "spoofed"}
                 }
               ),
               route
             )

    payload = rpc_payload(envelope)
    job = BackgroundAgentJobs.get_job_for_agent(payload["job_id"], agent.uid)

    assert payload["request_id"] == "background-agent-job-create-1"
    assert job.agent_uid == agent.uid
    assert job.owner_session_id == turn_wire_ref(turn_ref)["actor"]["session_id"]
    assert job.source_actor_event_id == turn_ref.actor_event_id
    assert job.task == "Write and verify the launch brief."
    assert job.background == "The brief is for operators."
    assert job.notes == "Keep the result concise."
    assert job.reply_route["binding_name"] == "bot"
    refute job.reply_route["binding_name"] == "spoofed"
    assert job.metadata["worker_route"] == route
    assert is_binary(job.metadata["brain_owner_conversation_id"])
  end

  test "readonly Agent Plugin catalog exposes package identity and canonical Skill names" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request("agent-plugin-list", "agent_plugin.list", %{"turn" => turn_ref}),
               route
             )

    assert %{"agent_plugins" => agent_plugins} = rpc_payload(envelope)
    assert Enum.map(agent_plugins, & &1["id"]) == ["deep-research", "office"]

    plugin = Enum.find(agent_plugins, &(&1["id"] == "deep-research"))
    assert plugin["id"] == "deep-research"
    assert plugin["version"] == "1.0.0"
    assert plugin["content_hash"] =~ ~r/^[a-f0-9]{64}$/

    assert Map.keys(plugin) |> Enum.sort() ==
             ~w(content_hash description id skills version)

    assert plugin["skills"] == [
             %{
               "catalog_name" => "deep-research",
               "codex_name" => "deep-research:deep-research"
             }
           ]
  end

  test "RPC authorization rejects an unassigned route and job-turn mutations from a parent turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    wrong_route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)
    assert {:ok, _worker} = admit_worker(wrong_route)

    create_request =
      rpc_request("background-agent-job-create-auth", "background_agent_job.create", %{
        "turn" => turn_ref,
        "source_tool_call_id" => "tool-auth",
        "title" => "Authorized work",
        "task" => "Do the authorized work."
      })

    assert {:ok, rejected} = RPCLane.handle_request(create_request, wrong_route)
    assert rpc_error(rejected)["code"] == "worker_not_assigned_to_turn"

    assert {:ok, created} = RPCLane.handle_request(create_request, route)
    job_id = rpc_payload(created)["job_id"]

    for {method, extra} <- [
          {"background_agent_job.turn.upsert", turn_attrs()},
          {"background_agent_job.status.update", %{"status" => "running"}}
        ] do
      assert {:ok, mutation_rejected} =
               RPCLane.handle_request(
                 rpc_request(
                   "mutation-#{method}",
                   method,
                   Map.merge(extra, %{"turn" => turn_ref, "job_id" => job_id})
                 ),
                 route
               )

      assert rpc_error(mutation_rejected)["code"] == "background_agent_job_turn_mismatch"
    end
  end

  test "job memory reads use only the server-validated parent session and channel scope" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    parent_turn = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               rpc_request("background-agent-job-create-memory", "background_agent_job.create", %{
                 "turn" => parent_turn,
                 "source_tool_call_id" => "tool-memory",
                 "title" => "Research prior decisions",
                 "task" => "Search memory for prior decisions."
               }),
               route
             )

    job_id = rpc_payload(created)["job_id"]
    job = BackgroundAgentJobs.get_job_for_agent(job_id, agent.uid)
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job_id)}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, dispatch_envelope}, 200
    turn_start = turn_start_payload!(dispatch_envelope)
    job_turn = turn_start.turn

    base_payload = %{
      "turn" => job_turn,
      "actor_event" => turn_start.actor_event,
      "job_id" => job_id,
      "query" => "prior decisions"
    }

    assert {:ok, ignored_spoof} =
             RPCLane.handle_request(
               rpc_request(
                 "memory-wrong-scope",
                 "memory_search",
                 Map.put(base_payload, "job_scope", %{
                   "owner_session_id" => job.owner_session_id,
                   "signal_channel_id" => "another-channel"
                 })
               ),
               route
             )

    ignored_spoof_payload = rpc_payload(ignored_spoof)
    assert ignored_spoof_payload["status"] in ["ok", "degraded"]

    if ignored_spoof_payload["status"] == "degraded" do
      assert ignored_spoof_payload["result_completeness"] == "incomplete"
      assert ignored_spoof_payload["degraded_reasons"] != []
    end

    assert {:ok, accepted} =
             RPCLane.handle_request(
               rpc_request(
                 "memory-correct-scope",
                 "memory_search",
                 Map.put(base_payload, "job_scope", %{
                   "owner_session_id" => job.owner_session_id,
                   "signal_channel_id" => job.reply_route["signal_channel_id"]
                 })
               ),
               route
             )

    accepted_payload = rpc_payload(accepted)

    assert Map.take(accepted_payload, [
             "status",
             "result_completeness",
             "results",
             "degraded_reasons"
           ]) ==
             Map.take(ignored_spoof_payload, [
               "status",
               "result_completeness",
               "results",
               "degraded_reasons"
             ])
  end

  test "job turn resolves its frozen Codex account and writes back refreshed auth" do
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
               rpc_request(
                 "background-agent-job-create-codex-account",
                 "background_agent_job.create",
                 %{
                   "turn" => parent_turn,
                   "source_tool_call_id" => "tool-codex-account",
                   "title" => "Use the subscription account",
                   "task" => "Complete the delegated coding task."
                 }
               ),
               route
             )

    job_id = rpc_payload(created)["job_id"]
    job = BackgroundAgentJobs.get_job_for_agent(job_id, agent.uid)
    assert job.codex_account_id == account_id

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job_id)},
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, dispatch_envelope}, 200
    job_turn = turn_start_payload!(dispatch_envelope).turn

    assert {:ok, resolved} =
             RPCLane.handle_request(
               rpc_request("codex-account-resolve", "codex.account.resolve", %{
                 "turn" => job_turn,
                 "job_id" => job_id
               }),
               route
             )

    resolved_payload = rpc_payload(resolved)
    assert resolved_payload["account_id"] == account_id
    assert resolved_payload["auth_json"] == initial_auth
    assert resolved_payload["auth_hash"] == NativeKernel.generic_hash(initial_auth)

    refreshed_auth = auth_json(account_id, "refreshed-token")

    assert {:ok, updated} =
             RPCLane.handle_request(
               rpc_request("codex-account-update", "codex.account.auth.update", %{
                 "turn" => job_turn,
                 "job_id" => job_id,
                 "auth_json" => refreshed_auth
               }),
               route
             )

    updated_payload = rpc_payload(updated)
    refute Map.has_key?(updated_payload, "auth_hash")

    assert {:ok, %{auth_json: ^refreshed_auth, auth_hash: refreshed_hash}} =
             CodexAccounts.resolve_auth(account_id)

    assert refreshed_hash == NativeKernel.generic_hash(refreshed_auth)
  end

  test "Deep Research turns use the shared Turn trajectory" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    parent_turn = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-research",
                 "background_agent_job.create",
                 %{
                   "turn" => parent_turn,
                   "source_tool_call_id" => "tool-research",
                   "agent_plugin_ids" => ["deep-research"],
                   "title" => "Forecast the outcome",
                   "task" => "Research and produce a forecast dossier."
                 }
               ),
               route
             )

    job_id = rpc_payload(created)["job_id"]
    job = BackgroundAgentJobs.get_job_for_agent(job_id, agent.uid)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job_id)},
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, dispatch_envelope}, 200
    job_turn = turn_start_payload!(dispatch_envelope).turn

    assert {:ok, _running_response} =
             RPCLane.handle_request(
               rpc_request("job-running", "background_agent_job.status.update", %{
                 "turn" => job_turn,
                 "job_id" => job_id,
                 "status" => "running",
                 "runtime_thread_id" => "thread-1"
               }),
               route
             )

    assert {:ok, turn_response} =
             RPCLane.handle_request(
               rpc_request(
                 "turn-upsert",
                 "background_agent_job.turn.upsert",
                 turn_attrs()
                 |> Map.put("turn", job_turn)
                 |> Map.put("job_id", job_id)
               ),
               route
             )

    turn_payload = rpc_payload(turn_response)["turn"]
    assert turn_payload["status"] == "in_progress"
    assert turn_payload["runtime_turn_id"] == "turn-1"
    assert turn_payload["trajectory"]["format"] == "ankole_chatml"

    assert turn_payload["trajectory"]["messages"] == [
             %{"role" => "assistant", "content" => "Researching."}
           ]

    refute inspect(turn_payload) =~ "json_rpc"

    completed_at = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    completed_attrs =
      turn_attrs()
      |> Map.put("turn", job_turn)
      |> Map.put("job_id", job_id)
      |> Map.put("revision", 1)
      |> Map.put("status", "completed")
      |> Map.put("completed_at", completed_at)
      |> put_in(
        ["trajectory", "messages"],
        [%{"role" => "assistant", "content" => "Research complete."}]
      )

    assert {:ok, completed_response} =
             RPCLane.handle_request(
               rpc_request("turn-completed", "background_agent_job.turn.upsert", completed_attrs),
               route
             )

    completed_turn = rpc_payload(completed_response)["turn"]
    assert completed_turn["status"] == "completed"
    assert completed_turn["revision"] == 1

    assert {:ok, stale_response} =
             RPCLane.handle_request(
               rpc_request(
                 "turn-stale-retry",
                 "background_agent_job.turn.upsert",
                 completed_attrs
                 |> Map.put("revision", 0)
                 |> Map.put("status", "in_progress")
                 |> Map.delete("completed_at")
               ),
               route
             )

    assert rpc_payload(stale_response)["turn"]["status"] == "completed"
    assert [_single_turn] = BackgroundAgentJobs.list_turns(job_id)

    assert {:ok, status_response} =
             RPCLane.handle_request(
               rpc_request("job-status", "background_agent_job.get", %{
                 "turn" => parent_turn,
                 "job_id" => job_id,
                 "trajectory_limit" => 1
               }),
               route
             )

    execution = rpc_payload(status_response)["execution"]
    assert execution["lead_turn_number"] == 1

    assert execution["turns"] == %{
             "lead" => 1,
             "child" => 0,
             "compaction" => 0,
             "active" => 0
           }

    assert execution["trajectory_page"]["messages"] == [
             %{"role" => "assistant", "content" => "Research complete."}
           ]

    assert {:ok, invalid_cursor_response} =
             RPCLane.handle_request(
               rpc_request("job-invalid-cursor", "background_agent_job.get", %{
                 "turn" => parent_turn,
                 "job_id" => job_id,
                 "trajectory_cursor" => "not-a-cursor"
               }),
               route
             )

    assert rpc_error(invalid_cursor_response)["code"] ==
             "invalid_background_agent_job_trajectory_cursor"
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
    assert turn_start_payload!(envelope).turn.actor_event_id == input.id
    turn_start_payload!(envelope).turn
  end

  defp turn_attrs do
    now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    %{
      "attempt" => 1,
      "runtime_thread_id" => "thread-1",
      "runtime_turn_id" => "turn-1",
      "kind" => "agent",
      "status" => "in_progress",
      "revision" => 0,
      "trajectory" => %{
        "format" => "ankole_chatml",
        "version" => 1,
        "messages" => [%{"role" => "assistant", "content" => "Researching."}]
      },
      "progress" => %{
        "completed_items" => 0,
        "tool_calls" => 0,
        "tools_used" => [],
        "files_changed" => []
      },
      "error" => %{},
      "started_at" => now
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
    assert envelope_body_type(envelope) == :rpc_response, inspect(envelope)
    rpc_response_payload!(envelope)
  end

  defp rpc_error(envelope) do
    assert envelope_body_type(envelope) == :rpc_error
    rpc_error_payload!(envelope)
  end
end
