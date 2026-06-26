defmodule Ankole.ActorRuntimeWorkerE2ETest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import ExUnit.Assertions

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.LlmProviders
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.WorkerAuthKeys
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Registry, as: PluginRegistry
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.OutboxEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @e2e_timeout_ms 12_000
  @real_e2e_timeout_ms 600_000
  @long_lease_seconds 604_800
  @docker_image "ankole-agent-computer:0.1.0"

  @tag timeout: 30_000
  test "external Bun worker connects to RuntimeFabric and is admitted" do
    pre_auth_token = "mock-provider-e2e-token-#{System.unique_integer([:positive])}"
    worker_id = "mock-worker-#{System.unique_integer([:positive])}"
    worker_instance_id = "#{worker_id}-instance"

    {:ok, endpoint} =
      Broker.start_router("tcp://127.0.0.1:*",
        pre_auth_token: pre_auth_token,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    port =
      start_external_worker!(
        endpoint: endpoint,
        pre_auth_token: pre_auth_token,
        worker_id: worker_id,
        worker_instance_id: worker_instance_id
      )

    on_exit(fn -> close_port(port) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, port, deadline())
  end

  @tag timeout: 45_000
  test "Docker image worker connects to RuntimeFabric and is admitted" do
    assert_docker_image!()

    worker_id = "docker-worker-#{System.unique_integer([:positive])}"
    worker_instance_id = "#{worker_id}-instance"

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth: :database,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_instance_id: worker_instance_id
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline())
  end

  @tag timeout: 30_000
  test "Docker image worker with disabled worker auth key is not admitted" do
    assert_docker_image!()

    worker_id = "docker-rejected-worker-#{System.unique_integer([:positive])}"
    assert {:ok, _auth_key} = WorkerAuthKeys.bootstrap_key(worker_id)
    assert {:ok, _auth_key} = WorkerAuthKeys.disable(worker_id)

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth: :database,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_instance_id: "#{worker_id}-instance"
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
               {"ANKOLE_AGENT_COMPUTER_WORKER_ID", "worker-missing-env"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID", "worker-missing-env-1"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN", "unused-test-secret"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "ANKOLE_RUNTIME_FABRIC_ENDPOINT is required"
  end

  test "Docker image worker rejects actor-specific startup env" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"ANKOLE_RUNTIME_FABRIC_ENDPOINT", "tcp://host.docker.internal:1"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_ID", "worker-actor-env"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID", "worker-actor-env-1"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN", "unused-test-secret"},
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
        flunk("OPENROUTER_API_KEY is required for real provider e2e")

    %{principal: agent} = committed_agent_fixture!()
    adapter = mock_provider_adapter()

    assert {:ok, _provider} =
             LlmProviders.create_provider(%{
               provider_id: "openrouter-e2e",
               provider_source: "openrouter",
               credential: openrouter_api_key,
               connection_options: %{"base_url" => "https://openrouter.ai/api/v1"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-e2e",
               model: "google/gemini-3.5-flash"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: "openrouter-e2e",
               model: "openai/gpt-5.4-nano"
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
    worker_instance_id = "#{worker_id}-instance"

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        worker_auth: :database,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        worker_id: worker_id,
        worker_instance_id: worker_instance_id
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

    assert {:ok, [%{status: :accepted, actor_input: input}]} =
             adapter.ingress_module.handle_message_receive(
               "mock.message.receive",
               %{
                 ingress_event_id: "mock-real-llm-event-1",
                 signal_channel_id: "mock:chat:real-llm-e2e",
                 provider_entry_id: "mock-real-llm-message-1",
                 provider_thread_id: "mock-real-llm-thread",
                 text: """
                 You must call the skill_append tool before replying.
                 Use skill_append with name exactly "nano-pdf" and content exactly "E2E overlay: ANKOLE_E2E_OK".
                 After the tool result confirms the change, reply exactly ANKOLE_E2E_OK.
                 """,
                 explicit: true,
                 now: @base_time,
                 provider_time: @base_time
               },
               [consumer]
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert {:ok, %OutboxEntry{} = outbox} = wait_for_outbox(container, real_deadline())

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

    assert {:ok, [%{actor_input: rm_input}]} =
             adapter.ingress_module.handle_message_receive(
               "mock.message.receive",
               %{
                 ingress_event_id: "mock-real-llm-rm-overlay-file-1",
                 signal_channel_id: "mock:chat:real-llm-e2e",
                 provider_entry_id: "mock-real-llm-rm-overlay-file-message-1",
                 provider_thread_id: "mock-real-llm-thread",
                 text: """
                 You must call the command tool before replying.
                 Run exactly: rm -f /workspace/library-containers/skills/nano-pdf/AGENT_APPEND.md
                 After the command succeeds, reply exactly ANKOLE_E2E_RM_OK.
                 """,
                 explicit: true,
                 now: DateTime.add(@base_time, 2, :second),
                 provider_time: DateTime.add(@base_time, 2, :second)
               },
               [consumer]
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 3, :second),
               lease_seconds: @long_lease_seconds
             )

    assert {:ok, %OutboxEntry{} = rm_outbox} =
             wait_for_outbox_for_input(container, rm_input.id, real_deadline())

    assert rm_outbox.payload["text"] =~ "ANKOLE_E2E_RM_OK"

    active_overlay =
      AgentSkillOverlay
      |> where([overlay], overlay.agent_uid == ^agent.uid)
      |> where([overlay], overlay.skill_name == "nano-pdf")
      |> where([overlay], is_nil(overlay.deleted_at))
      |> Repo.one()

    assert %AgentSkillOverlay{overlay_json: %{"text" => "E2E overlay: ANKOLE_E2E_OK"}} =
             active_overlay

    assert {:ok, [%{actor_input: compress_input}]} =
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

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: compression_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 5, :second),
               lease_seconds: @long_lease_seconds
             )

    assert %LlmTurn{
             kind: "compression",
             profile: "light",
             model: "openai/gpt-5.4-nano"
           } = Repo.get!(LlmTurn, compression_turn.id)

    assert {:ok, %OutboxEntry{} = compress_outbox} =
             wait_for_outbox_for_input(container, compress_input.id, real_deadline())

    assert compress_outbox.payload == %{"text" => "Conversation compressed."}

    assert %Message{kind: "summary"} =
             Message
             |> where([message], message.conversation_id == ^compression_turn.conversation_id)
             |> where([message], message.kind == "summary")
             |> where([message], message.event_id == ^compress_input.ingress_event_id)
             |> Repo.one()

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

    assert {:ok, [%{actor_input: ambient_input}]} =
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
                 now: DateTime.add(@base_time, 6, :second),
                 provider_time: DateTime.add(@base_time, 6, :second)
               },
               [ambient_consumer]
             )

    assert ambient_input.type == "im.message.may_intervene"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: ambient_turn}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 8, :second),
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

  defp start_external_worker!(opts) do
    assert_file!(Path.join(kernel_dir(), "ankole-kernel.node"))

    workspace_root =
      Path.join(System.tmp_dir!(), "ankole-worker-e2e-#{System.unique_integer([:positive])}")

    shared_root = Path.join(workspace_root, "shared")
    user_files_root = Path.join(shared_root, "user-files")
    installed_skills_root = Path.join(shared_root, "skills/agents")
    sessions_root = Path.join(workspace_root, ".sessions")

    File.mkdir_p!(user_files_root)
    File.mkdir_p!(installed_skills_root)
    File.mkdir_p!(sessions_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    env = [
      {~c"ANKOLE_RUNTIME_FABRIC_ENDPOINT",
       Keyword.fetch!(opts, :endpoint) |> String.to_charlist()},
      {~c"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN",
       Keyword.fetch!(opts, :pre_auth_token) |> String.to_charlist()},
      {~c"ANKOLE_AGENT_COMPUTER_WORKER_ID",
       Keyword.fetch!(opts, :worker_id) |> String.to_charlist()},
      {~c"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID",
       Keyword.fetch!(opts, :worker_instance_id) |> String.to_charlist()},
      {~c"ANKOLE_WORKSPACE_ROOT", workspace_root |> String.to_charlist()},
      {~c"ANKOLE_WORKSPACE_SESSIONS_ROOT", sessions_root |> String.to_charlist()},
      {~c"ANKOLE_SHARED_FS_ROOT", shared_root |> String.to_charlist()},
      {~c"ANKOLE_USER_FILES_ROOT", user_files_root |> String.to_charlist()},
      {~c"ANKOLE_AGENT_INSTALLED_SKILLS_ROOT", installed_skills_root |> String.to_charlist()},
      {~c"ANKOLE_BUILTIN_SKILLS_ROOT",
       Path.join([repo_root(), "app", "library", "skills"]) |> String.to_charlist()}
    ]

    Port.open({:spawn_executable, bun_path()}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, ["src/main.ts"]},
      {:cd, worker_dir()},
      {:env, env}
    ])
  end

  defp start_docker_worker!(opts) do
    name = "ankole-worker-e2e-#{System.unique_integer([:positive])}"
    worker_id = Keyword.fetch!(opts, :worker_id)
    pre_auth_key = worker_pre_auth_key!(worker_id)

    args =
      [
        "run",
        "--rm",
        "--name",
        name,
        "--add-host",
        "host.docker.internal=host-gateway"
      ] ++
        docker_dev_agent_computer_mount_args() ++
        docker_dev_workspace_mount_args() ++
        docker_env_args([
          {"ANKOLE_RUNTIME_FABRIC_ENDPOINT", Keyword.fetch!(opts, :endpoint)},
          {"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN", pre_auth_key},
          {"ANKOLE_AGENT_COMPUTER_WORKER_ID", worker_id},
          {"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID", Keyword.fetch!(opts, :worker_instance_id)},
          {"ANKOLE_SHARED_FS_ROOT", "/workspace/shared"},
          {"ANKOLE_USER_FILES_ROOT", "/workspace/shared/user-files"},
          {"ANKOLE_AGENT_INSTALLED_SKILLS_ROOT", "/workspace/shared/skills/agents"},
          {"ANKOLE_BUILTIN_SKILLS_ROOT", "/repo/app/library/skills"}
        ]) ++ [@docker_image]

    port =
      Port.open({:spawn_executable, docker_path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    %{kind: :docker, name: name, port: port, output: []}
  end

  defp worker_pre_auth_key!(worker_id) do
    case Repo.get(Ankole.ActorRuntime.Schemas.AgentComputerWorkerAuthKey, worker_id) do
      %{pre_auth_key: pre_auth_key} ->
        pre_auth_key

      nil ->
        {:ok, auth_key} = WorkerAuthKeys.bootstrap_key(worker_id)
        auth_key.pre_auth_key
    end
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

  defp wait_for_outbox(port, deadline) do
    case Repo.one(OutboxEntry) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        receive_port_or_wait(port, deadline, fn -> wait_for_outbox(port, deadline) end)
    end
  end

  defp wait_for_outbox_for_input(process, actor_input_id, deadline) do
    case Repo.get_by(OutboxEntry, source_actor_input_id: actor_input_id) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_outbox_for_input(process, actor_input_id, deadline)
        end)
    end
  end

  defp wait_for_outbox_matching_or_turn_terminal(process, llm_turn_id, deadline, predicate)
       when is_function(predicate, 1) do
    case OutboxEntry |> Repo.all() |> Enum.find(predicate) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        case Repo.get(LlmTurn, llm_turn_id) do
          %LlmTurn{status: "succeeded", response: response} ->
            port = process_port(process)

            flunk(
              "turn succeeded without matching outbox: response=#{inspect(response)} #{inspect_process(process)} #{received_process_output(port)}"
            )

          %LlmTurn{status: "failed", response: response} ->
            port = process_port(process)

            flunk(
              "turn failed before matching outbox: response=#{inspect(response)} #{inspect_process(process)} #{received_process_output(port)}"
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

      flunk(
        "external worker e2e timed out: #{inspect_process(process)} #{received_process_output(port)}"
      )
    end

    port = process_port(process)

    receive do
      {^port, {:exit_status, status}} ->
        flunk(
          "external worker exited before e2e completed: #{status} #{inspect_process(process)} #{received_process_output(port)}"
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

  defp close_port(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  end

  defp close_port(_port), do: :ok

  defp cleanup_docker_worker(%{name: name, port: port}) do
    System.cmd(docker_path(), ["rm", "-f", name], stderr_to_stdout: true)
    close_port(port)
  end

  defp docker_run_worker_once(env) do
    args =
      [
        "run",
        "--rm",
        "--add-host",
        "host.docker.internal=host-gateway"
      ] ++
        docker_dev_agent_computer_mount_args() ++
        docker_dev_workspace_mount_args() ++
        docker_env_args(env) ++ [@docker_image]

    System.cmd(docker_path(), args, stderr_to_stdout: true)
  end

  defp docker_env_args(env) do
    Enum.flat_map(env, fn {key, value} -> ["-e", "#{key}=#{value}"] end)
  end

  # Development-only fast path for the real worker e2e: the image still supplies
  # OS packages, native binaries, and node_modules, but TS source changes can be
  # exercised without rebuilding the image. Native/Rust or dependency changes
  # still require rebuilding because those artifacts remain image-owned.
  defp docker_dev_agent_computer_mount_args do
    case System.get_env("ANKOLE_E2E_MOUNT_AGENT_COMPUTER_SRC") do
      "1" ->
        src = Path.join([repo_root(), "app", "agent_computer", "src"])
        ["-v", "#{src}:/repo/app/agent_computer/src:ro"]

      _value ->
        []
    end
  end

  # Optional test-only observability hook. Keeping /workspace on the host makes
  # failed real-provider runs inspectable without changing the worker protocol
  # or adding debugging fields to final proposals.
  defp docker_dev_workspace_mount_args do
    case System.get_env("ANKOLE_E2E_HOST_WORKSPACE_ROOT") do
      nil ->
        []

      "" ->
        []

      host_root ->
        File.mkdir_p!(host_root)
        File.mkdir_p!(Path.join(host_root, "shared/user-files"))
        File.mkdir_p!(Path.join(host_root, "shared/skills/agents"))
        File.mkdir_p!(Path.join(host_root, ".sessions"))
        ["-v", "#{Path.expand(host_root)}:/workspace"]
    end
  end

  defp docker_host_endpoint(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "tcp", port: port} when is_integer(port) ->
        "tcp://host.docker.internal:#{port}"

      _uri ->
        flunk("unexpected router endpoint for Docker worker: #{endpoint}")
    end
  end

  defp assert_docker_image! do
    case System.cmd(docker_path(), ["image", "inspect", @docker_image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("missing Docker image #{@docker_image}, status=#{status}, output=#{output}")
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @e2e_timeout_ms
  defp real_deadline, do: System.monotonic_time(:millisecond) + @real_e2e_timeout_ms

  defp assert_file!(path) do
    case File.exists?(path) do
      true ->
        :ok

      false ->
        flunk("missing #{path}; run `bun run build:bun` in app/kernel before this e2e test")
    end
  end

  defp repo_root, do: Path.expand("../../..", __DIR__)

  defp bun_path do
    System.find_executable("bun") || flunk("bun executable was not found on PATH")
  end

  defp docker_path do
    System.find_executable("docker") || flunk("docker executable was not found on PATH")
  end

  defp worker_dir, do: Path.expand("../../agent_computer", __DIR__)
  defp kernel_dir, do: Path.expand("../../kernel", __DIR__)
  defp registry_name, do: :"mock_signal_provider_registry_#{System.unique_integer([:positive])}"
end
