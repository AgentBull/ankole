defmodule Ankole.KubernetesWorkerUserFlowTest do
  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [deadline: 1, wait_until: 2, wait_for_completed_final_reply: 3]

  alias Ankole.{Principals, WorkerFiles}
  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.E2E.Scenarios.ScheduleAndTool
  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Kubernetes
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob

  alias Ankole.AgentWorkers.Kubernetes.Client
  alias Ankole.Sessions.SessionWorkspace
  alias Ankole.AgentWorkers.AgentWorker

  @moduletag sandbox: false, timeout: 240_000
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external

  setup do
    path = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG")
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    assert String.starts_with?(kubectl!(path, ["config", "current-context"]), "kind-")
    cleanup_committed_fixtures_on_exit!()

    namespace = "wp-user-flow-#{System.unique_integer([:positive])}"
    kubectl!(path, ["create", "namespace", namespace])

    on_exit(fn ->
      kubectl!(path, ["delete", "namespace", namespace, "--wait=true", "--timeout=60s"])
    end)

    {:ok, previous} = Config.fetch()
    :ok = Config.put(previous |> Map.to_list() |> Keyword.put(:image, image))
    on_exit(fn -> Config.put(Map.to_list(previous)) end)

    port = start_ai_gateway_test_http_server!()
    assert {:ok, _} = FakeOpenAIState.start_link(self())
    fake_llm_port = start_fake_llm_server!()
    fake_feishu = start_fake_feishu!()

    %{
      path: path,
      image: image,
      namespace: namespace,
      port: port,
      fake_llm_port: fake_llm_port,
      fake_feishu: fake_feishu
    }
  end

  for layout <- [:exclusive, :shared] do
    @layout layout
    test "#{layout} PVC keeps command output across Pod deletion and the next user message",
         ctx do
      provider = provider!(ctx, @layout)
      if @layout == :shared, do: prepare_shared_home!(ctx, provider)

      kubectl!(ctx.path, [
        "label",
        "namespace",
        ctx.namespace,
        "pod-security.kubernetes.io/enforce=restricted"
      ])

      domain =
        setup_lark_domain!(ctx.fake_llm_port, ctx.fake_feishu, %{
          worker_provider_id: provider.provider_id
        })

      start_lark_connections!(ctx.fake_feishu, connections: 3)
      uid = domain.agent.uid

      assert %AgentWorker{state: "absent", wanted_until: %DateTime{}} =
               Repo.get!(AgentWorker, uid)

      handle = %{kind: :kubernetes, agent_uid: uid}
      flow = Map.merge(domain, %{fake_feishu: ctx.fake_feishu, container: handle})

      # Manual Oban reconciliation follows the Agent's Worker request.
      turn = Task.async(Repo.bind_tenant(fn -> ScheduleAndTool.run_read_file_tool_loop(flow) end))
      first = await_worker!(uid)
      %{input: write_input, reply: reply} = Task.await(turn, 120_000)

      workspace =
        Repo.get_by!(SessionWorkspace, agent_uid: uid, session_id: write_input.session_id)

      home_path = "sessions/#{workspace.id}/chaos/read-file.txt"

      assert_lark_final_reply(
        ctx.fake_feishu,
        reply,
        "CHAOS_READ_FILE_OK",
        :reply,
        "om_read_file_1"
      )

      assert_home_file!(first, home_path)

      assert {:ok, [instance]} = Kubernetes.list_instances(provider, uid)
      assert :ok = Kubernetes.delete_instance(provider, instance, :graceful)
      assert :ok = AgentWorkers.request(uid)
      replacement = await_worker!(uid, first.generation)
      assert replacement.instance_ref != first.instance_ref
      assert {:ok, nil} = Client.get(provider, "Pod", first.instance_ref)
      assert_home_file!(replacement, home_path)

      assert :ok =
               FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
                 event_id: "evt_kind_after_replace",
                 message_id: "om_kind_after_replace",
                 chat_id: "oc_kind_after_replace",
                 chat_type: "p2p",
                 text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
                 mentions: [lark_bot_mention()]
               )

      input = signal_by_provider_message_id!(uid, "om_kind_after_replace")

      assert {:ok, %{status: :driving}} =
               ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

      assert {:ok, response, _message} =
               wait_for_completed_final_reply(handle, input.id, deadline(90_000))

      assert_lark_final_reply(
        ctx.fake_feishu,
        response,
        "CHAOS_DIRECT_OK",
        :reply,
        "om_kind_after_replace"
      )

      assert {:ok, _} = Principals.delete_agent(uid)
      assert {:ok, _} = Principals.delete_agent(uid)

      assert {:ok, true} =
               wait_until(deadline(60_000), fn ->
                 case reconcile(uid) do
                   :ok -> is_nil(Repo.get(AgentWorker, uid))
                   {:error, {:kubernetes_claim_deleting, _}} -> false
                   error -> flunk("Agent deletion failed: #{inspect(error)}")
                 end
               end)

      assert {:ok, []} = Kubernetes.list_instances(provider, uid)
      assert {:ok, []} = Client.list(provider, "Pod")
      assert {:ok, claims} = Client.list(provider, "PersistentVolumeClaim")

      assert Enum.map(claims, & &1["metadata"]["name"]) ==
               if(@layout == :shared, do: ["agent-homes"], else: [])
    end
  end

  defp provider!(ctx, layout) do
    claim = %{
      storageClassName: "standard",
      accessModes: ["ReadWriteOnce"],
      resources: %{requests: %{storage: "128Mi"}}
    }

    storage =
      if layout == :shared, do: %{sharedClaim: "agent-homes"}, else: %{claimTemplate: claim}

    config = %{
      namespace: ctx.namespace,
      storage: storage,
      cache: %{claimTemplate: claim},
      serviceAccount: "default",
      stopGraceSeconds: 3,
      podTemplate: %{spec: %{containers: [%{name: "worker", imagePullPolicy: "Never"}]}},
      endpoints: %{
        runtimeFabricUrl: "ws://host.docker.internal:#{ctx.port}/runtime-fabric/worker",
        relayOrigin: "http://host.docker.internal:#{ctx.port}",
        aiGatewayUrl: "http://host.docker.internal:#{ctx.port}/api/v1/ai-gateway"
      }
    }

    assert {:ok, row} =
             Providers.create(%{
               provider_id: ctx.namespace,
               display_name: "kind user flow",
               kind: "kubernetes",
               config: Ankole.JSON.encode!(config),
               credentials: %{"kubeconfig" => File.read!(ctx.path)}
             })

    assert {:ok, provider} = Providers.load(row)
    provider
  end

  defp prepare_shared_home!(ctx, provider) do
    assert {:ok, _} =
             Client.create(provider, %{
               "apiVersion" => "v1",
               "kind" => "PersistentVolumeClaim",
               "metadata" => %{"name" => "agent-homes", "namespace" => ctx.namespace},
               "spec" => %{
                 "storageClassName" => "example-nfs",
                 "accessModes" => ["ReadWriteMany"],
                 "resources" => %{"requests" => %{"storage" => "128Mi"}}
               }
             })

    # The operator prepares the shared root before restricted Workers mount it.
    assert {:ok, _} =
             Client.create(provider, %{
               "apiVersion" => "v1",
               "kind" => "Pod",
               "metadata" => %{"name" => "storage-permissions", "namespace" => ctx.namespace},
               "spec" => %{
                 "restartPolicy" => "Never",
                 "containers" => [
                   %{
                     "name" => "permissions",
                     "image" => ctx.image,
                     "imagePullPolicy" => "Never",
                     "command" => ["sh", "-ec", "chgrp 1000 /home; chmod 2777 /home"],
                     "securityContext" => %{"runAsUser" => 0},
                     "volumeMounts" => [%{"name" => "home", "mountPath" => "/home"}]
                   }
                 ],
                 "volumes" => [
                   %{"name" => "home", "persistentVolumeClaim" => %{"claimName" => "agent-homes"}}
                 ]
               }
             })

    kubectl!(ctx.path, [
      "-n",
      ctx.namespace,
      "wait",
      "--for=jsonpath={.status.phase}=Succeeded",
      "pod/storage-permissions",
      "--timeout=60s"
    ])

    kubectl!(ctx.path, [
      "-n",
      ctx.namespace,
      "delete",
      "pod/storage-permissions",
      "--grace-period=1",
      "--wait=true"
    ])
  end

  defp await_worker!(uid, previous \\ nil) do
    assert {:ok, worker} =
             wait_until(deadline(120_000), fn ->
               assert :ok = reconcile(uid)

               case Repo.get!(AgentWorker, uid) do
                 %AgentWorker{state: "ready", generation: generation} = worker
                 when generation != previous ->
                   worker

                 _worker ->
                   nil
               end
             end)

    worker
  end

  defp assert_home_file!(worker, path) do
    assert {:ok, %{"body" => body}} = WorkerFiles.stream(path, worker: worker)
    assert Enum.join(body) == "CHAOS_READ_FILE_CONTENT\n"
  end

  defp reconcile(uid) do
    ReconcileJob.perform(%Oban.Job{
      args: %{"agent_uid" => uid, "tenant_id" => Repo.tenant_id!()}
    })
  end

  defp kubectl!(path, args) do
    {output, status} =
      System.cmd("kubectl", ["--kubeconfig", path | args], stderr_to_stdout: true)

    assert status == 0, output
    output
  end
end
