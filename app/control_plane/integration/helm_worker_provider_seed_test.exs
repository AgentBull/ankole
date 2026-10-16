defmodule Ankole.HelmWorkerProviderSeedIntegrationTest do
  use ExUnit.Case, async: false

  alias Ankole.AgentWorkers.Cloudflare
  alias Ankole.AgentWorkers.Kubernetes
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers.Configuration

  @root Path.expand("../../..", __DIR__)
  @namespace "ankole-wp-chart"
  @chart "tools/deploy/helm/ankole-agent"
  @local_worker_objects ~w(ConfigMap NetworkPolicy PersistentVolumeClaim Role RoleBinding ServiceAccount)

  test "preserves the shared claim and imports valid provider settings" do
    docs = render!(@chart, %{"networkPolicy" => %{"enabled" => true}})
    [provider] = providers(docs)
    settings = settings!(provider)
    assert provider["legacy_agents"]
    assert provider["is_default"]
    claim = resource!(docs, "PersistentVolumeClaim", settings["storage"]["sharedClaim"])
    assert claim["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
    refute claim["metadata"]["ownerReferences"]

    assert claim["metadata"]["name"] == "ankole-ankole-agent-agents"
    refute Map.has_key?(settings["podTemplate"]["spec"], "runtimeClassName")

    role = Enum.find(docs, &(&1["kind"] == "Role"))

    for resource <- ["persistentvolumeclaims", "secrets"] do
      assert Enum.any?(role["rules"], fn rule ->
               resource in rule["resources"] and rule["verbs"] == ["create", "delete", "list"]
             end)
    end

    assert Enum.any?(docs, fn doc ->
             doc["kind"] == "NetworkPolicy" and
               get_in(doc, ["spec", "podSelector", "matchLabels", "ankole.io/task"]) == "worker"
           end)

    sa = resource!(docs, "ServiceAccount", settings["serviceAccount"])
    assert sa["automountServiceAccountToken"] == false
    resource!(docs, "ConfigMap", settings["ownerConfigMap"])

    docs =
      render!(@chart, %{
        "worker" => %{
          "agents" => %{"persistence" => %{"existingClaim" => "old-agents"}},
          "runtimeClassName" => "gvisor"
        }
      })

    [provider] = providers(docs)
    settings = settings!(provider)
    assert provider["legacy_agents"]
    assert settings["storage"] == %{"sharedClaim" => "old-agents"}
    assert settings["podTemplate"]["spec"]["runtimeClassName"] == "gvisor"
    refute Enum.any?(docs, &worker_claim?/1)
  end

  test "does not assign old Agents to a new exclusive volume" do
    storage = %{
      "claimTemplate" => %{
        "accessModes" => ["ReadWriteOnce"],
        "storageClassName" => "standard",
        "resources" => %{"requests" => %{"storage" => "10Gi"}}
      }
    }

    docs = render!(@chart, %{"worker" => %{"storage" => storage}})
    [provider] = providers(docs)
    assert provider["legacy_agents"] == false
    assert settings!(provider)["storage"] == storage
    refute Enum.any?(docs, &worker_claim?/1)
  end

  test "preserves raw YAML and keeps local Worker objects for any seed" do
    raw =
      "# Keep this comment and the final blank line.\n" <>
        Kubernetes.definition().example <> "\n"

    docs = render!(@chart, %{"worker" => %{"providerConfig" => raw}})
    [provider] = providers(docs)
    assert provider["config"] == raw
    settings!(provider)

    # The control plane reads the seed only on its first start. A later seed
    # without a local provider must not delete the objects that stored
    # providers and their running Workers use.
    docs =
      render!(@chart, %{
        "worker" => %{"providers" => cloudflare_entries()},
        "networkPolicy" => %{"enabled" => true}
      })

    assert providers(docs) == cloudflare_entries()
    Enum.each(cloudflare_entries(), &settings!/1)
    assert local_worker_objects(docs) == @local_worker_objects
    deployment = Enum.find(docs, &(&1["kind"] == "Deployment"))
    pod = deployment["spec"]["template"]["spec"]
    container = Enum.find(pod["containers"], &(&1["name"] == "control-plane"))
    mount = Enum.find(container["volumeMounts"], &(&1["name"] == "bootstrap-secrets"))
    assert mount["mountPath"] == "/etc/ankole/bootstrap"
    assert mount["readOnly"]
    volume = Enum.find(pod["volumes"], &(&1["name"] == "bootstrap-secrets"))
    assert is_binary(volume["secret"]["secretName"])

    {output, status} =
      render(@chart, %{
        "worker" => %{"providers" => cloudflare_entries()},
        "controlPlane" => %{"replicaCount" => 2}
      })

    assert status != 0
    assert output =~ "endpoints.relayOrigin requires one control-plane replica"
  end

  test "removes local Worker objects only when worker.localPods is false" do
    docs =
      render!(@chart, %{
        "worker" => %{"localPods" => false, "providers" => cloudflare_entries()},
        "networkPolicy" => %{"enabled" => true}
      })

    assert providers(docs) == cloudflare_entries()
    assert local_worker_objects(docs) == []

    {output, status} = render(@chart, %{"worker" => %{"localPods" => false}})
    assert status != 0
    assert output =~ "worker.localPods=false requires worker.providers"
  end

  defp cloudflare_entries do
    for id <- ["cf-small", "cf-large"] do
      %{
        "provider_id" => id,
        "kind" => "cloudflare",
        "display_name" => id,
        "is_default" => id == "cf-small",
        "config" => "# " <> id <> "\n" <> Cloudflare.definition().example,
        "credentials" => %{
          "adapterToken" => %{"file" => "/etc/ankole/bootstrap/worker-adapter-token"}
        }
      }
    end
  end

  # Objects that let the control plane run Worker Pods in the release namespace.
  defp local_worker_objects(docs) do
    docs
    |> Enum.filter(fn doc ->
      doc["kind"] in @local_worker_objects and
        (doc["kind"] in ["Role", "RoleBinding"] or
           doc["metadata"]["labels"]["app.kubernetes.io/component"] == "worker")
    end)
    |> Enum.map(& &1["kind"])
    |> Enum.sort()
  end

  defp worker_claim?(doc) do
    doc["kind"] == "PersistentVolumeClaim" and
      doc["metadata"]["labels"]["app.kubernetes.io/component"] == "worker"
  end

  defp settings!(entry) do
    {:ok, module} = ProviderKind.fetch(entry["kind"])
    assert {:ok, settings} = Configuration.parse(module.definition().schema, entry["config"])
    settings
  end

  defp providers(docs) do
    secret =
      Enum.find(docs, &(&1["kind"] == "Secret" and get_in(&1, ["stringData", "providers.yaml"])))

    YamlElixir.read_from_string!(secret["stringData"]["providers.yaml"])["providers"]
  end

  defp resource!(docs, kind, name) do
    resource = Enum.find(docs, &(&1["kind"] == kind and &1["metadata"]["name"] == name))
    assert resource, "missing #{kind}/#{name}"
    resource
  end

  defp render!(chart, values) do
    {output, status} = render(chart, values)
    assert status == 0, output
    output |> YamlElixir.read_all_from_string!() |> Enum.filter(&is_map/1)
  end

  defp render(chart, values) do
    path = Path.join(System.tmp_dir!(), "ankole-helm-#{System.unique_integer([:positive])}.json")
    File.write!(path, Ankole.JSON.encode!(values))

    try do
      args = [
        "template",
        "ankole",
        Path.join(@root, chart),
        "--namespace",
        @namespace,
        "--values",
        path
      ]

      System.cmd("helm", args, stderr_to_stdout: true)
    after
      File.rm!(path)
    end
  end
end
