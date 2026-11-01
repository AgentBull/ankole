defmodule Ankole.PodDocumentWorker do
  @moduledoc """
  Runs document browser stories through a real Docker Agent Computer and its Pod CLI.
  The fixture uses the normal provider, AutomationJob attempt, RuntimeFabric RPC,
  Worker file relay, and authorized document commit.
  """
  use GenServer, restart: :temporary, shutdown: 120_000

  alias Ankole.{AgentWorkers, AutomationJobs, Repo}
  alias Ankole.AgentWorkers.{AgentWorker, Config, Providers}

  def start(port) do
    image = System.fetch_env!("ANKOLE_E2E_WORKER_IMAGE")
    {_, 0} = System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true)
    installation = "doc" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

    {"unix://" <> socket, 0} =
      System.cmd("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])

    {:ok, provider} =
      Providers.create(%{
        provider_id: installation,
        display_name: "Document collaboration browser Worker",
        kind: "docker",
        config:
          Ankole.JSON.encode!(%{
            socket: String.trim(socket),
            network: "bridge",
            endpoints: %{relayOrigin: "http://host.docker.internal:#{port}"}
          }),
        credentials: %{}
      })

    :ok =
      Config.put(
        image: image,
        installation: installation,
        runtime_fabric_endpoint: "ws://host.docker.internal:#{port}/runtime-fabric/worker",
        source_root: Path.expand("../../../agent_computer/src", __DIR__)
      )

    agent =
      Ankole.PrincipalsFixtures.agent_fixture(%{
        display_name: "Document collaboration Agent",
        worker_provider_id: provider.provider_id
      }).principal

    {:ok, stored} = Ankole.Files.store(script())

    {:ok, _} =
      Ankole.Files.commit(agent.uid, [
        Map.merge(stored, %{path: "automation/document-collaboration/main.ts", source: "agent"})
      ])

    {:ok, owner} =
      Supervisor.start_child(Ankole.Supervisor, {__MODULE__, {installation, Repo.tenant_id!()}})

    System.at_exit(fn _ ->
      Supervisor.terminate_child(Ankole.Supervisor, __MODULE__)
    end)

    try do
      :ok = AgentWorkers.request(agent.uid)
      send(owner, :reconcile)
      deadline = System.monotonic_time(:millisecond) + 120_000
      await_worker(agent.uid, deadline)
      agent.uid
    catch
      kind, reason ->
        Supervisor.terminate_child(Ankole.Supervisor, __MODULE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  @impl true
  def init({installation, tenant_id}) do
    Process.flag(:trap_exit, true)
    Repo.put_tenant_id(tenant_id)
    {:ok, installation}
  end

  @impl true
  def handle_info(:reconcile, installation) do
    Oban.drain_queue(queue: :agent_workers, with_scheduled: DateTime.utc_now(:microsecond))
    Process.send_after(self(), :reconcile, 200)
    {:noreply, installation}
  end

  @impl true
  def terminate(_reason, installation), do: cleanup(installation)

  def run(agent_uid, page_id) do
    source = Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid)

    {:ok, job} =
      AutomationJobs.create_job(%{
        agent_uid: agent_uid,
        owner_session_id: source.session_id,
        source_signal_id: source.id,
        drive_prefix: "automation/document-collaboration",
        label: "Document collaboration through ankole-pod",
        reply_route: %{},
        source_provenance: %{}
      })

    {:ok, %{automation_job_run: run}} =
      Repo.transact(fn ->
        AutomationJobs.enqueue_run_in_tx(job.id, agent_uid, %{
          "specversion" => "1.0",
          "id" => Ecto.UUID.generate(),
          "source" => "test://document-browser",
          "type" => "document.collaborate",
          "data" => %{"page" => page_id}
        })
      end)

    :ok =
      Ankole.AutomationJobs.Jobs.ExecuteRun.perform(%Oban.Job{
        args: %{
          "automation_job_run_id" => run.id,
          "tenant_id" => Repo.tenant_id!()
        }
      })

    result = Repo.reload!(run)

    if result.status == :succeeded and result.exit_code == 0 do
      {:ok, Torque.decode!(String.trim(result.stdout))}
    else
      raise "Document Agent run failed: #{inspect(Map.take(result, [:status, :error, :stdout, :stderr]))}"
    end
  end

  defp await_worker(uid, deadline) do
    case Repo.get_by!(AgentWorker, agent_uid: uid) do
      %{state: :ready} ->
        :ok

      worker ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "Document Worker not ready: #{inspect(Map.take(worker, [:state, :last_error]))}"
        end

        Process.sleep(200)
        await_worker(uid, deadline)
    end
  end

  defp cleanup(installation) do
    {containers, 0} =
      System.cmd("docker", ["ps", "-aq", "--filter", "label=ankole.installation=#{installation}"])

    for id <- String.split(containers, "\n", trim: true),
        do: System.cmd("docker", ["rm", "-f", id])

    {volumes, 0} =
      System.cmd("docker", [
        "volume",
        "ls",
        "-q",
        "--filter",
        "label=ankole.installation=#{installation}"
      ])

    for id <- String.split(volumes, "\n", trim: true),
        do: System.cmd("docker", ["volume", "rm", id])
  end

  defp script do
    ~S"""
    const id = context().event.data.page;
    async function cli(operation, params) {
      const child = Bun.spawn(['ankole-pod', operation, JSON.stringify(params)], {stdout: 'pipe', stderr: 'pipe'});
      const [code, out, err] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
      return {code, out, err, result: code === 0 ? JSON.parse(out) : undefined};
    }
    function accepted(result) {
      if (result.code !== 0) throw Error(result.err || result.out);
      return result.result;
    }
    const before = accepted(await cli('pages.read', {id}));
    const first = accepted(await cli('pages.append', {id, base_revision: before.page.revision, markdown: 'Agent outline'}));
    const base = first.page.revision;
    const deadline = Date.now() + 60000;
    let latest;
    do {
      latest = accepted(await cli('pages.read', {id}));
      if (latest.page.revision > base) break;
      if (Date.now() > deadline) throw Error('The human did not edit the shared document');
      await Bun.sleep(150);
    } while (true);
    const stale = await cli('pages.write', {id, base_revision: base, markdown: 'This stale replacement must not commit'});
    if (stale.code === 0 || !/revision_conflict/.test(stale.err + stale.out)) throw Error('Stale Agent write did not reject: ' + JSON.stringify(stale));
    const uncheckedTitle = await cli('pages.update', {id, title: 'Unchecked Agent title'});
    if (uncheckedTitle.code === 0 || !/title_conflict/.test(uncheckedTitle.err + uncheckedTitle.out)) throw Error('Agent rename without a base did not reject: ' + JSON.stringify(uncheckedTitle));
    const staleTitle = await cli('pages.update', {id, title: 'Stale Agent title', expected_title: before.page.title});
    if (staleTitle.code === 0 || !/title_conflict/.test(staleTitle.err + staleTitle.out)) throw Error('Stale Agent rename did not reject: ' + JSON.stringify(staleTitle));
    latest = accepted(await cli('pages.read', {id}));
    if (latest.page.title !== 'Human reviewed title') throw Error('Rejected Agent rename changed the human title: ' + latest.page.title);
    accepted(await cli('pages.update', {id, title: 'Agent reviewed title', expected_title: latest.page.title}));
    const revised = accepted(await cli('pages.write', {id, base_revision: latest.page.revision, markdown: '# ' + latest.content.markdown.replace('Human introduction', 'Human introduction (Agent reviewed)')}));
    const final = accepted(await cli('pages.append', {id, base_revision: revised.page.revision, markdown: 'Agent conclusion'}));
    console.log(JSON.stringify({first_revision: base, human_revision: latest.page.revision, final_revision: final.page.revision, stale_rejected: true, title_conflicts_rejected: true}));
    """
  end
end
