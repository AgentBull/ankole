defmodule Ankole.KubernetesWorkerStorageIntegrationTest do
  use Ankole.DataCase, async: false
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  alias Ankole.AgentWorkers.Kubernetes
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Kubernetes.Client

  alias Ankole.AgentWorkers.Providers.Configuration
  alias Ankole.AgentWorkers.Providers.Credentials
  alias Ankole.AgentWorkers.Providers.Provider

  alias Ankole.AgentWorkers.WorkerBootstrap

  @moduletag timeout: 240_000
  # Needs Docker, Kubernetes, or cloud tooling; see CONTRIBUTING.md.
  @moduletag :external

  setup do
    kubeconfig_path = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_KUBECONFIG")
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    kubeconfig = File.read!(kubeconfig_path)
    # This suite creates storage. It must never use the operator's cloud context.
    context = kubectl!(kubeconfig_path, ["config", "current-context"]) |> String.trim()
    assert String.starts_with?(context, "kind-")
    namespace = "wp-storage-#{System.unique_integer([:positive])}"
    kubectl!(kubeconfig_path, ["create", "namespace", namespace])

    on_exit(fn ->
      kubectl!(kubeconfig_path, ["delete", "namespace", namespace, "--wait=true", "--timeout=60s"])
    end)

    %{
      kubeconfig_path: kubeconfig_path,
      kubeconfig: kubeconfig,
      image: image,
      namespace: namespace
    }
  end

  for layout <- [:exclusive, :shared] do
    @layout layout
    test "#{layout} Home survives Pod deletion, cache replacement, and another Agent's storage deletion",
         ctx do
      provider = provider(ctx, @layout)
      if @layout == :shared, do: prepare_shared_volume(provider, ctx)

      kubectl!(ctx.kubeconfig_path, [
        "label",
        "namespace",
        ctx.namespace,
        "pod-security.kubernetes.io/enforce=restricted"
      ])

      assert :ok = Kubernetes.check(provider)
      uid = "agent-main"
      peer = "agent-peer"
      assert :ok = Kubernetes.prepare_storage(provider, uid)
      assert :ok = Kubernetes.prepare_storage(provider, peer)
      first = start_instance(provider, ctx, uid, "first")
      peer_name = start_instance(provider, ctx, peer, "peer")

      assert exec(
               ctx,
               first,
               "test \"$(id -u)\" = 1000; ! command -v sudo; printf persistent > /workspace/keep; printf cache > /var/cache/ankole/keep; printf legacy > /agents/$WORKER_ID/old-path"
             ) == ""

      assert exec(ctx, peer_name, "test ! -e /workspace/keep; printf peer > /workspace/keep") ==
               ""

      assert {:ok, []} =
               Kubernetes.list_instances(%{provider | provider_id: "another-provider"}, :all)

      home_claim =
        if @layout == :shared, do: "agent-homes", else: ProviderKind.storage_name("storage", uid)

      {:ok, claim} = Client.get(provider, "PersistentVolumeClaim", home_claim)
      refute Map.has_key?(claim["metadata"], "ownerReferences")

      remove_instances(provider, uid)

      assert {:ok, %{"metadata" => %{}}} =
               Client.get(provider, "PersistentVolumeClaim", home_claim)

      second = start_instance(provider, ctx, uid, "second")

      assert exec(
               ctx,
               second,
               "cat /workspace/keep /var/cache/ankole/keep /agents/$WORKER_ID/old-path"
             ) == "persistentcachelegacy"

      remove_instances(provider, uid)

      assert {:ok, true} =
               wait_until(deadline(30_000), fn ->
                 Kubernetes.delete_cache(provider, uid) == :ok
               end)

      assert :ok = Kubernetes.prepare_storage(provider, uid)
      third = start_instance(provider, ctx, uid, "third")

      assert exec(ctx, third, "test ! -e /var/cache/ankole/keep; cat /workspace/keep") ==
               "persistent"

      remove_instances(provider, uid)

      if @layout == :shared,
        do: delete_with_retained_helper(provider, ctx, uid),
        else: delete_storage(provider, uid)

      assert exec(ctx, peer_name, "cat /workspace/keep") == "peer"

      assert {:ok, nil} =
               Client.get(
                 provider,
                 "PersistentVolumeClaim",
                 ProviderKind.storage_name("storage", uid) <> "-cache"
               )

      if @layout == :exclusive,
        do: assert({:ok, nil} = Client.get(provider, "PersistentVolumeClaim", home_claim))

      if @layout == :shared do
        assert {:ok, %{}} = Client.get(provider, "PersistentVolumeClaim", home_claim)

        assert {:ok, nil} =
                 Client.get(
                   provider,
                   "Pod",
                   ProviderKind.storage_name("storage", uid) <> "-storage"
                 )
      end

      remove_instances(provider, peer)
      delete_storage(provider, peer)
    end
  end

  test "the Helm control-plane Role permits provider checks and storage operations", ctx do
    chart = Path.expand("../../../tools/deploy/helm/ankole-agent", __DIR__)

    {output, status} =
      System.cmd("helm", ["template", "ankole", chart, "--namespace", ctx.namespace],
        stderr_to_stdout: true
      )

    assert status == 0, output
    docs = output |> YamlElixir.read_all_from_string!() |> Enum.filter(&is_map/1)
    seed = Enum.find(docs, &get_in(&1, ["stringData", "providers.yaml"]))
    [entry] = YamlElixir.read_from_string!(seed["stringData"]["providers.yaml"])["providers"]
    {:ok, settings} = Configuration.parse(Kubernetes.definition().schema, entry["config"])

    resources =
      Enum.filter(docs, fn doc ->
        doc["kind"] in ["ServiceAccount", "Role", "RoleBinding"] or
          (doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == settings["ownerConfigMap"])
      end)

    manifest = Path.join(System.tmp_dir!(), "#{ctx.namespace}-rbac.json")

    File.write!(
      manifest,
      Ankole.JSON.encode!(%{"apiVersion" => "v1", "kind" => "List", "items" => resources})
    )

    try do
      kubectl!(ctx.kubeconfig_path, ["-n", ctx.namespace, "apply", "-f", manifest])
    after
      File.rm!(manifest)
    end

    binding = Enum.find(resources, &(&1["kind"] == "RoleBinding"))
    [subject] = binding["subjects"]
    user = "system:serviceaccount:#{ctx.namespace}:#{subject["name"]}"

    # The real API evaluates the rendered Role. Impersonation does not mint a token.
    kubeconfig =
      ctx.kubeconfig
      |> YamlElixir.read_from_string!()
      |> Map.update!("users", fn users -> Enum.map(users, &put_in(&1, ["user", "as"], user)) end)
      |> Ankole.JSON.encode!()

    provider =
      provider(ctx, :exclusive)
      |> put_in([Access.key!(:settings), "ownerConfigMap"], settings["ownerConfigMap"])
      |> put_in([Access.key!(:secrets), "kubeconfig"], kubeconfig)

    assert :ok = Kubernetes.check(provider)
    assert :ok = Kubernetes.prepare_storage(provider, "rbac-agent")
    assert {:ok, []} = Kubernetes.list_instances(provider, "rbac-agent")
    delete_storage(provider, "rbac-agent")
  end

  defp provider(ctx, layout) do
    claim = %{
      storageClassName: "standard",
      accessModes: ["ReadWriteOnce"],
      resources: %{requests: %{storage: "128Mi"}}
    }

    storage =
      if layout == :exclusive, do: %{claimTemplate: claim}, else: %{sharedClaim: "agent-homes"}

    config = %{
      namespace: ctx.namespace,
      storage: storage,
      cache: %{claimTemplate: claim},
      serviceAccount: "default",
      podTemplate: %{spec: %{containers: [%{name: "worker", imagePullPolicy: "Never"}]}},
      stopGraceSeconds: 3,
      endpoints: %{
        runtimeFabricUrl: "ws://127.0.0.1:1/runtime-fabric/worker",
        relayOrigin: "http://127.0.0.1:1",
        aiGatewayUrl: "http://127.0.0.1:1/api/v1/ai-gateway"
      }
    }

    assert {:ok, settings} =
             Configuration.parse(Kubernetes.definition().schema, Ankole.JSON.encode!(config))

    secrets = %{"kubeconfig" => ctx.kubeconfig}
    assert :ok = Credentials.validate(Kubernetes, Kubernetes.definition(), settings, secrets)

    %Provider{
      provider_id: "kubernetes-test",
      kind: "kubernetes",
      settings: settings,
      secrets: secrets,
      runtime: %{
        installation: "storage",
        image: ctx.image,
        runtime_fabric_endpoint: "ws://127.0.0.1:1/runtime-fabric/worker",
        source_root: nil,
        internal_skills_root: nil
      }
    }
  end

  defp prepare_shared_volume(provider, ctx) do
    assert {:ok, _claim} =
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

    # Operator storage preparation precedes restricted Worker admission (WP 2.5).
    assert {:ok, _pod} =
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

    kubectl!(ctx.kubeconfig_path, [
      "-n",
      ctx.namespace,
      "wait",
      "--for=jsonpath={.status.phase}=Succeeded",
      "pod/storage-permissions",
      "--timeout=60s"
    ])

    kubectl!(ctx.kubeconfig_path, [
      "-n",
      ctx.namespace,
      "delete",
      "pod/storage-permissions",
      "--grace-period=1",
      "--wait=true"
    ])
  end

  defp start_instance(provider, ctx, uid, generation) do
    spec = WorkerBootstrap.agent_worker_spec(provider, uid, generation, "local-storage-test")
    assert {:ok, nil} = Kubernetes.create_instance(provider, spec)
    name = ProviderKind.instance_name("storage", uid, generation)

    first_uid =
      kubectl!(ctx.kubeconfig_path, [
        "-n",
        ctx.namespace,
        "get",
        "pod",
        name,
        "-o",
        "jsonpath={.metadata.uid}"
      ])

    assert {:ok, nil} = Kubernetes.create_instance(provider, spec)

    assert kubectl!(ctx.kubeconfig_path, [
             "-n",
             ctx.namespace,
             "get",
             "pod",
             name,
             "-o",
             "jsonpath={.metadata.uid}"
           ]) == first_uid

    kubectl!(ctx.kubeconfig_path, [
      "-n",
      ctx.namespace,
      "wait",
      "--for=condition=Ready",
      "pod/#{name}",
      "--timeout=60s"
    ])

    name
  end

  defp remove_instances(provider, uid) do
    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               assert {:ok, instances} = Kubernetes.list_instances(provider, uid)

               for instance <- instances,
                   do: assert(:ok = Kubernetes.delete_instance(provider, instance, :now))

               instances == []
             end)
  end

  defp delete_storage(provider, uid) do
    delete_storage(provider, uid, nil, deadline(30_000))
  end

  defp delete_with_retained_helper(provider, ctx, uid) do
    assert {:ok, true} =
             wait_until(deadline(30_000), fn -> Kubernetes.delete_cache(provider, uid) == :ok end)

    assert {:pending, nil} = Kubernetes.delete_storage(provider, uid, nil)
    helper = ProviderKind.storage_name("storage", uid) <> "-storage"

    kubectl!(ctx.kubeconfig_path, [
      "-n",
      ctx.namespace,
      "wait",
      "--for=jsonpath={.status.phase}=Succeeded",
      "pod/#{helper}",
      "--timeout=60s"
    ])

    kubectl!(ctx.kubeconfig_path, [
      "-n",
      ctx.namespace,
      "patch",
      "pod",
      helper,
      "--type=merge",
      "-p",
      ~s({"metadata":{"finalizers":["ankole.test/retain"]}})
    ])

    try do
      assert {:ok, nil} = Kubernetes.delete_storage(provider, uid, nil)

      assert {:ok, %{"metadata" => %{"deletionTimestamp" => _}}} =
               Client.get(provider, "Pod", helper)
    after
      kubectl!(ctx.kubeconfig_path, [
        "-n",
        ctx.namespace,
        "patch",
        "pod",
        helper,
        "--type=merge",
        "-p",
        ~s({"metadata":{"finalizers":[]}})
      ])
    end

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               Client.get(provider, "Pod", helper) == {:ok, nil}
             end)
  end

  defp delete_storage(provider, uid, ref, until) do
    result = Kubernetes.delete_storage(provider, uid, ref)

    case result do
      {:ok, nil} ->
        :ok

      {:pending, next_ref} ->
        retry_storage(provider, uid, next_ref, until)

      {:error, {:kubernetes_claim_deleting, _name}} ->
        retry_storage(provider, uid, ref, until)

      error ->
        flunk("Storage deletion failed: #{inspect(error)}")
    end
  end

  defp retry_storage(provider, uid, ref, until) do
    assert System.monotonic_time(:millisecond) < until, "Storage deletion did not finish"
    Process.sleep(50)
    delete_storage(provider, uid, ref, until)
  end

  defp exec(ctx, name, script),
    do:
      kubectl!(ctx.kubeconfig_path, ["-n", ctx.namespace, "exec", name, "--", "sh", "-ec", script])

  defp kubectl!(kubeconfig, args) do
    {output, status} =
      System.cmd("kubectl", ["--kubeconfig", kubeconfig | args], stderr_to_stdout: true)

    assert status == 0, "kubectl #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end
end
