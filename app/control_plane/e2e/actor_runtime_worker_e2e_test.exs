defmodule Ankole.ActorRuntimeWorkerE2ETest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import ExUnit.Assertions

  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockOutbox
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Registry, as: PluginRegistry
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.OutboxEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @e2e_timeout_ms 12_000
  @docker_image "ankole-agent-computer-worker:ping-pong"

  @tag timeout: 30_000
  test "mock provider plugin drives PING through external Bun worker to provider-visible PONG" do
    %{principal: agent} = agent_fixture()
    adapter = mock_provider_adapter()

    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "mock-main",
        adapter: adapter.id,
        config_ref: "test://mock-provider",
        filters: %{},
        unaddressed_group_message_policy: :ignore
      })

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
                 ingress_event_id: "mock-event-ping-1",
                 signal_channel_id: "mock:chat:e2e",
                 provider_entry_id: "mock-message-ping-1",
                 provider_thread_id: "mock-thread-e2e",
                 text: "PING",
                 explicit: true,
                 now: @base_time,
                 provider_time: @base_time
               },
               [consumer]
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: 86_400
             )

    assert {:ok, %OutboxEntry{} = outbox} = wait_for_outbox(port, deadline())

    refute Repo.get(ActorInput, input.id)
    assert Repo.get!(LlmTurn, outbox.llm_turn_id).status == "succeeded"
    assert outbox.payload == %{"text" => "PONG"}

    MockOutbox.put_recipient(self())

    assert {:ok, sent_outbox} =
             SignalsGateway.dispatch_outbox(
               agent.uid,
               binding.name,
               outbox.outbound_key,
               adapter.outbox_module
             )

    assert_receive {:mock_provider_outbox_sent, delivered_outbox}
    assert delivered_outbox.payload == %{"text" => "PONG"}
    assert delivered_outbox.source_provider_entry_id == "mock-message-ping-1"
    assert sent_outbox.status == :succeeded
    assert sent_outbox.provider_entry_id =~ "mock-reply-"
  end

  @tag timeout: 45_000
  test "Docker image worker drives PING through mock provider to provider-visible PONG" do
    assert_docker_image!()

    %{principal: agent} = agent_fixture()
    adapter = mock_provider_adapter()

    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent.uid,
        name: "mock-docker",
        adapter: adapter.id,
        config_ref: "test://mock-provider",
        filters: %{},
        unaddressed_group_message_policy: :ignore
      })

    pre_auth_token = "docker-e2e-token-#{System.unique_integer([:positive])}"
    worker_id = "docker-worker-#{System.unique_integer([:positive])}"
    worker_instance_id = "#{worker_id}-instance"

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        pre_auth_token: pre_auth_token,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        pre_auth_token: pre_auth_token,
        worker_id: worker_id,
        worker_instance_id: worker_instance_id
      )

    on_exit(fn -> cleanup_docker_worker(container) end)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline())

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
                 ingress_event_id: "mock-docker-event-ping-1",
                 signal_channel_id: "mock:chat:docker-e2e",
                 provider_entry_id: "mock-docker-message-ping-1",
                 provider_thread_id: "mock-docker-thread-e2e",
                 text: "PING",
                 explicit: true,
                 now: @base_time,
                 provider_time: @base_time
               },
               [consumer]
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             ActorRuntime.process_ready_inputs_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: 86_400
             )

    assert {:ok, %OutboxEntry{} = outbox} = wait_for_outbox(container, deadline())

    refute Repo.get(ActorInput, input.id)
    assert Repo.get!(LlmTurn, outbox.llm_turn_id).status == "succeeded"
    assert outbox.payload == %{"text" => "PONG"}

    MockOutbox.put_recipient(self())

    assert {:ok, sent_outbox} =
             SignalsGateway.dispatch_outbox(
               agent.uid,
               binding.name,
               outbox.outbound_key,
               adapter.outbox_module
             )

    assert_receive {:mock_provider_outbox_sent, delivered_outbox}
    assert delivered_outbox.payload == %{"text" => "PONG"}
    assert delivered_outbox.source_provider_entry_id == "mock-docker-message-ping-1"
    assert sent_outbox.status == :succeeded
  end

  @tag timeout: 30_000
  test "Docker image worker with wrong pre-auth token is not admitted" do
    assert_docker_image!()

    pre_auth_token = "docker-auth-token-#{System.unique_integer([:positive])}"
    worker_id = "docker-rejected-worker-#{System.unique_integer([:positive])}"

    {:ok, endpoint} =
      Broker.start_router("tcp://0.0.0.0:*",
        pre_auth_token: pre_auth_token,
        poll_interval_ms: 1
      )

    on_exit(fn -> Broker.stop_router() end)

    container =
      start_docker_worker!(
        endpoint: docker_host_endpoint(endpoint),
        pre_auth_token: "wrong-#{pre_auth_token}",
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
               {"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN", "secret"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_ID", "worker-missing-env"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID", "worker-missing-env-1"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "ANKOLE_ACTOR_BUS_ENDPOINT is required"
  end

  test "Docker image worker rejects actor-specific startup env" do
    assert_docker_image!()

    assert {output, status} =
             docker_run_worker_once([
               {"ANKOLE_ACTOR_BUS_ENDPOINT", "tcp://host.docker.internal:1"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN", "secret"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_ID", "worker-actor-env"},
               {"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID", "worker-actor-env-1"},
               {"ANKOLE_AGENT_UID", "agent-1"}
             ])

    assert status != 0
    assert output =~ ~s("event":"worker.error")
    assert output =~ "ANKOLE_AGENT_UID must not be set on an agent computer worker"
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

  defp start_external_worker!(opts) do
    assert_file!(Path.join(kernel_dir(), "ankole-kernel.node"))

    env = [
      {~c"ANKOLE_ACTOR_BUS_ENDPOINT", Keyword.fetch!(opts, :endpoint) |> String.to_charlist()},
      {~c"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN",
       Keyword.fetch!(opts, :pre_auth_token) |> String.to_charlist()},
      {~c"ANKOLE_AGENT_COMPUTER_WORKER_ID",
       Keyword.fetch!(opts, :worker_id) |> String.to_charlist()},
      {~c"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID",
       Keyword.fetch!(opts, :worker_instance_id) |> String.to_charlist()}
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

    args =
      [
        "run",
        "--rm",
        "--name",
        name,
        "--add-host",
        "host.docker.internal=host-gateway"
      ] ++
        docker_env_args([
          {"ANKOLE_ACTOR_BUS_ENDPOINT", Keyword.fetch!(opts, :endpoint)},
          {"ANKOLE_AGENT_COMPUTER_WORKER_PRE_AUTH_TOKEN", Keyword.fetch!(opts, :pre_auth_token)},
          {"ANKOLE_AGENT_COMPUTER_WORKER_ID", Keyword.fetch!(opts, :worker_id)},
          {"ANKOLE_AGENT_COMPUTER_WORKER_INSTANCE_ID", Keyword.fetch!(opts, :worker_instance_id)}
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

  defp receive_port_or_wait(process, deadline, next) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("external worker e2e timed out")
    end

    port = process_port(process)

    receive do
      {^port, {:exit_status, status}} ->
        flunk(
          "external worker exited before e2e completed: #{status} #{inspect_process(process)}"
        )

      {^port, {:data, _data}} ->
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
      ] ++ docker_env_args(env) ++ [@docker_image]

    System.cmd(docker_path(), args, stderr_to_stdout: true)
  end

  defp docker_env_args(env) do
    Enum.flat_map(env, fn {key, value} -> ["-e", "#{key}=#{value}"] end)
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

  defp assert_file!(path) do
    case File.exists?(path) do
      true ->
        :ok

      false ->
        flunk("missing #{path}; run `bun run build:bun` in app/kernel before this e2e test")
    end
  end

  defp bun_path do
    System.find_executable("bun") || flunk("bun executable was not found on PATH")
  end

  defp docker_path do
    System.find_executable("docker") || flunk("docker executable was not found on PATH")
  end

  defp worker_dir, do: Path.expand("../../agent_computer_worker", __DIR__)
  defp kernel_dir, do: Path.expand("../../kernel", __DIR__)
  defp registry_name, do: :"mock_signal_provider_registry_#{System.unique_integer([:positive])}"
end
