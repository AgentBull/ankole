defmodule Ankole.KubernetesWorkerLifecycleIntegrationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Kubernetes
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob

  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.WorkerProviderHTTPBarrier

  @moduletag timeout: 180_000
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external

  setup do
    path = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG")
    {context, 0} = System.cmd("kubectl", ["--kubeconfig", path, "config", "current-context"])
    assert String.starts_with?(context, "kind-")
    namespace = "wp-recovery-#{System.unique_integer([:positive])}"
    {_output, 0} = System.cmd("kubectl", ["--kubeconfig", path, "create", "namespace", namespace])
    {:ok, previous} = Config.fetch()

    :ok =
      Config.put(
        Keyword.put(
          Map.to_list(previous),
          :image,
          System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
        )
      )

    old_options = Application.get_env(:ankole, :kubereq)
    Application.put_env(:ankole, :kubereq, adapter: WorkerProviderHTTPBarrier)

    {uid, provider} =
      Sandbox.unboxed_run(Repo, fn ->
        claim = %{
          storageClassName: "standard",
          accessModes: ["ReadWriteOnce"],
          resources: %{requests: %{storage: "128Mi"}}
        }

        row =
          worker_provider_fixture(%{
            kind: "kubernetes",
            credentials: %{"kubeconfig" => File.read!(path)},
            config:
              Ankole.JSON.encode!(%{
                namespace: namespace,
                storage: %{claimTemplate: claim},
                cache: %{claimTemplate: claim},
                serviceAccount: "default",
                stopGraceSeconds: 2,
                podTemplate: %{spec: %{containers: [%{name: "worker", imagePullPolicy: "Never"}]}},
                endpoints: %{
                  runtimeFabricUrl: "ws://127.0.0.1:1/runtime-fabric/worker",
                  relayOrigin: "http://127.0.0.1:1",
                  aiGatewayUrl: "http://127.0.0.1:1/api/v1/ai-gateway"
                }
              })
          })

        %{principal: agent} = agent_fixture(%{worker_provider_id: row.provider_id})
        assert :ok = AgentWorkers.request(agent.uid)
        {:ok, provider} = Providers.load(row)
        {agent.uid, provider}
      end)

    on_exit(fn ->
      Application.delete_env(:ankole, :kubereq)

      assert {:ok, true} =
               wait_until(deadline(30_000), fn ->
                 {:ok, objects} = Kubernetes.list_instances(provider, uid)

                 for object <- objects,
                     do: assert(:ok = Kubernetes.delete_instance(provider, object, :now))

                 objects == []
               end)

      assert {:ok, true} =
               wait_until(deadline(30_000), fn ->
                 case Kubernetes.delete_storage(provider, uid, nil) do
                   {:ok, nil} -> true
                   {:error, {:kubernetes_claim_deleting, _}} -> false
                   other -> flunk(inspect(other))
                 end
               end)

      Sandbox.unboxed_run(Repo, fn ->
        delete_agent_fixture_rows(uid, provider.provider_id)
        Repo.delete_all(from j in Oban.Job, where: fragment("?->>'agent_uid' = ?", j.args, ^uid))
      end)

      {_output, 0} =
        System.cmd("kubectl", [
          "--kubeconfig",
          path,
          "delete",
          "namespace",
          namespace,
          "--wait=true",
          "--timeout=60s"
        ])

      :ok = Config.put(Map.to_list(previous))
      if old_options, do: Application.put_env(:ankole, :kubereq, old_options)
    end)

    %{uid: uid, provider: provider, namespace: namespace}
  end

  for state <- ["starting", "deleting"] do
    @state state
    test "#{state} retries G after a crash between Secret and Pod creation", %{
      uid: uid,
      provider: provider,
      namespace: namespace
    } do
      crashed = create_until(uid, "/api/v1/namespaces/#{namespace}/secrets")
      generation = Repo.get!(AgentWorker, uid).generation
      assert Repo.get!(AgentWorker, uid).instance_seen_at == nil

      assert {:ok, [%{generation: ^generation, instance_present?: false}]} =
               Kubernetes.list_instances(provider, uid)

      Task.shutdown(crashed, :brutal_kill)

      if @state == "deleting",
        do: Sandbox.unboxed_run(Repo, fn -> AgentWorkers.mark_deleting_in_tx(Repo, uid) end)

      resumed = create_until(uid, "/api/v1/namespaces/#{namespace}/pods")
      assert Repo.get!(AgentWorker, uid).generation == generation
      assert Repo.get!(AgentWorker, uid).state == @state

      assert {:ok, [%{generation: ^generation, instance_present?: true}]} =
               Kubernetes.list_instances(provider, uid)

      send(resumed.pid, :continue)
      result = Task.await(resumed, 30_000)

      if @state == "deleting" do
        assert_delete_progress(result, uid)

        assert {:ok, true} =
                 wait_until(deadline(30_000), fn ->
                   assert_delete_progress(
                     Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end),
                     uid
                   )

                   Repo.get(AgentWorker, uid) == nil
                 end)

        assert {:ok, []} = Kubernetes.list_instances(provider, uid)
      else
        assert :ok = result

        assert %AgentWorker{generation: ^generation, instance_seen_at: %DateTime{}} =
                 Repo.get!(AgentWorker, uid)
      end
    end
  end

  defp assert_delete_progress(:ok, _uid), do: :ok

  defp assert_delete_progress({:error, {:kubernetes_claim_deleting, name}}, uid) do
    # PVC finalizers finish after the Pod disappears. The row must survive
    # this expected retry, with its generation already settled.
    assert %AgentWorker{state: "deleting", generation: nil, last_error: reason} =
             Repo.get!(AgentWorker, uid)

    assert reason =~ name
  end

  defp create_until(uid, path) do
    parent = self()

    task =
      Task.async(fn ->
        Process.put(:worker_http_barrier, {parent, :after, :post, path})
        Sandbox.unboxed_run(Repo, fn -> reconcile(uid) end)
      end)

    pid = task.pid
    assert_receive {:paused, ^pid}, 30_000
    task
  end

  defp reconcile(uid),
    do:
      ReconcileJob.perform(%Oban.Job{args: Ankole.Job.arguments(:tenant, %{"agent_uid" => uid})})
end
