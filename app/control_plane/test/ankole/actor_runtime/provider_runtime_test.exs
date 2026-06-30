defmodule Ankole.ActorRuntime.ProviderRuntimeTest do
  use Ankole.ActorRuntimeCase

  describe "provider and worker-runtime commit edges" do
    test "preserves worker reply attachments through the RuntimeFabric user story" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      worker_id = "worker-attachment-" <> Integer.to_string(System.unique_integer([:positive]))

      assert {:ok, endpoint} =
               Broker.start_router("tcp://127.0.0.1:*",
                 worker_auth_key: "test-token",
                 poll_interval_ms: 1
               )

      on_exit(fn -> Broker.stop_router() end)

      worker_task =
        Task.async(fn ->
          System.cmd("bun", ["--eval", runtime_fabric_attachment_worker_script()],
            cd: runtime_fabric_kernel_dir(),
            env: [
              {"ANKOLE_RF_ENDPOINT", endpoint},
              {"ANKOLE_RF_IDENTITY", worker_id},
              {"ANKOLE_RF_WORKER_ID", worker_id},
              {"ANKOLE_RF_TOKEN", "test-token"}
            ],
            stderr_to_stdout: true
          )
        end)

      on_exit(fn ->
        if Process.alive?(worker_task.pid) do
          Process.exit(worker_task.pid, :kill)
        end
      end)

      assert %AgentComputerWorker{status: "ready", transport_route: ^worker_id} =
               wait_for_worker(worker_id, worker_task)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "Send the report", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert {output, 0} = Task.await(worker_task, 5_000)
      assert output =~ "worker-complete"

      assert %OutboxEntry{payload: payload} = wait_for_attachment_outbox(input.id)

      assert payload == %{
               "text" => "Here is the report.",
               "attachments" => [
                 %{
                   "agent_computer_path" => "/workspace/user-files/reports/a.txt",
                   "user_files_relative_path" => "reports/a.txt",
                   "name" => "report.txt",
                   "mime_type" => "text/plain",
                   "size" => 16
                 }
               ]
             }
    end

    test "provider-routed final proposal must include visible reply text" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: "openrouter-commit-guard",
                 provider_kind: "openrouter",
                 base_url: "https://openrouter.ai/api/v1",
                 connection_options: %{
                   "api_key" => "sk-test"
                 }
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "primary", %{
                 provider_id: "openrouter-commit-guard",
                 model: "google/gemini-3.5-flash"
               })

      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, %{actor_input: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "Call a tool and answer", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert %LlmTurn{
               provider: "openrouter",
               provider_metadata: %{"provider_id" => "openrouter-commit-guard"}
             } = Repo.get!(LlmTurn, llm_turn.id)

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:error, :proposal_reply_missing} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => []
                 }
               })

      assert Repo.get!(ActorInput, input.id).input_state == "open"
      assert Repo.get!(LlmTurn, llm_turn.id).status == "started"

      assert Repo.aggregate(from(message in Message, where: message.role == "assistant"), :count) ==
               0

      assert Repo.aggregate(OutboxEntry, :count) == 0
    end

    test "commits final proposal telemetry for provider-routed turns" do
      %{principal: agent} = agent_fixture()

      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: "openrouter-telemetry-commit",
                 provider_kind: "openrouter",
                 base_url: "https://openrouter.ai/api/v1",
                 connection_options: %{
                   "api_key" => "sk-test"
                 }
               })

      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(agent.uid, "primary", %{
                 provider_id: "openrouter-telemetry-commit",
                 model: "google/gemini-3.5-flash"
               })

      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()

      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)

      assert {:ok, _worker} = admit_worker(route)

      assert {:ok, _result} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "Use the tool and answer", explicit: true}),
                 now: @base_time
               )

      assert {:ok, %{llm_turn: llm_turn}} =
               ActorRuntime.process_ready_inputs_once(
                 now: DateTime.add(@base_time, 1, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert %LlmTurn{provider_metadata: %{"provider_id" => "openrouter-telemetry-commit"}} =
               Repo.get!(LlmTurn, llm_turn.id)

      assert_receive {:actor_lane, envelope}

      turn_start = envelope["body"]["turn_start"]
      turn_ref = turn_start["turn"]
      input_ids = Enum.map(turn_start["inputs"], & &1["actor_input_id"])

      assert {:ok, [%ActorInputDelivery{state: "accepted"}]} =
               ActorRuntime.handle_turn_accepted(%{
                 "turn_accepted" => %{
                   "turn" => turn_ref,
                   "accepted_actor_input_ids" => input_ids
                 }
               })

      assert {:ok, _result} =
               ActorRuntime.commit_final_proposal(%{
                 "turn_final_proposal" => %{
                   "turn" => turn_ref,
                   "messages" => [],
                   "reply" => %{"text" => "Tool result committed"},
                   "usage_json" => %{
                     "input" => 11,
                     "output" => 7,
                     "cacheRead" => 2,
                     "cacheWrite" => 0,
                     "totalTokens" => 20,
                     "cost" => %{
                       "input" => 0.0011,
                       "output" => 0.0021,
                       "cacheRead" => 0.0,
                       "cacheWrite" => 0.0,
                       "total" => 0.0032
                     }
                   },
                   "provider_metadata_json" => %{
                     "provider_kind" => "openrouter",
                     "response_id" => "resp_123",
                     "response_model" => "google/gemini-3.5-flash"
                   },
                   "stop_reason" => "stop",
                   "tool_results_json" => [
                     %{
                       "tool_call_id" => "call_1",
                       "tool_name" => "command",
                       "args" => %{"cmd" => "printf ok"},
                       "is_error" => false,
                       "result" => %{
                         "content" => [%{"type" => "text", "text" => "ok"}]
                       }
                     }
                   ]
                 }
               })

      assert %LlmTurn{} = persisted = Repo.get!(LlmTurn, llm_turn.id)
      assert persisted.status == "succeeded"
      assert persisted.usage["input"] == 11
      assert persisted.usage["totalTokens"] == 20
      assert persisted.provider_metadata["provider_id"] == "openrouter-telemetry-commit"
      assert persisted.provider_metadata["provider_kind"] == "openrouter"
      assert persisted.provider_metadata["response_id"] == "resp_123"
      assert persisted.provider_metadata["response_model"] == "google/gemini-3.5-flash"
      assert persisted.response["stop_reason"] == "stop"

      assert [
               %{
                 "tool_call_id" => "call_1",
                 "tool_name" => "command",
                 "is_error" => false,
                 "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
               }
             ] = persisted.tool_results
    end
  end
end
