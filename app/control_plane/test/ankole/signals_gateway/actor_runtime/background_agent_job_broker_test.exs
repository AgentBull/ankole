defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBrokerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Conversations.{Admission, CodexJob, Run}

  test "RPC rejects a conversation RunRef for Job operations on either connection" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    wrong_route = unique_route()
    parent = start_parent_turn!(agent.uid, route)
    assert {:ok, _worker} = admit_worker(wrong_route, %{worker_id: other_agent.uid})
    job = create_job!(agent.uid, parent, "auth")
    job_id = Integer.to_string(job.id)

    assert {:ok, rejected} =
             handle_rpc(
               rpc_request(
                 "wrong-agent",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{job_id: job_id},
                 run: parent
               ),
               wrong_route,
               other_agent.uid
             )

    assert rpc_error(rejected)["code"] == "run_closed"

    for {method, payload} <- [
          {"background_agent_job.get", %FabricProto.BackgroundAgentJobGetRequest{job_id: job_id}},
          {"background_agent_job.turn.upsert", turn_upsert_request(job_id)},
          {"background_agent_job.turn_items.list",
           %FabricProto.BackgroundAgentJobTurnItemsListRequest{job_id: job_id}},
          {"background_agent_job.status.update",
           %FabricProto.BackgroundAgentJobStatusUpdateRequest{job_id: job_id, status: "running"}}
        ] do
      assert {:ok, rejected} =
               handle_rpc(rpc_request(method, method, payload, run: parent), route, agent.uid)

      assert rpc_error(rejected)["code"] == "invalid_job_turn_ref"
    end
  end

  test "upsert rejects a request attempt outside the locked Job attempt without writing a Turn" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    parent = start_parent_turn!(agent.uid, route)
    job = create_job!(agent.uid, parent, "wrong-attempt")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)
    assert {:ok, %{event: event}} = Run.rebuild(key, now)
    assert {:ok, run} = Admission.admit(key, event, now: now)
    assert {:ok, _} = CodexJob.start(run)
    assert_receive {:actor_lane, envelope}, 200
    job_turn = turn_start_payload!(envelope).turn
    assert job_turn.attempt == 1
    assert Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, job.id).attempts == 1
    refute Repo.get_by(Ankole.BackgroundAgentJobs.Schemas.Turn, job_id: job.id)

    assert {:ok, rejected} =
             handle_rpc(
               rpc_request(
                 "wrong-attempt",
                 "background_agent_job.turn.upsert",
                 %{turn_upsert_request(Integer.to_string(job.id)) | attempt: 2},
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    error = rpc_error(rejected)
    assert error["code"] == "background_agent_job_turn_attempt_mismatch"
    assert envelope_body!(rejected, :rpc_error).retryable == false
    refute Repo.get_by(Ankole.BackgroundAgentJobs.Schemas.Turn, job_id: job.id)
  end

  test "Deep Research turns use the shared Turn trajectory" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    parent_turn = start_parent_turn!(agent.uid, route)

    job =
      create_job!(agent.uid, parent_turn, "research", %{
        "workspace_template_id" => "deep-research"
      })

    job_id = Integer.to_string(job.id)
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, %{event: event}} = Run.rebuild(key, DateTime.add(job.queued_at, 1, :second))
    assert {:ok, run} = Admission.admit(key, event, now: DateTime.add(job.queued_at, 1, :second))
    assert {:ok, _} = CodexJob.start(run)

    assert_receive {:actor_lane, dispatch_envelope}, 200
    job_turn = turn_start_payload!(dispatch_envelope).turn

    assert {:ok, _running_response} =
             handle_rpc(
               rpc_request(
                 "job-running",
                 "background_agent_job.status.update",
                 %FabricProto.BackgroundAgentJobStatusUpdateRequest{
                   job_id: job_id,
                   status: "running",
                   runtime_thread_id: "thread-1"
                 },
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    assert {:ok, turn_response} =
             handle_rpc(
               rpc_request(
                 "turn-upsert",
                 "background_agent_job.turn.upsert",
                 turn_upsert_request(job_id),
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    turn_payload =
      rpc_response_payload!(turn_response, FabricProto.BackgroundAgentJobTurnUpsertResponse).turn

    assert turn_payload.status == "in_progress"
    assert turn_payload.runtime_turn_id == "turn-1"

    trajectory = Torque.decode!(turn_payload.trajectory_json)

    assert trajectory == %{"format" => "ankole_chatml", "version" => 1}

    refute inspect(trajectory) =~ "json_rpc"

    assert {:ok, items_response} =
             handle_rpc(
               rpc_request(
                 "job-turn-items",
                 "background_agent_job.turn_items.list",
                 %FabricProto.BackgroundAgentJobTurnItemsListRequest{job_id: job_id},
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    items_payload =
      rpc_response_payload!(items_response, FabricProto.BackgroundAgentJobTurnItemsListResponse)

    assert items_payload.next_cursor == ""
    assert [stored_item] = items_payload.items
    assert stored_item.item_key == "assistant:researching"
    assert Torque.decode!(stored_item.item_json)["type"] == "agentMessage"

    assert {:ok, items_rejected} =
             handle_rpc(
               rpc_request(
                 "parent-turn-items",
                 "background_agent_job.turn_items.list",
                 %FabricProto.BackgroundAgentJobTurnItemsListRequest{job_id: job_id},
                 run: parent_turn
               ),
               route,
               agent.uid
             )

    assert rpc_error(items_rejected)["code"] == "invalid_job_turn_ref"

    assert {:ok, in_progress_response} =
             handle_rpc(
               rpc_request(
                 "job-in-progress",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{job_id: job_id},
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    assert job_payload(in_progress_response).status == "running"

    assert {:ok, %{execution: in_progress_execution}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid, trajectory_limit: 1)

    assert in_progress_execution.trajectory_page.messages == [
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
             handle_rpc(
               rpc_request(
                 "turn-completed",
                 "background_agent_job.turn.upsert",
                 completed_request,
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    completed_turn =
      rpc_response_payload!(completed_response, FabricProto.BackgroundAgentJobTurnUpsertResponse).turn

    assert completed_turn.status == "completed"
    assert completed_turn.revision == 1

    assert {:ok, stale_response} =
             handle_rpc(
               rpc_request(
                 "turn-stale-retry",
                 "background_agent_job.turn.upsert",
                 %{completed_request | revision: 0, status: "in_progress", completed_at: ""},
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    stale_turn =
      rpc_response_payload!(stale_response, FabricProto.BackgroundAgentJobTurnUpsertResponse).turn

    assert stale_turn.status == "completed"
    assert [_single_turn] = BackgroundAgentJobs.list_turns(job.id)

    assert {:ok, status_response} =
             handle_rpc(
               rpc_request(
                 "job-status",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{job_id: job_id},
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    assert job_payload(status_response).status == "running"

    assert {:ok, %{execution: execution}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid, trajectory_limit: 1)

    assert execution.lead_turn_number == 1

    assert execution.turns == %{
             lead: 1,
             child: 0,
             compaction: 0,
             active: 0
           }

    assert execution.trajectory_page.messages == [
             %{
               "id" => "assistant:research-complete",
               "role" => "assistant",
               "content" => "Research complete.",
               "metadata" => %{"phase" => "assistant"}
             }
           ]

    assert {:error, :invalid_background_agent_job_trajectory_cursor} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid,
               trajectory_cursor: "not-a-cursor"
             )

    error = %{"message" => "model request failed", "codexErrorInfo" => "internalServerError"}

    assert {:ok, failed_response} =
             handle_rpc(
               rpc_request(
                 "turn-failed",
                 "background_agent_job.turn.upsert",
                 %{
                   turn_upsert_request(job_id)
                   | runtime_turn_id: "turn-2",
                     status: "failed",
                     completed_at: DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
                     turn_items_json: Torque.encode!([]),
                     error_json: Torque.encode!(error)
                 },
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    assert rpc_response_payload!(
             failed_response,
             FabricProto.BackgroundAgentJobTurnUpsertResponse
           ).turn.status ==
             "failed"

    assert {:ok, failure_details} =
             handle_rpc(
               rpc_request(
                 "job-failure-details",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{job_id: job_id},
                 job_turn: job_turn
               ),
               route,
               agent.uid
             )

    payload = job_payload(failure_details)
    assert payload.status == "running"

    assert {:ok, %{execution: failure_execution}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid)

    assert failure_execution.current.error == error
  end

  test "a continuation reads complete UTF-8 result windows only from its direct source" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    route = unique_route()
    parent = start_parent_turn!(agent.uid, route)
    source = create_job!(agent.uid, parent, "source")
    output = "SOURCE_DONE:" <> String.duplicate("界", 20_000)

    source
    |> Ecto.Changeset.change(
      status: "succeeded",
      runtime_thread_id: "source-thread",
      workspace_owner_job_id: source.id,
      completed_at: DateTime.utc_now(:microsecond),
      result: %{"output_text" => output}
    )
    |> Repo.update!()

    assert {:ok, %{job: successor}} =
             BackgroundAgentJobs.respawn_with_dispatch(source.id, %{
               "agent_uid" => agent.uid,
               "owner_session_id" => parent.actor.session_id,
               "source_actor_event_id" => parent.actor_event_id,
               "source_tool_call_id" => "continue-source",
               "message" => "Continue the work.",
               "reply_route" => source.reply_route
             })

    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(successor.id)}
    now = DateTime.add(successor.queued_at, 1, :second)
    assert {:ok, %{event: event}} = Run.rebuild(key, now)
    assert {:ok, run} = Admission.admit(key, event, now: now)
    assert {:ok, _} = CodexJob.start(run)
    assert_receive {:actor_lane, dispatch_envelope}, 200
    job_turn = turn_start_payload!(dispatch_envelope).turn

    chunks =
      Stream.unfold(0, fn offset ->
        if offset < byte_size(output) do
          response = read_result!(source.id, offset, job_turn, route, agent.uid)
          assert response.task == source.task
          assert response.result_output_total_bytes == Integer.to_string(byte_size(output))
          assert String.valid?(response.result_output_text)
          assert byte_size(response.result_output_text) in 1..16_384
          {response.result_output_text, offset + byte_size(response.result_output_text)}
        end
      end)
      |> Enum.to_list()

    assert length(chunks) > 1
    assert Enum.join(chunks) == output

    assert read_result!(source.id, byte_size(output), job_turn, route, agent.uid).result_output_text ==
             ""

    unrelated = create_job!(agent.uid, parent, "unrelated")
    other = create_job!(other_agent.uid, parent, "other")

    for {job, expected} <- [
          {unrelated, "background_agent_job_scope_mismatch"},
          {other, "job_not_found"}
        ] do
      assert {:ok, rejected} =
               handle_rpc(
                 rpc_request(
                   "denied-source",
                   "background_agent_job.get",
                   %FabricProto.BackgroundAgentJobGetRequest{
                     job_id: Integer.to_string(job.id),
                     result_offset: "0"
                   },
                   job_turn: job_turn
                 ),
                 route,
                 agent.uid
               )

      assert rpc_error(rejected)["code"] == expected
    end
  end

  defp read_result!(job_id, offset, turn, route, agent_uid) do
    assert {:ok, response} =
             handle_rpc(
               rpc_request(
                 "read-source",
                 "background_agent_job.get",
                 %FabricProto.BackgroundAgentJobGetRequest{
                   job_id: Integer.to_string(job_id),
                   result_offset: Integer.to_string(offset)
                 },
                 job_turn: turn
               ),
               route,
               agent_uid
             )

    job_payload(response)
  end

  defp start_parent_turn!(agent_uid, route) do
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route, %{worker_id: agent_uid})

    assert {:ok, %{actor_event: input}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(%{text: "Delegate this work", explicit: true}),
               now: @base_time
             )

    assert {:ok, _run} = Admission.admit(input, input)

    %FabricProto.RunRef{
      actor: %FabricProto.ActorKey{session_id: input.session_id},
      actor_event_id: input.id
    }
  end

  defp create_job!(agent_uid, parent, suffix, extra \\ %{}) do
    assert {:ok, %{job: job}} =
             Repo.transact(fn _ ->
               BackgroundAgentJobs.create_with_dispatch(
                 Map.merge(
                   %{
                     "agent_uid" => agent_uid,
                     "owner_session_id" => parent.actor.session_id,
                     "source_actor_event_id" => parent.actor_event_id,
                     "source_tool_call_id" => "job-#{suffix}",
                     "title" => "Delegated work",
                     "task" => "Finish the delegated work.",
                     "reply_route" => %{"binding_name" => "bot"}
                   },
                   extra
                 )
               )
             end)

    job
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

  defp rpc_error(envelope) do
    assert envelope_body_type(envelope) == :rpc_error
    rpc_error_payload!(envelope)
  end
end
