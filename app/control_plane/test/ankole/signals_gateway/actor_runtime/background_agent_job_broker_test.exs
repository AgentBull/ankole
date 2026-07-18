defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBrokerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIAgent.CodexAccounts
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor

  test "parent turn creates a durable job with server-frozen identity and reply route" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-1",
                 "background_agent_job.create",
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-background-agent-job-1",
                   title: "Prepare launch brief",
                   task: "Write and verify the launch brief.",
                   background: "The brief is for operators.",
                   notes: "Keep the result concise."
                 },
                 turn: turn_ref
               ),
               route
             )

    payload = job_payload(envelope)
    job = BackgroundAgentJobs.get_job_for_agent(payload.job_id, agent.uid)

    assert envelope_body!(envelope, :rpc_response).request_id == "background-agent-job-create-1"
    assert job.agent_uid == agent.uid
    assert job.owner_session_id == turn_ref.actor.session_id
    assert job.source_actor_event_id == turn_ref.actor_event_id
    assert job.task == "Write and verify the launch brief."
    assert job.background == "The brief is for operators."
    assert job.notes == "Keep the result concise."
    assert job.reply_route["binding_name"] == "bot"
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
               rpc_request(
                 "agent-plugin-list",
                 "agent_plugin.list",
                 %FabricProto.AgentPluginListRequest{},
                 turn: turn_ref
               ),
               route
             )

    assert %FabricProto.AgentPluginListResponse{agent_plugins: agent_plugins} =
             rpc_response_payload!(envelope, FabricProto.AgentPluginListResponse)

    assert Enum.map(agent_plugins, & &1.id) == ["deep-research", "office"]

    plugin = Enum.find(agent_plugins, &(&1.id == "deep-research"))
    assert plugin.id == "deep-research"
    assert plugin.version == "1.0.0"
    assert plugin.content_hash =~ ~r/^[a-f0-9]{64}$/

    assert plugin.skills == [
             %FabricProto.AgentPluginCatalogSkill{
               catalog_name: "deep-research",
               codex_name: "deep-research:deep-research"
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
      rpc_request(
        "background-agent-job-create-auth",
        "background_agent_job.create",
        %FabricProto.BackgroundAgentJobCreateRequest{
          source_tool_call_id: "tool-auth",
          title: "Authorized work",
          task: "Do the authorized work."
        },
        turn: turn_ref
      )

    assert {:ok, rejected} = RPCLane.handle_request(create_request, wrong_route)
    assert rpc_error(rejected)["code"] == "worker_not_assigned_to_turn"

    assert {:ok, created} = RPCLane.handle_request(create_request, route)
    job_id = job_payload(created).job_id

    assert {:ok, upsert_rejected} =
             RPCLane.handle_request(
               rpc_request(
                 "mutation-turn-upsert",
                 "background_agent_job.turn.upsert",
                 turn_upsert_request(job_id),
                 turn: turn_ref
               ),
               route
             )

    assert rpc_error(upsert_rejected)["code"] == "background_agent_job_turn_mismatch"

    assert {:ok, status_rejected} =
             RPCLane.handle_request(
               rpc_request(
                 "mutation-status-update",
                 "background_agent_job.status.update",
                 %FabricProto.BackgroundAgentJobStatusUpdateRequest{
                   job_id: job_id,
                   status: "running"
                 },
                 turn: turn_ref
               ),
               route
             )

    assert rpc_error(status_rejected)["code"] == "background_agent_job_turn_mismatch"
  end

  test "job turn memory reads resolve their scope from the server-owned job session" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    parent_turn = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-memory",
                 "background_agent_job.create",
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-memory",
                   title: "Research prior decisions",
                   task: "Search memory for prior decisions."
                 },
                 turn: parent_turn
               ),
               route
             )

    job_id = job_payload(created).job_id
    job = BackgroundAgentJobs.get_job_for_agent(job_id, agent.uid)
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job_id)}

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(actor_key,
               now: DateTime.add(job.queued_at, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, dispatch_envelope}, 200
    job_turn = turn_start_payload!(dispatch_envelope).turn

    assert {:ok, searched} =
             RPCLane.handle_request(
               rpc_request(
                 "memory-job-scope",
                 "memory_search",
                 %FabricProto.MemorySearchRequest{query: "prior decisions"},
                 turn: job_turn
               ),
               route
             )

    search_payload = rpc_passthrough_payload!(searched)
    assert search_payload["status"] in ["ok", "degraded"]

    if search_payload["status"] == "degraded" do
      assert search_payload["result_completeness"] == "incomplete"
      assert search_payload["degraded_reasons"] != []
    end
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
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-codex-account",
                   title: "Use the subscription account",
                   task: "Complete the delegated coding task."
                 },
                 turn: parent_turn
               ),
               route
             )

    job_id = job_payload(created).job_id
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
               rpc_request(
                 "codex-account-resolve",
                 "codex.account.resolve",
                 %FabricProto.CodexAccountResolveRequest{job_id: job_id},
                 turn: job_turn
               ),
               route
             )

    resolved_payload = rpc_response_payload!(resolved, FabricProto.CodexAccountResolveResponse)
    assert resolved_payload.account_id == account_id
    assert resolved_payload.auth_json == initial_auth
    assert resolved_payload.auth_hash == NativeKernel.generic_hash(initial_auth)

    refreshed_auth = auth_json(account_id, "refreshed-token")

    assert {:ok, updated} =
             RPCLane.handle_request(
               rpc_request(
                 "codex-account-update",
                 "codex.account.auth.update",
                 %FabricProto.CodexAccountAuthUpdateRequest{
                   job_id: job_id,
                   auth_json: refreshed_auth
                 },
                 turn: job_turn
               ),
               route
             )

    updated_payload = rpc_response_payload!(updated, FabricProto.CodexAccountAuthUpdateResponse)
    assert updated_payload.account_id == account_id

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
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-research",
                   agent_plugin_ids: ["deep-research"],
                   title: "Forecast the outcome",
                   task: "Research and produce a forecast dossier."
                 },
                 turn: parent_turn
               ),
               route
             )

    job_id = job_payload(created).job_id
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
               rpc_request(
                 "job-running",
                 "background_agent_job.status.update",
                 %FabricProto.BackgroundAgentJobStatusUpdateRequest{
                   job_id: job_id,
                   status: "running",
                   runtime_thread_id: "thread-1"
                 },
                 turn: job_turn
               ),
               route
             )

    assert {:ok, turn_response} =
             RPCLane.handle_request(
               rpc_request(
                 "turn-upsert",
                 "background_agent_job.turn.upsert",
                 turn_upsert_request(job_id),
                 turn: job_turn
               ),
               route
             )

    turn_payload =
      rpc_response_payload!(turn_response, FabricProto.BackgroundAgentJobTurnUpsertResponse).turn

    assert turn_payload.status == "in_progress"
    assert turn_payload.runtime_turn_id == "turn-1"

    trajectory = Torque.decode!(turn_payload.trajectory_json)
    assert trajectory == %{"format" => "ankole_chatml", "version" => 1, "messages" => []}

    refute inspect(trajectory) =~ "json_rpc"

    assert {:ok, in_progress_response} =
             RPCLane.handle_request(
               rpc_request(
                 "job-in-progress",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{job_id: job_id, trajectory_limit: 1},
                 turn: parent_turn
               ),
               route
             )

    in_progress_execution = Torque.decode!(job_payload(in_progress_response).execution_json)

    assert in_progress_execution["trajectory_page"]["messages"] == [
             %{"role" => "assistant", "content" => "Researching."}
           ]

    completed_at = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    completed_request = %{
      turn_upsert_request(job_id)
      | revision: 1,
        status: "completed",
        completed_at: completed_at,
        trajectory_groups_json:
          Torque.encode!([
            %{
              "position" => 1,
              "item_key" => "assistant:research-complete",
              "messages" => [%{"role" => "assistant", "content" => "Research complete."}]
            }
          ])
    }

    assert {:ok, completed_response} =
             RPCLane.handle_request(
               rpc_request(
                 "turn-completed",
                 "background_agent_job.turn.upsert",
                 completed_request,
                 turn: job_turn
               ),
               route
             )

    completed_turn =
      rpc_response_payload!(completed_response, FabricProto.BackgroundAgentJobTurnUpsertResponse).turn

    assert completed_turn.status == "completed"
    assert completed_turn.revision == 1

    assert {:ok, stale_response} =
             RPCLane.handle_request(
               rpc_request(
                 "turn-stale-retry",
                 "background_agent_job.turn.upsert",
                 %{completed_request | revision: 0, status: "in_progress", completed_at: ""},
                 turn: job_turn
               ),
               route
             )

    stale_turn =
      rpc_response_payload!(stale_response, FabricProto.BackgroundAgentJobTurnUpsertResponse).turn

    assert stale_turn.status == "completed"
    assert [_single_turn] = BackgroundAgentJobs.list_turns(job_id)

    assert {:ok, status_response} =
             RPCLane.handle_request(
               rpc_request(
                 "job-status",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{job_id: job_id, trajectory_limit: 1},
                 turn: parent_turn
               ),
               route
             )

    execution = Torque.decode!(job_payload(status_response).execution_json)
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
               rpc_request(
                 "job-invalid-cursor",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{
                   job_id: job_id,
                   trajectory_cursor: "not-a-cursor"
                 },
                 turn: parent_turn
               ),
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

  defp turn_upsert_request(job_id) do
    now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    %FabricProto.BackgroundAgentJobTurnUpsertRequest{
      job_id: job_id,
      attempt: 1,
      runtime_thread_id: "thread-1",
      runtime_turn_id: "turn-1",
      kind: "agent",
      status: "in_progress",
      revision: 0,
      trajectory_json:
        Torque.encode!(%{
          "format" => "ankole_chatml",
          "version" => 1,
          "messages" => []
        }),
      trajectory_groups_json:
        Torque.encode!([
          %{
            "position" => 0,
            "item_key" => "assistant:researching",
            "messages" => [%{"role" => "assistant", "content" => "Researching."}]
          }
        ]),
      progress_json:
        Torque.encode!(%{
          "completed_items" => 0,
          "tool_calls" => 0,
          "tools_used" => [],
          "files_changed" => []
        }),
      error_json: Torque.encode!(%{}),
      started_at: now
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

  defp job_payload(envelope) do
    assert envelope_body_type(envelope) == :rpc_response, inspect(envelope)
    rpc_response_payload!(envelope, FabricProto.BackgroundAgentJobResponse)
  end

  defp rpc_error(envelope) do
    assert envelope_body_type(envelope) == :rpc_error
    rpc_error_payload!(envelope)
  end
end
