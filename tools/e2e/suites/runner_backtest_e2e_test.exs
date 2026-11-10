defmodule Ankole.E2E.RunnerBacktestE2ETest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.E2E.Harness
  import Ankole.E2E.WaitHelpers

  alias Ankole.{AuthZ.Actor, BackgroundAgentJobs, Conversations, Files, JSON, Principals, Repo}
  alias Ankole.AgentWorkers.{Providers, RunnerDevices, WorkerRoute}
  alias Ankole.AIGateway.{ModelProfiles, ProviderConfigs}
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.E2E.{DockerWorker, FakeOpenAIState}
  alias Ankole.Pod.RunnerJobs
  alias Ankole.Signals.Signal

  @moduletag sandbox: false
  @moduletag timeout: 420_000
  @root Path.expand("../../..", __DIR__)

  setup_all do
    start_committed_repo!()
  end

  setup do
    cleanup_committed_fixtures_on_exit!()
    :ok
  end

  test "a paired device reconnects during a Bull Backtesting job and returns the report to the conversation" do
    mono = System.fetch_env!("ANKOLE_E2E_BACKTEST_MONO")
    DockerWorker.assert_docker_image!()
    assert {:ok, _model_state} = FakeOpenAIState.start_link(self())
    configure_endpoint_host!()
    port = start_ai_gateway_test_http_server!()
    DockerWorker.install_provider!(worker_endpoint(port))
    ensure_default_provider!()

    %{principal: owner} = Ankole.PrincipalsFixtures.human_fixture()
    actor = Actor.new(owner)
    assert {:ok, %{agent: agent}} = Principals.ensure_personal_assistant(owner.uid)
    configure_model!(agent.uid, start_fake_llm_server!())
    assert {:ok, %{conversation: %{id: conversation_id}}} = create_conversation(actor, agent.uid)
    signal = conversation_signal!(conversation_id, "conversation.message.addressed")
    drive_signal!(signal)
    assert_signal_finished!(signal.id)

    origin = "http://host.docker.internal:#{port}"

    assert {:ok, %{id: runner_id, code: code}} =
             RunnerDevices.register(actor, "Backtest device", origin)

    device = start_device!("http://127.0.0.1:#{port}", runner_id, code)

    assert {:ok, binding} =
             wait_until(deadline(45_000), fn ->
               case RunnerDevices.connected_worker(agent.uid, runner_id) do
                 {:ok, %{state: :ready} = binding} -> binding
                 _offline -> nil
               end
             end)

    assert binding.agent_uid == agent.uid
    assert [container] = device_containers(device.owner)
    File.write!(Path.join(device.dir, "home-volume"), container_home!(container))

    with_backtest_fixture!(container, mono, device.dir, fn fixture ->
      assert {:ok, %{jobID: job_id}} =
               RunnerJobs.create(actor, %{
                 id: conversation_id,
                 agentUID: agent.uid,
                 runnerID: runner_id,
                 requestID: Ecto.UUID.generate(),
                 title: "Bull Backtesting report",
                 task:
                   "CHAOS_RUNNER_BACKTEST #{fixture} Run the staged report and publish the JSON in Drive."
               })

      dispatch_job!(job_id)

      assert {:ok, true} =
               wait_until(deadline(35_000), fn ->
                 {_, status} =
                   docker([
                     "exec",
                     container,
                     "test",
                     "-f",
                     "/workspace/jobs/#{job_id}/worker-checkpoint"
                   ])

                 status == 0
               end)

      running = Repo.get!(Job, job_id)
      assert running.status == :running
      assert is_binary(running.runtime_thread_id)
      assert running.workspace_owner_job_id == job_id

      assert {:ok, before} = RunnerDevices.connected_worker(agent.uid, runner_id)

      assert :ok =
               WorkerRoute.close_connection(agent.uid, before.transport_route, :e2e_reconnect)

      assert {:ok, rejoined} =
               wait_until(deadline(20_000), fn ->
                 case RunnerDevices.connected_worker(agent.uid, runner_id) do
                   {:ok, %{state: :ready, transport_route: route} = current}
                   when route != before.transport_route ->
                     current

                   _waiting ->
                     nil
                 end
               end)

      assert rejoined.generation == before.generation
      assert rejoined.incarnation_id == before.incarnation_id

      assert {_, 0} =
               docker(["exec", container, "touch", "/workspace/jobs/#{job_id}/worker-resumed"])

      job = wait_job!(job_id)
      assert job.runner_id == runner_id
      assert job.runtime_thread_id == running.runtime_thread_id
      assert job.workspace_owner_job_id == running.workspace_owner_job_id
      assert job.result["output_text"] =~ "CHAOS_RUNNER_BACKTEST_COMPLETE"

      assert {:ok, file} = Files.fetch(agent.uid, "backtest-result.json")

      assert {:ok, _entry, result_json} =
               Ankole.Pod.Files.read(actor, file.node_id, "backtest-result.json")

      report = JSON.decode!(result_json)
      assert Enum.map(report["executions"], & &1["filled_price"]) == ["10.50", "11.00"]
      assert List.last(report["equity_curve"])["equity"] == "100477.40"

      signal = conversation_signal!(conversation_id, "background_agent_job.completed")
      assert signal.data["job_id"] == job_id
      drive_signal!(signal)
      assert_signal_finished!(signal.id)
      assert_conversation_report!(actor, signal, result_json)
    end)

    assert {:ok, _} = RunnerDevices.revoke(actor, runner_id)

    assert {:ok, true} =
             wait_until(deadline(30_000), fn -> device_containers(device.owner) == [] end)
  end

  defp configure_endpoint_host! do
    endpoint = AnkoleWeb.Endpoint
    previous = Application.fetch_env!(:ankole, endpoint)
    url = Keyword.put(endpoint.config(:url), :host, "host.docker.internal")
    current = Keyword.put(previous, :url, url)
    Application.put_env(:ankole, endpoint, current)
    endpoint.config_change([{endpoint, current}], [])

    on_exit(fn ->
      Application.put_env(:ankole, endpoint, previous)
      endpoint.config_change([{endpoint, previous}], [])
    end)
  end

  defp ensure_default_provider! do
    if Providers.default_status() != :ok do
      assert {:ok, _} = Providers.update(DockerWorker.provider_id!(), %{is_default: true})
    end
  end

  defp configure_model!(agent_uid, port) do
    provider_id = "runner-backtest-#{Ecto.UUID.generate()}"

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai_compatible",
               base_url: "http://127.0.0.1:#{port}",
               credential_pool: %{entries: [%{label: "Test", api_key: "test-only"}]}
             })

    for profile <- ["primary", "coding"] do
      assert {:ok, _} =
               ModelProfiles.put_model_profile(agent_uid, profile, %{
                 provider_id: provider_id,
                 model: "gpt-4.1",
                 provider_options: %{}
               })
    end
  end

  defp create_conversation(actor, agent_uid) do
    Conversations.create(actor, %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent_uid,
      text: "CHAOS_RUNNER_OPEN Create a workspace for the backtest."
    })
  end

  defp start_device!(origin, runner_id, code) do
    dir = Path.join(System.tmp_dir!(), "ankole-runner-" <> Ecto.UUID.generate())
    File.mkdir!(dir)
    state = Path.join(dir, "device.json")
    cli = Path.join(@root, "app/agent_computer/src/cli/device/device-cli.ts")
    bun = System.find_executable("bun") || flunk("bun executable is required")

    assert {_output, 0} =
             System.cmd(
               bun,
               [cli, "pair", "--url", origin, "--code", code, "--state", state],
               stderr_to_stdout: true
             )

    port =
      Port.open({:spawn_executable, bun}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [cli, "run", "--state", state]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    owner =
      :crypto.hash(:sha256, JSON.encode!([origin, runner_id]))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    on_exit(fn ->
      System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)

      homes =
        for container <- device_containers(owner, true) do
          home = container_home!(container)
          docker(["rm", "-f", container])
          home
        end

      homes =
        case File.read(Path.join(dir, "home-volume")) do
          {:ok, home} -> [home | homes]
          _ -> homes
        end

      Enum.each(Enum.uniq(homes), &docker(["volume", "rm", &1]))

      File.rm_rf!(dir)
    end)

    %{dir: dir, owner: owner}
  end

  defp device_containers(owner, all? \\ false) do
    {output, 0} =
      docker(
        ["ps"] ++
          if(all?, do: ["-a"], else: []) ++
          ["--filter", "label=ankole.runner-device=#{owner}", "--format", "{{.Names}}"]
      )

    String.split(output, "\n", trim: true)
  end

  defp docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)

  defp container_home!(container) do
    {home, 0} =
      docker([
        "inspect",
        "--format",
        "{{range .Mounts}}{{if eq .Destination \"/workspace\"}}{{.Name}}{{end}}{{end}}",
        container
      ])

    String.trim(home)
  end

  defp with_backtest_fixture!(container, mono, dir, fun) do
    stage = Path.join(dir, "backtest-stage")
    script = Path.join(@root, "tools/e2e/runner-backtest")

    fixture =
      Task.async(fn -> System.cmd(script, [container, mono, stage], stderr_to_stdout: true) end)

    try do
      assert {:ok, name} =
               wait_until(deadline(180_000), fn ->
                 case File.read(stage) do
                   {:ok, name} -> String.trim(name)
                   {:error, :enoent} -> nil
                 end
               end)

      fun.(name)
    after
      File.touch!(stage <> ".release")
      assert {_output, 0} = Task.await(fixture, 30_000)
    end
  end

  defp dispatch_job!(id) do
    assert {:ok, signal} =
             wait_until(deadline(15_000), fn ->
               Repo.one(
                 from s in Signal,
                   where:
                     s.session_id == ^BackgroundAgentJobs.job_session_id(id) and
                       s.type == "background_agent_job.dispatch"
               )
             end)

    drive_signal!(signal)
  end

  defp drive_signal!(signal),
    do: retry_until_sent!(signal, DateTime.add(signal.available_at, 1, :second))

  defp conversation_signal!(conversation_id, type) do
    assert {:ok, signal} =
             wait_until(deadline(15_000), fn ->
               Repo.one(
                 from s in Signal,
                   where: s.conversation_id == ^conversation_id and s.type == ^type
               )
             end)

    signal
  end

  defp assert_conversation_report!(actor, signal, bytes) do
    message =
      Repo.one!(
        from m in Ankole.Conversations.Message,
          where: m.signal_id == ^signal.id and m.author_type == :agent
      )

    assert message.text =~ "CHAOS_RUNNER_BACKTEST_DELIVERED"

    assert {:ok, attachment} =
             Conversations.resolve_attachment(actor, signal.conversation_id, message.id, 0)

    assert attachment["name"] == "backtest-result.json"
    assert {:ok, ^bytes} = Files.read_object(attachment["object_id"])
  end

  defp wait_job!(id) do
    assert {:ok, job} =
             wait_until(deadline(120_000), fn ->
               case Repo.get!(Job, id) do
                 %Job{status: :succeeded} = job ->
                   job

                 %Job{status: status, error: error} when status in [:failed, :stopped] ->
                   flunk("Device Job #{status}: #{inspect(error)}")

                 _pending ->
                   nil
               end
             end)

    job
  end
end
