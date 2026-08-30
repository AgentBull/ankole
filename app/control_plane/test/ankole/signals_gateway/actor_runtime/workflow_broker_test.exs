defmodule Ankole.SignalsGateway.ActorRuntime.WorkflowBrokerTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkflowBroker
  alias Ankole.Workflow

  test "create, get, list, and cancel use decimal IDs and exact generated responses" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    turn_ref = turn_ref(source)

    assert {:ok, %FabricProto.WorkflowCreateResponse{run_id: run_id, status: "running"}} =
             WorkflowBroker.handle_create(
               turn_ref,
               %FabricProto.WorkflowCreateRequest{
                 source_tool_call_id: "tool-workflow-broker",
                 title: "Review the release",
                 script: "return await agent('Review the release');",
                 args_json: Torque.encode!(%{"release" => "v1"}),
                 concurrency: 4,
                 max_agent_calls: 12
               },
               rpc_ctx("create")
             )

    assert {:ok, run_id_integer} = Workflow.parse_run_id(run_id)

    assert {:ok, %FabricProto.WorkflowGetResponse{} = get} =
             WorkflowBroker.handle_get(
               turn_ref,
               %FabricProto.WorkflowGetRequest{run_id: run_id},
               rpc_ctx("get")
             )

    assert get.run_id == run_id
    assert get.status == "running"
    assert Torque.decode!(get.counts_json)["total"] == 0

    assert {:ok, %FabricProto.WorkflowListResponse{} = list} =
             WorkflowBroker.handle_list(
               turn_ref,
               %FabricProto.WorkflowListRequest{status: "live"},
               rpc_ctx("list")
             )

    assert [%{"run_id" => ^run_id, "status" => "running"}] = Torque.decode!(list.runs_json)

    assert {:ok, %FabricProto.WorkflowCancelResponse{run_id: ^run_id, status: "cancelled"}} =
             WorkflowBroker.handle_cancel(
               turn_ref,
               %FabricProto.WorkflowCancelRequest{run_id: Integer.to_string(run_id_integer)},
               rpc_ctx("cancel")
             )
  end

  test "create rejects both Job and Workflow task owner sessions" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)

    request = %FabricProto.WorkflowCreateRequest{
      source_tool_call_id: "tool-owner-guard",
      title: "Nested Workflow",
      script: "return 'no';"
    }

    for session_id <- ["job:1000", "wf_task:1000"] do
      assert {:error, %{"code" => "workflow_owner_turn_required"}} =
               WorkflowBroker.handle_create(
                 %{turn_ref(source) | session_id: session_id},
                 request,
                 rpc_ctx("guard")
               )
    end
  end

  test "create rejects whitespace-padded args above the raw 64 KiB wire cap" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)
    padded_args = String.duplicate(" ", 65_536) <> "{}"

    assert byte_size(padded_args) > 65_536

    assert {:error, %{"code" => "workflow_args_too_large"}} =
             WorkflowBroker.handle_create(
               turn_ref(source),
               %FabricProto.WorkflowCreateRequest{
                 source_tool_call_id: "tool-oversized-args",
                 title: "Oversized args",
                 script: "return 'no';",
                 args_json: padded_args
               },
               rpc_ctx("oversized-args")
             )
  end

  test "task result submit requires the exact same-Agent Workflow task session" do
    %{principal: agent} = agent_fixture()
    source = source_event!(agent.uid)

    {:ok, %{run: run}} =
      Workflow.create_with_dispatch(%{
        "agent_uid" => agent.uid,
        "owner_session_id" => source.session_id,
        "reply_route" => %{"binding_name" => source.binding_name},
        "source_actor_event_id" => source.id,
        "source_tool_call_id" => "tool-submit",
        "title" => "Submit",
        "script" => "return await agent('Submit');",
        "args" => %{}
      })

    assert {:ok, %{new_calls: [call]}} =
             Workflow.commit_replay_pending(
               run.id,
               [
                 %{
                   namespace: nil,
                   name: "agent",
                   arguments: %{"prompt" => "Submit.", "schema" => %{"type" => "boolean"}}
                 }
               ],
               0
             )

    {:ok, %{call: call}} = Workflow.claim_task_in_tx(Repo, call.id, agent.uid, 8)

    request = %FabricProto.WorkflowTaskResultSubmitRequest{
      call_id: Integer.to_string(call.id),
      ok: true,
      value_json: Torque.encode!(false)
    }

    assert {:error, %{"code" => "workflow_task_session_mismatch"}} =
             WorkflowBroker.handle_task_result_submit(
               %{turn_ref(source) | session_id: "wf_task:9999"},
               request,
               rpc_ctx("wrong-session")
             )

    padded_value = String.duplicate(" ", 24_576) <> "false"
    assert byte_size(padded_value) > 24_576

    assert {:error, %{"code" => "workflow_result_too_large"}} =
             WorkflowBroker.handle_task_result_submit(
               %{turn_ref(source) | session_id: Workflow.task_session_id(call.id)},
               %{request | value_json: padded_value},
               rpc_ctx("oversized-result")
             )

    assert {:ok,
            %FabricProto.WorkflowTaskResultSubmitResponse{
              accepted: true,
              task_status: "succeeded"
            }} =
             WorkflowBroker.handle_task_result_submit(
               %{turn_ref(source) | session_id: Workflow.task_session_id(call.id)},
               request,
               rpc_ctx("submit")
             )
  end

  defp source_event!(agent_uid) do
    unique = System.unique_integer([:positive])

    {:ok, event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        binding_name: "bot",
        session_id: "session-#{unique}",
        source_event_id: "source-#{unique}",
        signal_channel_id: "channel-#{unique}",
        provider_thread_id: "thread-#{unique}",
        source_entry_id: "entry-#{unique}",
        type: "im.message.addressed",
        available_at: DateTime.utc_now(),
        payload: %{
          "specversion" => "1.0",
          "id" => "source-#{unique}",
          "source" => "test://workflow-broker",
          "type" => "im.message.addressed",
          "data" => %{}
        }
      })

    event
  end

  defp turn_ref(source) do
    %TurnRef{
      agent_uid: source.agent_uid,
      session_id: source.session_id,
      activation_uid: "workflow-broker-test",
      actor_epoch: 1,
      actor_event_id: source.id,
      revision: 0
    }
  end

  defp rpc_ctx(request_id), do: %{route: "worker-route", request_id: request_id}
end
