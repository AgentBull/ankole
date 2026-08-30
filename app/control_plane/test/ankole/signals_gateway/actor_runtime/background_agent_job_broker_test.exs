defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBrokerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
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
                   task: "Write and verify the launch brief."
                 },
                 turn: turn_ref
               ),
               route
             )

    payload = job_payload(envelope)
    job = BackgroundAgentJobs.get_job_for_agent(domain_job_id!(payload.job_id), agent.uid)

    assert envelope_body!(envelope, :rpc_response).request_id == "background-agent-job-create-1"
    assert job.agent_uid == agent.uid
    assert job.owner_session_id == turn_ref.actor.session_id
    assert job.source_actor_event_id == turn_ref.actor_event_id
    assert job.task == "Write and verify the launch brief."
    assert job.reply_route["binding_name"] == "bot"
    assert job.metadata["worker_route"] == route
    assert is_binary(job.metadata["owner_conversation_id"])
    assert job.workspace_owner_job_id == job.id
    assert job.model_profile == "coding"
    assert payload.model_profile == "coding"
  end

  test "a cron parent freezes its delivery targets in the BackgroundAgentJob reply route" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)
    source = Repo.get!(ActorEvent, turn_ref.actor_event_id)

    delivery = %{
      "targets" => [
        %{
          "binding_name" => source.binding_name,
          "signal_channel_id" => source.signal_channel_id,
          "provider_thread_id" => source.provider_thread_id
        },
        %{
          "binding_name" => "archive-bot",
          "signal_channel_id" => "archive-channel"
        }
      ]
    }

    source
    |> ActorEvent.changeset(%{
      type: "cron.fire",
      payload: %{"data" => %{"wake_payload" => %{"delivery" => delivery}}}
    })
    |> Repo.update!()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-from-cron",
                 "background_agent_job.create",
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-background-agent-job-from-cron",
                   title: "Prepare scheduled brief",
                   task: "Write and verify the scheduled brief."
                 },
                 turn: turn_ref
               ),
               route
             )

    job =
      envelope
      |> job_payload()
      |> Map.fetch!(:job_id)
      |> domain_job_id!()
      |> BackgroundAgentJobs.get_job_for_agent(agent.uid)

    assert job.reply_route["delivery"] == delivery
  end

  test "parent turn respawns a same-Agent terminal job from another session and channel" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)
    assert {:ok, heavy} = ModelProfiles.get_model_profile(agent.uid, "heavy")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", %{
               description: "Long-context coding",
               provider_id: heavy["provider_id"],
               model: "moonshotai/kimi-k2.7-code",
               provider_options: %{"reasoningEffort" => "high"}
             })

    assert {:ok, created} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-for-respawn",
                 "background_agent_job.create",
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-create-for-respawn",
                   title: "Prepare launch brief",
                   task: "Write and verify the launch brief.",
                   model_profile: "kimi"
                 },
                 turn: turn_ref
               ),
               route
             )

    source_job_id = job_payload(created).job_id
    source_job = BackgroundAgentJobs.get_job_for_agent(domain_job_id!(source_job_id), agent.uid)
    assert source_job.model_profile == "kimi"

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", %{
               description: "Long-context coding",
               provider_id: heavy["provider_id"],
               model: "moonshotai/kimi-k3-code",
               provider_options: %{"reasoningEffort" => "max"}
             })

    source_job =
      source_job
      |> Ecto.Changeset.change(%{
        status: "failed",
        runtime_thread_id: "thread-for-respawn",
        owner_session_id: "historical-session",
        reply_route: %{
          "binding_name" => "bot",
          "signal_channel_id" => "historical-channel"
        },
        completed_at: DateTime.utc_now(:microsecond)
      })
      |> Repo.update!()

    request =
      rpc_request(
        "background-agent-job-respawn",
        "background_agent_job.respawn",
        %FabricProto.BackgroundAgentJobRespawnRequest{
          source_job_id: Integer.to_string(source_job.id),
          message: "  Improve the PDF layout.  ",
          source_tool_call_id: "tool-respawn"
        },
        turn: turn_ref
      )

    assert {:ok, respawned} = RPCLane.handle_request(request, route)

    assert %FabricProto.BackgroundAgentJobRespawnResponse{
             job_id: successor_job_id,
             status: "queued"
           } = rpc_response_payload!(respawned, FabricProto.BackgroundAgentJobRespawnResponse)

    successor_job =
      BackgroundAgentJobs.get_job_for_agent(domain_job_id!(successor_job_id), agent.uid)

    assert successor_job.id != source_job.id
    assert successor_job.title == source_job.title
    assert successor_job.task == "  Improve the PDF layout.  "
    assert successor_job.runtime_thread_id == source_job.runtime_thread_id
    assert successor_job.continued_from_job_id == source_job.id
    assert successor_job.workspace_owner_job_id == source_job.workspace_owner_job_id
    assert successor_job.owner_session_id == turn_ref.actor.session_id
    assert successor_job.workspace_template_id == nil
    assert successor_job.model_profile == "kimi"
    assert successor_job.runtime_projection == nil
    assert successor_job.metadata["managed_background_agent_job_root"] == false

    assert BackgroundAgentJobs.get_job_for_agent(source_job.id, agent.uid).status == "failed"

    assert {:ok, retried} = RPCLane.handle_request(request, route)

    assert rpc_response_payload!(retried, FabricProto.BackgroundAgentJobRespawnResponse).job_id ==
             Integer.to_string(successor_job.id)

    different_request =
      rpc_request(
        "background-agent-job-respawn-again",
        "background_agent_job.respawn",
        %FabricProto.BackgroundAgentJobRespawnRequest{
          source_job_id: Integer.to_string(source_job.id),
          message: "Try another continuation.",
          source_tool_call_id: "tool-respawn-again"
        },
        turn: turn_ref
      )

    assert {:ok, rejected} = RPCLane.handle_request(different_request, route)
    assert rpc_error(rejected)["code"] == "background_agent_job_already_respawned"
  end

  test "respawn rejects a live source and a terminal source without a Codex thread" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-invalid-respawn",
                 "background_agent_job.create",
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-create-invalid-respawn",
                   title: "Prepare launch brief",
                   task: "Write and verify the launch brief."
                 },
                 turn: turn_ref
               ),
               route
             )

    source_job_id = job_payload(created).job_id

    live_request =
      rpc_request(
        "background-agent-job-respawn-live",
        "background_agent_job.respawn",
        %FabricProto.BackgroundAgentJobRespawnRequest{
          source_job_id: source_job_id,
          message: "Continue.",
          source_tool_call_id: "tool-respawn-live"
        },
        turn: turn_ref
      )

    assert {:ok, live_rejected} = RPCLane.handle_request(live_request, route)
    assert rpc_error(live_rejected)["code"] == "background_agent_job_not_terminal"

    source_job = BackgroundAgentJobs.get_job_for_agent(domain_job_id!(source_job_id), agent.uid)

    source_job
    |> Ecto.Changeset.change(%{status: "stopped", completed_at: DateTime.utc_now(:microsecond)})
    |> Repo.update!()

    terminal_request =
      rpc_request(
        "background-agent-job-respawn-without-thread",
        "background_agent_job.respawn",
        %FabricProto.BackgroundAgentJobRespawnRequest{
          source_job_id: source_job_id,
          message: "Continue.",
          source_tool_call_id: "tool-respawn-without-thread"
        },
        turn: turn_ref
      )

    assert {:ok, terminal_rejected} = RPCLane.handle_request(terminal_request, route)
    assert rpc_error(terminal_rejected)["code"] == "background_agent_job_runtime_thread_missing"
  end

  test "list RPC returns the public Job projection" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-for-list",
                 "background_agent_job.create",
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-background-agent-job-list",
                   title: "Prepare launch brief",
                   task: "Write the first launch brief."
                 },
                 turn: turn_ref
               ),
               route
             )

    job_id = job_payload(created).job_id

    assert {:ok, listed} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-list",
                 "background_agent_job.list",
                 %FabricProto.BackgroundAgentJobListRequest{},
                 turn: turn_ref
               ),
               route
             )

    assert %FabricProto.BackgroundAgentJobListResponse{
             jobs: [%FabricProto.BackgroundAgentJobSummary{} = summary],
             next_cursor: ""
           } = rpc_response_payload!(listed, FabricProto.BackgroundAgentJobListResponse)

    assert summary.job_id == job_id
    assert summary.title == "Prepare launch brief"
    assert summary.status == "queued"
  end

  test "result offset returns one bounded UTF-8 window without the full Job document" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    turn_ref = start_parent_turn!(agent.uid, route)

    assert {:ok, created} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-create-for-result-read",
                 "background_agent_job.create",
                 %FabricProto.BackgroundAgentJobCreateRequest{
                   source_tool_call_id: "tool-background-agent-job-result-read",
                   title: "Prepare exact report",
                   task: "Return the exact report."
                 },
                 turn: turn_ref
               ),
               route
             )

    job_id = job_payload(created).job_id
    output_text = String.duplicate("季😀\"\\\n", 4_000)

    job_id
    |> domain_job_id!()
    |> BackgroundAgentJobs.get_job_for_agent(agent.uid)
    |> Ecto.Changeset.change(%{
      status: "succeeded",
      result: %{"output_text" => output_text},
      completed_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.update!()

    assert {:ok, first_response} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-result-first",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{
                   job_id: job_id,
                   result_offset: "0"
                 },
                 turn: turn_ref
               ),
               route
             )

    first = job_payload(first_response)
    assert first.status == "succeeded"
    assert first.result_ref.job_id == job_id
    assert first.execution_json == ""
    assert first.result_output_total_bytes == Integer.to_string(byte_size(output_text))
    assert byte_size(first.result_output_text) <= 16_384
    assert String.valid?(first.result_output_text)

    next_offset = byte_size(first.result_output_text)

    assert {:ok, second_response} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-result-second",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{
                   job_id: job_id,
                   result_offset: Integer.to_string(next_offset)
                 },
                 turn: turn_ref
               ),
               route
             )

    second = job_payload(second_response)
    remaining = binary_part(output_text, next_offset, byte_size(output_text) - next_offset)

    assert second.result_output_text ==
             Ankole.Text.utf8_prefix(remaining, 16_384)

    assert {:ok, invalid_response} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-result-invalid-offset",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{
                   job_id: job_id,
                   result_offset: "1"
                 },
                 turn: turn_ref
               ),
               route
             )

    assert rpc_error(invalid_response)["code"] ==
             "invalid_background_agent_job_result_offset"

    assert {:ok, oversized_response} =
             RPCLane.handle_request(
               rpc_request(
                 "background-agent-job-result-oversized-offset",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{
                   job_id: job_id,
                   result_offset: "2147483647"
                 },
                 turn: turn_ref
               ),
               route
             )

    assert rpc_error(oversized_response)["code"] ==
             "invalid_background_agent_job_result_offset"
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
                   workspace_template_id: "deep-research",
                   title: "Forecast the outcome",
                   task: "Research and produce a forecast dossier."
                 },
                 turn: parent_turn
               ),
               route
             )

    job_id = job_payload(created).job_id
    job = BackgroundAgentJobs.get_job_for_agent(domain_job_id!(job_id), agent.uid)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ReadyEventProcessor.process_ready_event_for_actor(
               %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)},
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

    assert trajectory == %{"format" => "ankole_chatml", "version" => 1}

    refute inspect(trajectory) =~ "json_rpc"

    assert {:ok, items_response} =
             RPCLane.handle_request(
               rpc_request(
                 "job-turn-items",
                 "background_agent_job.turn_items.list",
                 %FabricProto.BackgroundAgentJobTurnItemsListRequest{job_id: job_id},
                 turn: job_turn
               ),
               route
             )

    items_payload =
      rpc_response_payload!(items_response, FabricProto.BackgroundAgentJobTurnItemsListResponse)

    assert items_payload.next_cursor == ""
    assert [stored_item] = items_payload.items
    assert stored_item.item_key == "assistant:researching"
    assert Torque.decode!(stored_item.item_json)["type"] == "agentMessage"

    assert {:ok, items_rejected} =
             RPCLane.handle_request(
               rpc_request(
                 "parent-turn-items",
                 "background_agent_job.turn_items.list",
                 %FabricProto.BackgroundAgentJobTurnItemsListRequest{job_id: job_id},
                 turn: parent_turn
               ),
               route
             )

    assert rpc_error(items_rejected)["code"] == "background_agent_job_turn_mismatch"

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
             %{
               "id" => "assistant:researching",
               "role" => "assistant",
               "content" => "Researching.",
               "metadata" => %{"phase" => "assistant"}
             }
           ]

    completed_at = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()

    completed_request = %{
      turn_upsert_request(job_id)
      | revision: 1,
        status: "completed",
        completed_at: completed_at,
        turn_items_json:
          Torque.encode!([
            %{
              "position" => 1,
              "item_key" => "assistant:research-complete",
              "item" => %{
                "type" => "agentMessage",
                "id" => "assistant:research-complete",
                "text" => "Research complete."
              }
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
    assert [_single_turn] = BackgroundAgentJobs.list_turns(job.id)

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
             %{
               "id" => "assistant:research-complete",
               "role" => "assistant",
               "content" => "Research complete.",
               "metadata" => %{"phase" => "assistant"}
             }
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
          "version" => 1
        }),
      turn_items_json:
        Torque.encode!([
          %{
            "position" => 0,
            "item_key" => "assistant:researching",
            "item" => %{
              "type" => "agentMessage",
              "id" => "assistant:researching",
              "text" => "Researching."
            }
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

  defp job_payload(envelope) do
    assert envelope_body_type(envelope) == :rpc_response, inspect(envelope)
    rpc_response_payload!(envelope, FabricProto.BackgroundAgentJobResponse)
  end

  defp domain_job_id!(wire_id) do
    assert {:ok, job_id} = BackgroundAgentJobs.parse_job_id(wire_id)
    job_id
  end

  defp rpc_error(envelope) do
    assert envelope_body_type(envelope) == :rpc_error
    rpc_error_payload!(envelope)
  end
end
