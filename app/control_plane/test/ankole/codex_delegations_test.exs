defmodule Ankole.CodexDelegationsTest do
  use Ankole.AIGatewayCase

  alias Ankole.CodexDelegations

  test "RuntimeFabric Codex delegation RPC persists lifecycle and redacted trajectory events" do
    %{principal: agent} = agent_fixture()

    assert {:ok, create_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-create-1",
                 "method" => "codex.delegation.create",
                 "payload_json" => %{
                   "agent_uid" => agent.uid,
                   "session_id" => "session-1",
                   "tool_call_id" => "toolu-codex-1",
                   "workdir" => "/workspace/repo",
                   "metadata" => %{"prompt_chars" => 42}
                 }
               },
               "trusted-worker-route"
             )

    create_payload = rpc_payload(create_envelope)
    delegation_id = create_payload["delegation_id"]
    assert create_payload["status"] == "queued"
    assert create_payload["agent_uid"] == agent.uid

    delegation = CodexDelegations.get_delegation_for_agent(delegation_id, agent.uid)
    assert delegation.session_id == "session-1"
    assert delegation.metadata == %{"prompt_chars" => 42}

    assert {:ok, event_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-event-1",
                 "method" => "codex.delegation.event.append",
                 "payload_json" => %{
                   "delegation_id" => delegation_id,
                   "agent_uid" => agent.uid,
                   "seq" => 0,
                   "direction" => "client_to_server",
                   "event_type" => "json_rpc",
                   "payload" => %{
                     "method" => "initialize",
                     "headers" => %{"Authorization" => "Bearer secret-token"},
                     "nested" => [%{"api_key" => "sk-secret"}],
                     "visible" => true
                   }
                 }
               },
               "trusted-worker-route"
             )

    assert rpc_payload(event_envelope)["seq"] == 0

    [event] = CodexDelegations.list_events(delegation_id)
    assert event.payload["method"] == "initialize"
    assert event.payload["visible"] == true
    assert event.payload["headers"]["Authorization"] =~ "[REDACTED:sha256="
    assert get_in(event.payload, ["nested", Access.at(0), "api_key"]) =~ "[REDACTED:sha256="
    refute inspect(event.payload) =~ "secret-token"
    refute inspect(event.payload) =~ "sk-secret"
    assert "$.headers.Authorization" in event.redaction["redacted_paths"]
    assert "$.nested.0.api_key" in event.redaction["redacted_paths"]

    assert {:ok, running_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-status-1",
                 "method" => "codex.delegation.status.update",
                 "payload_json" => %{
                   "delegation_id" => delegation_id,
                   "agent_uid" => agent.uid,
                   "status" => "running",
                   "codex_thread_id" => "thread-1"
                 }
               },
               "trusted-worker-route"
             )

    running_payload = rpc_payload(running_envelope)
    assert running_payload["status"] == "running"
    assert running_payload["codex_thread_id"] == "thread-1"
    assert is_binary(running_payload["started_at"])

    assert {:ok, succeeded_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-status-2",
                 "method" => "codex.delegation.status.update",
                 "payload_json" => %{
                   "delegation_id" => delegation_id,
                   "agent_uid" => agent.uid,
                   "status" => "succeeded",
                   "result" => %{"output_text" => "done"}
                 }
               },
               "trusted-worker-route"
             )

    succeeded_payload = rpc_payload(succeeded_envelope)
    assert succeeded_payload["status"] == "succeeded"
    assert succeeded_payload["result"] == %{"output_text" => "done"}
    assert is_binary(succeeded_payload["completed_at"])
  end

  test "Codex delegation RPC returns a stable error for unknown delegation ids" do
    %{principal: agent} = agent_fixture()

    assert {:ok, envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-status-missing",
                 "method" => "codex.delegation.status.update",
                 "payload_json" => %{
                   "delegation_id" => Ecto.UUID.generate(),
                   "agent_uid" => agent.uid,
                   "status" => "running"
                 }
               },
               "trusted-worker-route"
             )

    assert get_in(envelope, ["body", "type"]) == "rpc_error"
    assert get_in(envelope, ["body", "rpc_error", "code"]) == "delegation_not_found"
  end

  test "Codex delegation running admission is globally limited per agent in the database" do
    %{principal: agent} = agent_fixture()

    delegation_ids =
      for index <- 1..4 do
        {:ok, envelope} =
          RPCLane.handle_request(
            %{
              "request_id" => "codex-create-#{index}",
              "method" => "codex.delegation.create",
              "payload_json" => %{
                "agent_uid" => agent.uid,
                "session_id" => "session-#{index}",
                "tool_call_id" => "tool-call-#{index}"
              }
            },
            "trusted-worker-route"
          )

        rpc_payload(envelope)["delegation_id"]
      end

    for delegation_id <- Enum.take(delegation_ids, 3) do
      assert {:ok, envelope} =
               RPCLane.handle_request(
                 %{
                   "request_id" => "codex-running-#{delegation_id}",
                   "method" => "codex.delegation.status.update",
                   "payload_json" => %{
                     "delegation_id" => delegation_id,
                     "agent_uid" => agent.uid,
                     "status" => "running"
                   }
                 },
                 "trusted-worker-route"
               )

      assert rpc_payload(envelope)["status"] == "running"
    end

    fourth_id = List.last(delegation_ids)

    assert {:ok, rejected_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-running-fourth",
                 "method" => "codex.delegation.status.update",
                 "payload_json" => %{
                   "delegation_id" => fourth_id,
                   "agent_uid" => agent.uid,
                   "status" => "running"
                 }
               },
               "trusted-worker-route"
             )

    assert get_in(rejected_envelope, ["body", "type"]) == "rpc_error"

    assert get_in(rejected_envelope, ["body", "rpc_error", "code"]) ==
             "codex_agent_running_limit_exceeded"

    assert CodexDelegations.get_delegation_for_agent(fourth_id, agent.uid).status == "queued"

    [first_id | _rest] = delegation_ids

    assert {:ok, _finished_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-finished-first",
                 "method" => "codex.delegation.status.update",
                 "payload_json" => %{
                   "delegation_id" => first_id,
                   "agent_uid" => agent.uid,
                   "status" => "succeeded"
                 }
               },
               "trusted-worker-route"
             )

    assert {:ok, admitted_envelope} =
             RPCLane.handle_request(
               %{
                 "request_id" => "codex-running-fourth-retry",
                 "method" => "codex.delegation.status.update",
                 "payload_json" => %{
                   "delegation_id" => fourth_id,
                   "agent_uid" => agent.uid,
                   "status" => "running"
                 }
               },
               "trusted-worker-route"
             )

    assert rpc_payload(admitted_envelope)["status"] == "running"
  end

  defp rpc_payload(envelope) do
    assert get_in(envelope, ["body", "type"]) == "rpc_response"
    get_in(envelope, ["body", "rpc_response", "payload_json"])
  end
end
