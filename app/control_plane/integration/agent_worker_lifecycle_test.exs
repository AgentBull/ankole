defmodule Ankole.AgentWorkerLifecycleIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.PrincipalsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{
    Config,
    Docker,
    ProviderKind,
    Providers,
    ReconcileJob,
    SweepJob
  }

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap

  @moduletag timeout: 180_000

  alias Ankole.WorkerProviderHTTPBarrier, as: BarrierHTTP

  setup %{tenant: tenant} do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    {:ok, previous} = Config.fetch()

    :ok =
      Config.put(
        previous
        |> Map.to_list()
        |> Keyword.put(:image, image)
        |> Keyword.put(:runtime_fabric_endpoint, "ws://127.0.0.1:1/runtime-fabric/worker")
      )

    old_options = Application.get_env(:ankole, :docker_api_req_options)
    Application.put_env(:ankole, :docker_api_req_options, adapter: BarrierHTTP)
    %{principal: agent} = Sandbox.unboxed_run(Repo, &agent_fixture/0)

    {:ok, provider} =
      Sandbox.unboxed_run(Repo, fn ->
        worker = Repo.get!(AgentWorker, agent.uid)
        Providers.load(worker.provider_id)
      end)

    assert :ok = Sandbox.unboxed_run(Repo, fn -> AgentWorkers.request(agent.uid) end)

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)
      Application.delete_env(:ankole, :docker_api_req_options)

      assert {:ok, true} =
               wait_until(deadline(30_000), fn ->
                 {:ok, instances} = Docker.list_instances(provider, agent.uid)

                 for object <- instances,
                     do: assert(:ok = Docker.delete_instance(provider, object, :now))

                 instances == []
               end)

      assert {:ok, nil} = Docker.delete_storage(provider, agent.uid, nil)

      Sandbox.unboxed_run(Repo, fn ->
        delete_agent_fixture_rows(agent.uid, provider.provider_id)

        Repo.delete_all(
          from job in Oban.Job, where: fragment("?->>'agent_uid' = ?", job.args, ^agent.uid)
        )

        Repo.delete!(tenant)
      end)

      :ok = Config.put(Map.to_list(previous))
      if old_options, do: Application.put_env(:ankole, :docker_api_req_options, old_options)
    end)

    %{uid: agent.uid, provider: provider}
  end

  test "overlapping coordinators send one committed generation and hold no lock while creating",
       %{uid: uid, provider: provider} do
    first =
      start_unboxed(fn ->
        pause_on(:before, :post, "/v1.42/containers/create")
        reconcile(uid)
      end)

    assert_paused(first)
    intent = Repo.get!(AgentWorker, uid)
    assert intent.state == "starting"
    assert intent.generation != nil
    assert intent.instance_seen_at == nil
    assert {:ok, []} = Docker.list_instances(provider, uid)

    # The first coordinator waits inside the Engine request without a row
    # lock. The second one finishes the same committed generation meanwhile.
    second = start_unboxed(fn -> reconcile(uid) end)
    assert :ok = finish(second)
    assert [%{generation: generation}] = instances(provider, uid)
    assert generation == intent.generation

    # The first create of the same name meets the existing container.
    release(first)
    assert :ok = finish(first)
    assert [%{generation: ^generation}] = instances(provider, uid)
    assert Repo.get!(AgentWorker, uid).generation == generation
  end

  test "a crash after Engine accepted create completes the same container", %{
    uid: uid,
    provider: provider
  } do
    crashed =
      start_unboxed(fn ->
        pause_on(:after, :post, "/v1.42/containers/create")
        reconcile(uid)
      end)

    assert_paused(crashed)
    intent = Repo.get!(AgentWorker, uid)
    assert {:ok, token} = AgentWorkers.credential(intent)
    assert [%{generation: generation, instance_ref: instance_ref}] = instances(provider, uid)
    assert generation == intent.generation
    # The crashed coordinator holds no row lock after the Engine request.
    waiting = start_unboxed(fn -> reconcile(uid) end)
    assert :ok = finish(waiting)
    Task.shutdown(crashed.task, :brutal_kill)
    row = Repo.get!(AgentWorker, uid)
    assert row.generation == generation
    assert row.token_digest == :crypto.hash(:sha256, token)
    assert row.instance_seen_at != nil

    assert [%{generation: ^generation, instance_ref: ^instance_ref, phase: :running}] =
             instances(provider, uid)
  end

  test "a crash before the instance request retries the committed generation", %{
    uid: uid,
    provider: provider
  } do
    crashed =
      start_unboxed(fn ->
        pause_on(:before, :post, "/v1.42/containers/create")
        reconcile(uid)
      end)

    assert_paused(crashed)
    generation = Repo.get!(AgentWorker, uid).generation
    assert {:ok, []} = Docker.list_instances(provider, uid)
    Task.shutdown(crashed.task, :brutal_kill)
    assert :ok = Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
    assert [%{generation: ^generation}] = instances(provider, uid)
    assert Repo.get!(AgentWorker, uid).generation == generation
  end

  test "a discovered instance reference commits before a create retry can deliver a contract", %{
    uid: uid,
    provider: provider
  } do
    crashed =
      start_unboxed(fn ->
        pause_on(:after, :post, "/v1.42/containers/create")
        reconcile(uid)
      end)

    assert_paused(crashed)
    assert Repo.get!(AgentWorker, uid).instance_ref == nil
    [object] = instances(provider, uid)
    Task.shutdown(crashed.task, :brutal_kill)

    retry =
      start_unboxed(fn ->
        pause_on(:before, :post, "/v1.42/containers/create")
        reconcile(uid)
      end)

    assert_paused(retry)
    # This query uses another PostgreSQL connection. An uncommitted row
    # update in the retry transaction would still read as nil here.
    saved = Repo.get!(AgentWorker, uid)
    assert saved.instance_ref == object.instance_ref
    assert saved.generation == object.generation
    assert saved.instance_seen_at != nil
    release(retry)
    assert :ok = finish(retry)
  end

  test "image preparation leaves the row unlocked and rechecks deletion", %{
    uid: uid,
    provider: provider
  } do
    pulling =
      start_unboxed(fn ->
        pause_on(:before, :get, "/v1.42/images/")
        reconcile(uid)
      end)

    assert_paused(pulling)
    deleting = start_unboxed(fn -> AgentWorkers.mark_deleting_in_tx(Repo, uid) end)
    assert :ok = finish(deleting)
    assert Repo.get!(AgentWorker, uid).state == "deleting"
    release(pulling)
    assert :ok = finish(pulling)
    assert Repo.get(AgentWorker, uid) == nil
    assert instances(provider, uid) == []
  end

  test "storage preparation does not block deletion, and deletion removes the volumes", %{
    uid: uid,
    provider: provider
  } do
    preparing =
      start_unboxed(fn ->
        pause_on(:before, :post, "/v1.42/volumes/create")
        reconcile(uid)
      end)

    assert_paused(preparing)
    deleting = start_unboxed(fn -> AgentWorkers.mark_deleting_in_tx(Repo, uid) end)
    assert :ok = finish(deleting)
    release(preparing)
    assert :ok = finish(preparing)

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               assert :ok = Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
               is_nil(Repo.get(AgentWorker, uid))
             end)

    assert instances(provider, uid) == []
    name = ProviderKind.storage_name(provider.runtime.installation, uid)
    refute docker!(["volume", "ls", "--format", "{{.Name}}"]) =~ name
  end

  test "deletion settles an accepted but uncommitted create", %{uid: uid, provider: provider} do
    crashed =
      start_unboxed(fn ->
        pause_on(:after, :post, "/v1.42/containers/create")
        reconcile(uid)
      end)

    assert_paused(crashed)
    generation = Repo.get!(AgentWorker, uid).generation
    Task.shutdown(crashed.task, :brutal_kill)
    Sandbox.unboxed_run(Repo, fn -> AgentWorkers.mark_deleting_in_tx(Repo, uid) end)
    assert Repo.get!(AgentWorker, uid).generation == generation

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               assert :ok = Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
               is_nil(Repo.get(AgentWorker, uid))
             end)

    assert instances(provider, uid) == []
  end

  test "a stale orphan list cannot delete a subsequently created generation", %{
    uid: uid,
    provider: provider
  } do
    assert :ok = Docker.prepare_storage(provider, uid)
    spec = WorkerBootstrap.agent_worker_spec(provider, uid, "old-orphan", "old-token")
    assert {:ok, nil} = Docker.create_instance(provider, spec)

    sweep =
      start_unboxed(fn ->
        pause_on(:after, :get, "/v1.42/containers/json")
        SweepJob.perform(%Oban.Job{args: %{"objects" => true}})
      end)

    assert_paused(sweep)

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               assert :ok = Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
               Repo.get!(AgentWorker, uid).generation != nil
             end)

    generation = Repo.get!(AgentWorker, uid).generation
    release(sweep)
    assert :ok = finish(sweep)
    assert [%{generation: ^generation}] = instances(provider, uid)
    assert_enqueued(worker: ReconcileJob, args: %{agent_uid: uid})
  end

  test "a readiness timeout replaces the observed instance and cache but keeps Home", %{
    uid: uid,
    provider: provider
  } do
    assert :ok = Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
    first = Repo.get!(AgentWorker, uid)
    assert first.instance_seen_at != nil
    name = wait_for_entrypoint!(provider, uid, first.generation)
    write_markers!(name)

    key = "agent_computer.worker.ready_timeout"

    previous =
      Sandbox.unboxed_run(Repo, fn ->
        row = Repo.get_by(Ankole.AppConfigure.AppConfig, scope: "global", key: key)
        assert {:ok, 2} = Ankole.AppConfigure.put_global_by_key(key, 2)
        row
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from c in Ankole.AppConfigure.AppConfig, where: c.scope == "global" and c.key == ^key
        )

        if previous, do: Repo.insert!(Ecto.put_meta(previous, state: :built))
        :ok = Ankole.AppConfigure.Cache.clear_for_test()
      end)
    end)

    # This Worker cannot reach the test endpoint. Use the real timeout and
    # platform state; do not age its row or fabricate a stale connection.
    next = wait_for_replacement!(uid, first.generation)
    next_name = wait_for_entrypoint!(provider, uid, next.generation)

    assert docker!([
             "exec",
             "--user",
             "1000:1000",
             next_name,
             "sh",
             "-ec",
             "test ! -e /var/cache/ankole/lifecycle-marker; cat /workspace/lifecycle-marker"
           ]) == "home"

    assert [%{generation: generation}] = instances(provider, uid)
    assert generation == next.generation
  end

  test "changed CPU and memory settings replace an idle instance and keep its cache", %{
    uid: uid,
    provider: provider
  } do
    assert :ok = Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
    first = Repo.get!(AgentWorker, uid)
    name = wait_for_entrypoint!(provider, uid, first.generation)
    write_markers!(name)

    Sandbox.unboxed_run(Repo, fn ->
      {:ok, stored} = Providers.fetch(provider.provider_id)

      assert {:ok, _provider} =
               Providers.update(stored.provider_id, %{
                 config: stored.config <> "cpus: 1.5\nmemoryMiB: 1024\nstopGraceSeconds: 1\n"
               })
    end)

    next = wait_for_replacement!(uid, first.generation)
    next_name = wait_for_entrypoint!(provider, uid, next.generation)
    [container] = docker!(["inspect", next_name]) |> Ankole.JSON.decode!()
    assert container["HostConfig"]["NanoCpus"] == 1_500_000_000
    assert container["HostConfig"]["Memory"] == 1024 * 1024 * 1024
    assert next.settings_digest != first.settings_digest

    # Only a rebuild or a change of the cache's own settings removes the cache.
    assert docker!([
             "exec",
             "--user",
             "1000:1000",
             next_name,
             "sh",
             "-ec",
             "cat /var/cache/ankole/lifecycle-marker; cat /workspace/lifecycle-marker"
           ]) == "cachehome"

    assert [%{generation: generation}] = instances(provider, uid)
    assert generation == next.generation
  end

  defp wait_for_replacement!(uid, generation) do
    assert {:ok, worker} =
             wait_until(deadline(30_000), fn ->
               assert :ok = Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
               worker = Repo.get!(AgentWorker, uid)
               if worker.generation && worker.generation != generation, do: worker
             end)

    worker
  end

  defp wait_for_entrypoint!(provider, uid, generation) do
    name = ProviderKind.instance_name(provider.runtime.installation, uid, generation)

    assert {:ok, true} =
             wait_until(deadline(20_000), fn ->
               {_output, status} =
                 System.cmd(
                   "docker",
                   ["exec", "--user", "1000:1000", name, "test", "-L", "/agents/#{uid}"],
                   stderr_to_stdout: true
                 )

               status == 0
             end)

    name
  end

  defp write_markers!(name) do
    docker!([
      "exec",
      "--user",
      "1000:1000",
      name,
      "sh",
      "-ec",
      "printf home > /workspace/lifecycle-marker; printf cache > /var/cache/ankole/lifecycle-marker"
    ])
  end

  defp docker!(args) do
    {output, status} = System.cmd("docker", args, stderr_to_stdout: true)
    assert status == 0, "docker #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end

  defp reconcile(uid),
    do:
      ReconcileJob.perform(%Oban.Job{args: Ankole.Job.arguments(:tenant, %{"agent_uid" => uid})})

  defp instances(provider, uid) do
    assert {:ok, objects} = Docker.list_instances(provider, uid)
    objects
  end

  defp pause_on(stage, method, prefix),
    do: Process.put(:worker_http_barrier, {Process.get(:test_parent), stage, method, prefix})

  defp start_unboxed(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.put_tenant_id(tenant_id)

        Process.put(:test_parent, parent)

        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:database_task, self(), backend_pid})
          fun.()
        end)
      end)

    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp assert_paused(operation) do
    pid = operation.task.pid
    assert_receive {:paused, ^pid}, 15_000
  end

  defp release(operation), do: send(operation.task.pid, :continue)
  defp finish(operation), do: Task.await(operation.task, 30_000)
end
