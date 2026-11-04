defmodule Ankole.PodDocumentWorker do
  @moduledoc """
  Runs document browser stories through a real Docker Agent Computer and its Pod CLI.
  The fixture uses the normal provider, admitted Session turn, RuntimeFabric RPC,
  Worker file relay, and authorized document commit.
  """
  use GenServer, restart: :temporary, shutdown: 120_000

  alias Ankole.{AgentWorkers, Repo}
  alias Ankole.Sessions.{Admission, Context, PendingCall, Run, ToolCatalog, Tools, Worker}
  alias Ankole.AgentWorkers.{AgentWorker, Config, Providers}

  def start(port, owner_uid) do
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

    Ankole.ConversationsFixtures.grant_chat(owner_uid, agent.uid)
    {:ok, stored} = Ankole.Files.store(script())

    {:ok, _} =
      Ankole.Files.commit(agent.uid, [
        Map.merge(stored, %{path: "fixtures/document-collaboration.ts", source: "agent"})
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

  def run(agent_uid, page_id, owner_uid) do
    {:ok, page_id} = Ecto.UUID.cast(page_id)
    conversation_id = Ankole.Kernel.gen_uuid_v7()
    key = %{agent_uid: agent_uid, session_id: Ankole.Sessions.Key.conversation(conversation_id)}
    name = Ankole.Sessions.driver_name(key)
    :yes = :global.register_name(name, self())
    {:ok, owner} = Ankole.Principals.get_principal(owner_uid)

    {:ok, _} =
      Ankole.Conversations.create(Ankole.AuthZ.Actor.new(owner), %{
        conversation_id: conversation_id,
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: agent_uid,
        text: "Collaborate with me on the shared document #{page_id}"
      })

    [source] = Ankole.Signals.list_signals!(query: [filter: [conversation_id: conversation_id]])

    # The browser fixture selects the command deterministically. Admission still
    # owns the Signal, Session epoch, work authority, and the real Worker context.
    {:ok, policy} = Ankole.Sessions.AgentConfig.runtime_policy(agent_uid)
    overrides = %{model_ref: %{}, request_context: %{"ai_agent" => policy}}
    {:ok, run} = Admission.admit(key, source, turn_start_overrides: {:ok, overrides})

    try do
      {:ok, context} = Context.resolve(agent_uid, source.session_id, Run.metadata(run))
      run = %{run | context: context}
      {tools, hosted} = ToolCatalog.for_run(run)
      run = %{run | tools: tools, hosted_tools: hosted}
      {:ok, row, envelope} = Worker.prepare_open(run)
      {:ok, _} = Worker.send_open(row, envelope)
      :ready = await_workspace(run)

      args = %{
        "command" =>
          "ankole-files get fixtures/document-collaboration.ts --output document-collaboration.ts && " <>
            "bun document-collaboration.ts " <> page_id,
        "timeout" => 90
      }

      call_id = Ankole.Kernel.gen_uuid_v7()

      call = %{
        "type" => "function_call",
        "name" => "command",
        "call_id" => call_id,
        "arguments" => Torque.encode!(args)
      }

      {:ok, response} =
        Ankole.AIGatewayCase.start_response_run(%{
          subject_uid: agent_uid,
          conversation_id: run.conversation.id,
          round_state: run,
          metadata: %{"request_metadata" => %{"signal_id" => run.signal_id}}
        })

      {:ok, response} = Ankole.AIGateway.ResponseCommit.commit_complete(response, [call], %{})
      run = %{run | model_response: response, round_calls: [call]}
      {:ok, tool, args} = Tools.prepare(run, call)

      {_pending, dispatch} =
        PendingCall.new_round([call], false)
        |> PendingCall.start(call_id, call, tool, args, true)
        |> PendingCall.to_worker(call_id)

      {:ok, _} = Worker.send_call(run, row, dispatch)
      result = await_command(run, call_id)

      if result.is_error or result.details["exitCode"] != 0 do
        raise "Document Agent command failed: #{result.output}"
      end

      output =
        result.output
        |> String.split("\n", trim: true)
        |> Enum.find(&String.starts_with?(&1, ~s({"first_revision")))

      {:ok, decoded} = Torque.decode(output || "")
      {:ok, _} = Run.finalize(%{run | results: %{call_id => result}}, :silent)
      {:ok, decoded}
    rescue
      error ->
        Run.finalize(run, :stopped, "document_worker_failed")
        reraise error, __STACKTRACE__
    after
      Worker.close(run)
      :global.unregister_name(name)
    end
  end

  defp await_workspace(run) do
    receive do
      {:worker, :workspace_ready, payload} ->
        if Worker.matches?(payload.run, run) do
          case Worker.decode(:workspace_ready, payload) do
            :ready -> :ready
            error -> raise "Document Worker workspace failed: #{inspect(error)}"
          end
        else
          await_workspace(run)
        end
    after
      60_000 -> raise "Document Worker workspace timed out"
    end
  end

  defp await_command(run, call_id) do
    receive do
      {:worker, :tool_result, payload} ->
        if Worker.matches?(payload.run, run) and payload.call_id == call_id do
          {:result, ^call_id, result, _images} = Worker.decode(:tool_result, payload)
          result
        else
          await_command(run, call_id)
        end
    after
      100_000 -> raise "Document Worker command timed out"
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
    const id = Bun.argv[2];
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
