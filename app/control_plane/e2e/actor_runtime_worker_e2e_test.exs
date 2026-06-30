defmodule Ankole.ActorRuntimeWorkerE2ETest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import ExUnit.Assertions
  import Ankole.ActorRuntimeWorkerE2E.DockerWorker

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [
      checkback_by_idempotency!: 2,
      command_tool_succeeded?: 1,
      cron_event_for_schedule!: 1,
      cron_schedule_by_idempotency!: 2,
      seed_compression_history!: 2,
      tool_result_succeeded?: 2
    ]

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Registry, as: PluginRegistry
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.Actors.ActorInputConsumption

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @e2e_timeout_ms 12_000
  @real_e2e_timeout_ms 600_000
  @long_lease_seconds 604_800

  @tag timeout: 45_000
  test "Docker image worker connects to RuntimeFabric and is admitted" do
    assert_docker_image!()

    worker_id = "docker-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: worker_auth_key
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline())
  end

  @tag timeout: 30_000
  test "Docker image worker with the wrong global worker auth key is not admitted" do
    assert_docker_image!()

    worker_id = "docker-rejected-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: "wrong-" <> worker_auth_key
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    refute_worker_projection_until(
      worker_id,
      container,
      System.monotonic_time(:millisecond) + 1_500
    )

    assert Repo.get_by(AgentComputerWorker, worker_id: worker_id) == nil
  end

  test "Docker image worker fails fast with structured error when required env is missing" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"WORKER_ID", "worker-missing-env"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "RUNTIME_FABRIC_URL is required"
  end

  test "Docker image worker rejects actor-specific startup env" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"RUNTIME_FABRIC_URL", "tcp://:unused-test-secret@host.docker.internal:1"},
               {"WORKER_ID", "worker-actor-env"},
               {"ANKOLE_AGENT_UID", "agent-1"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "ANKOLE_AGENT_UID must not be set on an agent computer worker"
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :real_llm
  test "Docker daemon worker drives mock IM input through real OpenRouter LLM tool loop" do
    assert_docker_image!()

    openrouter_api_key =
      System.get_env("OPENROUTER_API_KEY") ||
        System.get_env("OPEN_ROUTER_API_KEY") ||
        flunk("OPENROUTER_API_KEY or OPEN_ROUTER_API_KEY is required for real provider e2e")

    %{principal: agent} = committed_agent_fixture!()
    adapter = mock_provider_adapter()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-e2e",
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{"api_key" => openrouter_api_key}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-e2e",
               model: "google/gemini-3.5-flash",
               provider_options: %{"reasoning" => %{"effort" => "minimal", "exclude" => true}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: "openrouter-e2e",
               model: "openai/gpt-5.4-nano",
               provider_options: %{"reasoning" => %{"effort" => "minimal", "exclude" => true}}
             })

    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "mock-real-llm",
        adapter: adapter.id,
        config_ref: "test://mock-provider",
        filters: %{},
        unaddressed_group_message_policy: :ignore
      })

    worker_id = "real-llm-worker-#{System.unique_integer([:positive])}"
    worker_auth_key = unique_worker_auth_key()

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth_key: worker_auth_key,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)
    start_ai_gateway_test_http_server!()

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_auth_key: worker_auth_key
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, real_deadline())

    context =
      AdapterContext.new(
        agent_uid: agent.uid,
        binding_name: binding.name,
        adapter: adapter.id,
        user_name: "Mock Provider"
      )

    consumer = adapter.ingress_module.chat_consumer(context, %{"provider" => "mock"})

    input =
      adapter.ingress_module.handle_message_receive(
        "mock.message.receive",
        %{
          ingress_event_id: "mock-real-llm-event-1",
          signal_channel_id: "mock:chat:real-llm-e2e",
          provider_entry_id: "mock-real-llm-message-1",
          provider_thread_id: "mock-real-llm-thread",
          text: """
          This is a two-step tool test.
          Step 1: If you have not yet received a skill_append tool result in this conversation, call skill_append exactly once with name exactly "nano-pdf" and content exactly "E2E overlay: ANKOLE_E2E_OK".
          Step 2: After the first successful skill_append tool result is visible, do not call any more tools. Reply exactly ANKOLE_E2E_OK.
          """,
          explicit: true,
          now: @base_time,
          provider_time: @base_time
        },
        [consumer]
      )
      |> receive_actor_input!()

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: first_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert {:ok, %OutboxEntry{} = outbox} =
             wait_for_outbox(container, real_deadline(), first_turn.id)

    refute Repo.get(ActorInput, input.id)
    assert Repo.get!(LlmTurn, outbox.llm_turn_id).status == "succeeded"
    assert outbox.payload["text"] =~ "ANKOLE_E2E_OK"

    assert %AgentSkillOverlay{overlay_json: %{"text" => content}} =
             AgentSkillOverlay
             |> where([overlay], overlay.agent_uid == ^agent.uid)
             |> where([overlay], overlay.skill_name == "nano-pdf")
             |> where([overlay], is_nil(overlay.deleted_at))
             |> Repo.one()

    assert content == "E2E overlay: ANKOLE_E2E_OK"

    rm_input =
      adapter.ingress_module.handle_message_receive(
        "mock.message.receive",
        %{
          ingress_event_id: "mock-real-llm-rm-overlay-file-1",
          signal_channel_id: "mock:chat:real-llm-e2e",
          provider_entry_id: "mock-real-llm-rm-overlay-file-message-1",
          provider_thread_id: "mock-real-llm-thread",
          text: """
          This is a two-step command test.
          Step 1: If you have not yet received a command tool result for this request, call the command tool exactly once. Run exactly: rm -f /workspace/library-containers/skills/nano-pdf/AGENT_APPEND.md
          Step 2: After the first successful command tool result is visible, do not call any more tools. Reply exactly ANKOLE_E2E_RM_OK.
          """,
          explicit: true,
          now: DateTime.add(@base_time, 2, :second),
          provider_time: DateTime.add(@base_time, 2, :second)
        },
        [consumer]
      )
      |> receive_actor_input!()

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: rm_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 3, :second),
               lease_seconds: @long_lease_seconds
             )

    assert {:ok, %OutboxEntry{} = rm_outbox} =
             wait_for_outbox_for_input(container, rm_input.id, real_deadline(), rm_turn.id)

    assert is_binary(rm_outbox.payload["text"])
    assert String.trim(rm_outbox.payload["text"]) != ""

    persisted_rm_turn = Repo.get!(LlmTurn, rm_outbox.llm_turn_id)

    assert persisted_rm_turn.status == "succeeded"
    assert command_tool_succeeded?(persisted_rm_turn.tool_results)

    active_overlay =
      AgentSkillOverlay
      |> where([overlay], overlay.agent_uid == ^agent.uid)
      |> where([overlay], overlay.skill_name == "nano-pdf")
      |> where([overlay], is_nil(overlay.deleted_at))
      |> Repo.one()

    assert %AgentSkillOverlay{overlay_json: %{"text" => "E2E overlay: ANKOLE_E2E_OK"}} =
             active_overlay

    compressed_seed_message_ids =
      seed_compression_history!(agent.uid, persisted_rm_turn.conversation_id)

    compress_input =
      adapter.ingress_module.handle_message_receive(
        "mock.message.receive",
        %{
          ingress_event_id: "mock-real-llm-compress-1",
          signal_channel_id: "mock:chat:real-llm-e2e",
          provider_entry_id: "mock-real-llm-compress-message-1",
          provider_thread_id: "mock-real-llm-thread",
          text: "/compress",
          explicit: true,
          now: DateTime.add(@base_time, 4, :second),
          provider_time: DateTime.add(@base_time, 4, :second)
        },
        [consumer]
      )
      |> receive_actor_input!()

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: compression_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 5, :second),
               lease_seconds: @long_lease_seconds
             )

    assert %LlmTurn{
             kind: "generation",
             profile: "primary",
             model: "google/gemini-3.5-flash"
           } = Repo.get!(LlmTurn, compression_turn.id)

    assert {:ok, %OutboxEntry{} = compress_outbox} =
             wait_for_outbox_for_input(
               container,
               compress_input.id,
               real_deadline(),
               compression_turn.id
             )

    assert compress_outbox.payload == %{"text" => "Conversation compressed."}

    compression_turn = Repo.get!(LlmTurn, compression_turn.id)
    assert compression_turn.provider_metadata["profile"] == "light"

    assert %Message{kind: "summary", covers_range: %{"message_ids" => covered_message_ids}} =
             Message
             |> where([message], message.conversation_id == ^compression_turn.conversation_id)
             |> where([message], message.kind == "summary")
             |> where([message], message.event_id == ^compression_turn.id)
             |> Repo.one()

    assert Enum.any?(compressed_seed_message_ids, &(&1 in covered_message_ids))

    checkback_input =
      adapter.ingress_module.handle_message_receive(
        "mock.message.receive",
        %{
          ingress_event_id: "mock-real-llm-checkback-1",
          signal_channel_id: "mock:chat:real-llm-e2e",
          provider_entry_id: "mock-real-llm-checkback-message-1",
          provider_thread_id: "mock-real-llm-thread",
          text: """
          This is a two-step check_back_later test.
          Step 1: If you have not yet received a check_back_later tool result for this request, call check_back_later exactly once with reason exactly "E2E checkback", check exactly "Confirm ANKOLE_E2E_CHECKBACK_OK", after value 5 and unit "minute", and idempotency_key exactly "ankole-real-e2e-checkback-1".
          Step 2: After the first successful check_back_later tool result is visible, do not call any more tools. Reply exactly ANKOLE_E2E_CHECKBACK_OK.
          """,
          explicit: true,
          now: DateTime.add(@base_time, 6, :second),
          provider_time: DateTime.add(@base_time, 6, :second)
        },
        [consumer]
      )
      |> receive_actor_input!()

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: checkback_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 7, :second),
               lease_seconds: @long_lease_seconds
             )

    assert {:ok, %OutboxEntry{} = checkback_outbox} =
             wait_for_outbox_for_input(
               container,
               checkback_input.id,
               real_deadline(),
               checkback_turn.id
             )

    persisted_checkback_turn = Repo.get!(LlmTurn, checkback_turn.id)
    assert persisted_checkback_turn.status == "succeeded"
    assert tool_result_succeeded?(persisted_checkback_turn.tool_results, "check_back_later")
    assert checkback_outbox.payload["text"] =~ "ANKOLE_E2E_CHECKBACK_OK"

    checkback = checkback_by_idempotency!(agent.uid, "ankole-real-e2e-checkback-1")
    assert checkback.status == "scheduled"
    assert checkback.binding_name == binding.name
    assert checkback.source_actor_input_id == checkback_input.id
    assert checkback.source_llm_turn_id == checkback_turn.id
    assert checkback.signal_channel_id == "mock:chat:real-llm-e2e"
    assert checkback.provider_thread_id == "mock-real-llm-thread"
    assert checkback.provider_entry_id == "mock-real-llm-checkback-message-1"
    assert checkback.wake_payload["reason"] == "E2E checkback"
    assert checkback.wake_payload["check"] == "Confirm ANKOLE_E2E_CHECKBACK_OK"
    assert DateTime.diff(checkback.due_at, checkback.requested_at, :second) in 295..305

    cron_anchor_at =
      DateTime.utc_now()
      |> DateTime.add(10, :minute)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    cron_input =
      adapter.ingress_module.handle_message_receive(
        "mock.message.receive",
        %{
          ingress_event_id: "mock-real-llm-cron-1",
          signal_channel_id: "mock:chat:real-llm-e2e",
          provider_entry_id: "mock-real-llm-cron-message-1",
          provider_thread_id: "mock-real-llm-thread",
          text: """
          This is a two-step cron tool test.
          Step 1: If you have not yet received a cron tool result for this request, call cron exactly once with action "add", name exactly "ankole-real-e2e-cron", schedule kind "every", every_ms 60000, anchor_at exactly "#{cron_anchor_at}", payload object {"task":"ANKOLE_E2E_CRON_OK"}, and idempotency_key exactly "ankole-real-e2e-cron-1".
          Step 2: After the first successful cron tool result is visible, do not call any more tools. Reply exactly ANKOLE_E2E_CRON_OK.
          """,
          explicit: true,
          now: DateTime.add(@base_time, 8, :second),
          provider_time: DateTime.add(@base_time, 8, :second)
        },
        [consumer]
      )
      |> receive_actor_input!()

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: cron_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 9, :second),
               lease_seconds: @long_lease_seconds
             )

    assert {:ok, %OutboxEntry{} = cron_outbox} =
             wait_for_outbox_for_input(container, cron_input.id, real_deadline(), cron_turn.id)

    persisted_cron_turn = Repo.get!(LlmTurn, cron_turn.id)
    assert persisted_cron_turn.status == "succeeded"
    assert tool_result_succeeded?(persisted_cron_turn.tool_results, "cron")
    assert cron_outbox.payload["text"] =~ "ANKOLE_E2E_CRON_OK"

    cron_schedule = cron_schedule_by_idempotency!(agent.uid, "ankole-real-e2e-cron-1")
    assert cron_schedule.status == "active"
    assert cron_schedule.binding_name == binding.name
    assert cron_schedule.name == "ankole-real-e2e-cron"
    assert cron_schedule.schedule["kind"] == "every"
    assert cron_schedule.schedule["every_ms"] == 60_000
    assert cron_schedule.payload == %{"task" => "ANKOLE_E2E_CRON_OK"}
    assert cron_schedule.delivery["signal_channel_id"] == "mock:chat:real-llm-e2e"
    assert cron_schedule.delivery["provider_thread_id"] == "mock-real-llm-thread"

    cron_event = cron_event_for_schedule!(cron_schedule.id)
    assert cron_event.status == "scheduled"
    assert cron_event.signal_channel_id == "mock:chat:real-llm-e2e"
    assert cron_event.provider_thread_id == "mock-real-llm-thread"
    assert cron_event.wake_payload["payload"] == %{"task" => "ANKOLE_E2E_CRON_OK"}

    {:ok, ambient_binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "mock-real-llm-ambient",
        adapter: adapter.id,
        config_ref: "test://mock-provider",
        filters: %{},
        unaddressed_group_message_policy: :may_intervene
      })

    ambient_context =
      AdapterContext.new(
        agent_uid: agent.uid,
        binding_name: ambient_binding.name,
        adapter: adapter.id,
        user_name: "Mock Provider"
      )

    ambient_consumer =
      adapter.ingress_module.chat_consumer(ambient_context, %{"provider" => "mock"})

    ambient_input =
      adapter.ingress_module.handle_message_receive(
        "mock.message.receive",
        %{
          ingress_event_id: "mock-real-llm-ambient-1",
          signal_channel_id: "mock:chat:real-llm-ambient-e2e",
          provider_entry_id: "mock-real-llm-ambient-message-1",
          provider_thread_id: "mock-real-llm-ambient-thread",
          text: """
          Could Real E2E Agent handle this concrete release handoff for the group?
          Please send one visible group reply with exactly ANKOLE_AMBIENT_OK so the release handoff is acknowledged.
          """,
          explicit: false,
          now: DateTime.add(@base_time, 10, :second),
          provider_time: DateTime.add(@base_time, 10, :second)
        },
        [ambient_consumer]
      )
      |> receive_actor_input!()

    assert ambient_input.type == "im.message.may_intervene"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: ambient_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: ambient_input.available_at,
               lease_seconds: @long_lease_seconds
             )

    assert %LlmTurn{
             kind: "generation",
             profile: "primary",
             model: "google/gemini-3.5-flash"
           } = Repo.get!(LlmTurn, ambient_turn.id)

    assert {:ok, %OutboxEntry{} = ambient_outbox} =
             wait_for_outbox_matching_or_turn_terminal(
               container,
               ambient_turn.id,
               real_deadline(),
               fn outbox ->
                 outbox.binding_name == ambient_binding.name &&
                   String.contains?(outbox.payload["text"] || "", "ANKOLE_AMBIENT_OK")
               end
             )

    refute Repo.get(ActorInput, ambient_input.id)

    assert %LlmTurn{kind: "generation", status: "succeeded"} =
             Repo.get!(LlmTurn, ambient_turn.id)

    assert %Message{kind: "introspection", role: "im_ambient"} =
             Message
             |> where(
               [message],
               message.conversation_id == ^ambient_turn.conversation_id
             )
             |> where([message], message.role == "im_ambient")
             |> where([message], message.kind == "introspection")
             |> where([message], message.metadata["control"]["type"] == "ambient_intervention")
             |> Repo.one()

    assert ambient_outbox.payload["text"] =~ "ANKOLE_AMBIENT_OK"
  end

  defp mock_provider_adapter do
    registry =
      start_supervised!(
        {PluginRegistry,
         name: registry_name(), discovery: [roots: [], modules: [MockSignalProviderPlugin]]}
      )

    assert [
             %{
               id: "mock-provider",
               ingress_module: ingress_module,
               outbox_module: outbox_module
             } = declaration
           ] = PluginRegistry.adapter_declarations("signals_gateway.adapter", registry)

    Map.merge(declaration, %{ingress_module: ingress_module, outbox_module: outbox_module})
  end

  defp receive_actor_input!({:ok, [%{status: :accepted, actor_input: %ActorInput{} = input}]}),
    do: input

  defp receive_actor_input!(
         {:ok, [%{inbound_batch: %{id: batch_id, available_at: available_at}}]}
       )
       when is_binary(batch_id) do
    assert %DateTime{} = available_at

    assert {:ok, [%{status: :accepted, inbound_batch: %{id: ^batch_id}, actor_input: input}]} =
             SignalsGateway.finalize_due_inbound_batches(now: available_at, limit: 1)

    assert %ActorInput{} = input
    input
  end

  defp receive_actor_input!(result) do
    flunk("expected inbound message to produce an actor input, got: #{inspect(result)}")
  end

  defp committed_agent_fixture! do
    uid =
      "agent-real-e2e-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    result =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %{skills: 3}} = Library.sync_builtin_skills(force: true)

        assert {:ok, result} =
                 Principals.create_agent(%{
                   uid: uid,
                   display_name: "Real E2E Agent",
                   role: "Research Analyst"
                 })

        result
      end)

    result
  end

  defp unique_worker_auth_key do
    "e2e-" <> Ecto.UUID.generate()
  end

  defp wait_for_worker_projection(worker_id, port, deadline) do
    case Repo.get_by(AgentComputerWorker, worker_id: worker_id) do
      %AgentComputerWorker{} = worker ->
        {:ok, worker}

      nil ->
        receive_port_or_wait(port, deadline, fn ->
          wait_for_worker_projection(worker_id, port, deadline)
        end)
    end
  end

  defp refute_worker_projection_until(worker_id, process, deadline) do
    case Repo.get_by(AgentComputerWorker, worker_id: worker_id) do
      %AgentComputerWorker{} = worker ->
        flunk("worker should not have been admitted: #{inspect(worker)}")

      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          :ok
        else
          port = process_port(process)

          receive do
            {^port, {:exit_status, _status}} ->
              :ok

            {^port, {:data, _data}} ->
              refute_worker_projection_until(worker_id, process, deadline)
          after
            50 ->
              refute_worker_projection_until(worker_id, process, deadline)
          end
        end
    end
  end

  defp wait_for_outbox(process, deadline, llm_turn_id) do
    case outbox_by_turn(llm_turn_id) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        flunk_if_terminal_without_outbox(process, llm_turn_id, "any outbox")

        receive_port_or_wait(process, deadline, fn ->
          wait_for_outbox(process, deadline, llm_turn_id)
        end)
    end
  end

  defp wait_for_outbox_for_input(process, actor_input_id, deadline, llm_turn_id) do
    case outbox_by_input(actor_input_id, llm_turn_id) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        flunk_if_terminal_without_outbox(
          process,
          llm_turn_id,
          "outbox for actor_input_id=#{actor_input_id}",
          fn -> outbox_by_input(actor_input_id, llm_turn_id) end
        )

        receive_port_or_wait(process, deadline, fn ->
          wait_for_outbox_for_input(process, actor_input_id, deadline, llm_turn_id)
        end)
    end
  end

  defp outbox_by_turn(nil), do: Repo.one(OutboxEntry)
  defp outbox_by_turn(llm_turn_id), do: Repo.get_by(OutboxEntry, llm_turn_id: llm_turn_id)

  defp outbox_by_input(actor_input_id, nil) do
    Repo.get_by(OutboxEntry, source_actor_input_id: actor_input_id)
  end

  defp outbox_by_input(actor_input_id, llm_turn_id) do
    Repo.get_by(OutboxEntry, source_actor_input_id: actor_input_id, llm_turn_id: llm_turn_id)
  end

  defp flunk_if_terminal_without_outbox(process, llm_turn_id, expected),
    do:
      flunk_if_terminal_without_outbox(process, llm_turn_id, expected, fn ->
        outbox_by_turn(llm_turn_id)
      end)

  defp flunk_if_terminal_without_outbox(_process, nil, _expected, _outbox_check), do: :ok

  defp flunk_if_terminal_without_outbox(process, llm_turn_id, expected, outbox_check) do
    case Repo.get(LlmTurn, llm_turn_id) do
      %LlmTurn{status: "succeeded", response: response} ->
        if outbox_check.() do
          :ok
        else
          flunk_terminal_without_outbox(process, llm_turn_id, expected, response, "succeeded")
        end

      %LlmTurn{status: "failed", response: response} ->
        flunk_terminal_without_outbox(process, llm_turn_id, expected, response, "failed")

      _turn ->
        :ok
    end
  end

  defp flunk_terminal_without_outbox(process, llm_turn_id, expected, response, status) do
    port = process_port(process)

    flunk(
      "turn #{status} without #{expected}: response=#{inspect(response)} durable_state=#{inspect(durable_commit_state(llm_turn_id))} #{inspect_process(process)} #{received_process_output(port)}"
    )
  end

  defp durable_commit_state(llm_turn_id) do
    %{
      consumptions:
        ActorInputConsumption
        |> where([consumption], consumption.llm_turn_id == ^llm_turn_id)
        |> Repo.all()
        |> Enum.map(&Map.take(&1, [:actor_input_id, :provider_entry_id, :llm_turn_id])),
      outboxes:
        OutboxEntry
        |> where([outbox], outbox.llm_turn_id == ^llm_turn_id)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :outbound_key,
            :source_actor_input_id,
            :source_provider_entry_id,
            :target_provider_entry_id,
            :llm_turn_id,
            :operation,
            :status,
            :payload
          ])
        )
    }
  end

  defp wait_for_outbox_matching_or_turn_terminal(process, llm_turn_id, deadline, predicate)
       when is_function(predicate, 1) do
    case OutboxEntry |> Repo.all() |> Enum.find(predicate) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        case Repo.get(LlmTurn, llm_turn_id) do
          %LlmTurn{status: "succeeded", response: response} ->
            case OutboxEntry |> Repo.all() |> Enum.find(predicate) do
              %OutboxEntry{} = outbox ->
                {:ok, outbox}

              nil ->
                port = process_port(process)

                flunk(
                  "turn succeeded without matching outbox: response=#{inspect(response)} durable_state=#{inspect(durable_commit_state(llm_turn_id))} #{inspect_process(process)} #{received_process_output(port)}"
                )
            end

          %LlmTurn{status: "failed", response: response} ->
            port = process_port(process)

            flunk(
              "turn failed before matching outbox: response=#{inspect(response)} durable_state=#{inspect(durable_commit_state(llm_turn_id))} #{inspect_process(process)} #{received_process_output(port)}"
            )

          _turn ->
            receive_port_or_wait(process, deadline, fn ->
              wait_for_outbox_matching_or_turn_terminal(process, llm_turn_id, deadline, predicate)
            end)
        end
    end
  end

  defp receive_port_or_wait(process, deadline, next) do
    if System.monotonic_time(:millisecond) > deadline do
      port = process_port(process)

      flunk("worker e2e timed out: #{inspect_process(process)} #{received_process_output(port)}")
    end

    port = process_port(process)

    receive do
      {^port, {:exit_status, status}} ->
        flunk(
          "worker exited before e2e completed: #{status} #{inspect_process(process)} #{received_process_output(port)}"
        )

      {^port, {:data, data}} ->
        remember_process_output(port, data)
        next.()
    after
      50 ->
        next.()
    end
  end

  defp process_port(%{port: port}), do: port
  defp process_port(port) when is_port(port), do: port

  defp inspect_process(%{kind: :docker, name: name}), do: "container=#{name}"
  defp inspect_process(port) when is_port(port), do: "port=#{inspect(port)}"

  defp remember_process_output(port, data) when is_port(port) and is_binary(data) do
    key = {:worker_e2e_output, port}

    output =
      [Process.get(key, ""), data] |> IO.iodata_to_binary() |> String.slice(-12_000, 12_000)

    Process.put(key, output)
    :ok
  end

  defp received_process_output(port) when is_port(port) do
    case Process.get({:worker_e2e_output, port}, "") do
      "" -> "output=<empty>"
      output -> "output=#{inspect(output)}"
    end
  end

  defp start_ai_gateway_test_http_server! do
    server =
      start_supervised!(
        {Bandit,
         plug: AnkoleWeb.Endpoint, scheme: :http, ip: {0, 0, 0, 0}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    # The Docker worker cannot use the host process' `Endpoint.url/0` because
    # localhost would resolve inside the container. The broker setting is scoped
    # to this async:false e2e and points the worker at the real Phoenix endpoint
    # exposed on the Docker host.
    put_ai_gateway_broker_env!(
      worker_facing_base_url: "http://host.docker.internal:#{port}/api/v1/ai-gateway"
    )
  end

  defp put_ai_gateway_broker_env!(config) do
    old_env = Application.fetch_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker)
    Application.put_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker, config)

    on_exit(fn ->
      case old_env do
        {:ok, value} ->
          Application.put_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker, value)

        :error ->
          Application.delete_env(:ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker)
      end
    end)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @e2e_timeout_ms
  defp real_deadline, do: System.monotonic_time(:millisecond) + @real_e2e_timeout_ms

  defp registry_name, do: :"mock_signal_provider_registry_#{System.unique_integer([:positive])}"
end
