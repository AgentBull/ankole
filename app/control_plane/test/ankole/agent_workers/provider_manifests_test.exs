defmodule Ankole.AgentWorkers.ProviderManifestsTest do
  use ExUnit.Case, async: true

  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Docker
  alias Ankole.AgentWorkers.Kubernetes
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers.Configuration
  alias Ankole.AgentWorkers.WorkerBootstrap

  @tenant_id "01900000-0000-7000-8000-000000000001"

  setup do
    # Manifest construction runs after the lifecycle owner has selected a tenant.
    Ankole.Repo.put_tenant_id(@tenant_id)
    :ok
  end

  @endpoint "ws://control-plane:4000/runtime-fabric/worker"

  test "instance names use the installation, Agent hash, and generation; storage omits generation" do
    home = ProviderKind.storage_name("prod", "agent-a")
    name = ProviderKind.instance_name("prod", "agent-a", "gen0000001")
    assert home == "ankole-prod-#{ProviderKind.hash16("agent-a")}"
    assert name == home <> "-gen0000001"
    assert String.length(ProviderKind.hash16("agent-a")) == 16
    assert String.length(name) <= 63
  end

  test "Docker mounts independent home and cache volumes with provider ownership and no restart" do
    provider = provider(Docker, %{"network" => "ankole_backend"})
    body = Docker.container_body(provider, spec(provider))
    assert body["Image"] == "worker:2"

    assert body["Labels"] == %{
             "ankole.worker" => "1",
             "ankole.tenant" => @tenant_id,
             "ankole.installation" => "prod",
             "ankole.provider" => "local",
             "ankole.agent-uid" => "agent-a",
             "ankole.generation" => "gen0000001"
           }

    host = body["HostConfig"]
    home = ProviderKind.storage_name("prod", "agent-a")
    assert host["RestartPolicy"] == %{"Name" => "no"}

    assert host["Mounts"] == [
             %{"Type" => "volume", "Source" => home, "Target" => "/workspace"},
             %{"Type" => "volume", "Source" => home <> "-cache", "Target" => "/var/cache/ankole"}
           ]

    refute Map.has_key?(host, "CapAdd")
    assert host["SecurityOpt"] == ["no-new-privileges"]
    assert host["ExtraHosts"] == ["host.docker.internal:host-gateway"]
    assert host["NetworkMode"] == "ankole_backend"
    refute Map.has_key?(body, "Cmd")
    assert "WORKER_ID=agent-a" in body["Env"]
    assert "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=token-a" in body["Env"]
  end

  test "Docker maps instance limits and keeps development mounts read-only" do
    provider =
      provider(Docker, %{
        "cpus" => 2,
        "memoryMiB" => 4096,
        "runtime" => "runsc",
        "env" => %{"ANKOLE_MAX_CONCURRENT_SLOTS" => "12"}
      })

    provider = put_in(provider.runtime.source_root, "/repo/app/agent_computer/src")
    body = Docker.container_body(provider, spec(provider))
    assert "ANKOLE_MAX_CONCURRENT_SLOTS=12" in body["Env"]
    assert body["HostConfig"]["Memory"] == 4_294_967_296
    assert body["HostConfig"]["NanoCpus"] == 2_000_000_000
    assert body["HostConfig"]["Runtime"] == "runsc"
    assert body["Cmd"] == ["bun", "--watch", "src/main.ts"]

    assert %{
             "Type" => "bind",
             "Source" => "/repo/app/agent_computer/src",
             "Target" => "/repo/app/agent_computer/src",
             "ReadOnly" => true
           } in body["HostConfig"]["Mounts"]
  end

  test "development Docker mounts internal Skills at the image root" do
    provider = provider(Docker)
    body = Docker.container_body(provider, spec(provider))
    refute Enum.any?(body["Env"], &String.starts_with?(&1, "ANKOLE_INTERNAL_SKILLS_ROOT="))
    refute Enum.any?(body["HostConfig"]["Mounts"], &(&1["Target"] == "/repo/internals/skills"))
    provider = put_in(provider.runtime.internal_skills_root, "/host/internal")
    body = Docker.container_body(provider, spec(provider))
    assert "ANKOLE_INTERNAL_SKILLS_ROOT=/repo/internals/skills" in body["Env"]

    assert %{
             "Type" => "bind",
             "Source" => "/host/internal",
             "Target" => "/repo/internals/skills",
             "ReadOnly" => true
           } in body["HostConfig"]["Mounts"]
  end

  test "Docker decodes multiplexed logs and preserves a TTY stream" do
    frames = <<1, 0, 0, 0, 6::32, "line1\n", 2, 0, 0, 0, 6::32, "line2\n">>
    assert Docker.demultiplex(frames) == ["line1\n", "line2\n"]
    assert Docker.demultiplex("plain output\n") == ["plain output\n"]
    assert Docker.demultiplex(<<>>) == []
  end

  test "Kubernetes renders home storage independently of instance lifetime and keeps the credential in a Secret" do
    provider = provider(Kubernetes)
    spec = spec(provider)
    pod = Kubernetes.pod_manifest(provider, spec, owner())
    name = ProviderKind.instance_name("prod", "agent-a", "gen0000001")
    home = ProviderKind.storage_name("prod", "agent-a")
    assert pod["metadata"]["name"] == name
    assert pod["metadata"]["labels"]["ankole.io/provider"] == "local"
    assert pod["metadata"]["labels"]["ankole.tenant"] == @tenant_id
    assert pod["metadata"]["labels"]["ankole.io/agent"] == ProviderKind.hash16("agent-a")
    assert pod["metadata"]["labels"]["ankole.io/generation"] == "gen0000001"
    assert pod["metadata"]["annotations"]["ankole.io/agent-uid"] == "agent-a"
    assert pod["metadata"]["ownerReferences"] == [owner()]
    assert pod["spec"]["restartPolicy"] == "Never"
    assert pod["spec"]["automountServiceAccountToken"] == false
    assert pod["spec"]["serviceAccountName"] == provider.settings["serviceAccount"]

    assert pod["spec"]["volumes"] == [
             %{"name" => "home", "persistentVolumeClaim" => %{"claimName" => home}},
             %{"name" => "cache", "emptyDir" => %{"sizeLimit" => "5Gi"}}
           ]

    [worker] = pod["spec"]["containers"]
    assert worker["image"] == "worker:2"
    assert worker["resources"]["limits"]["memory"] == "4Gi"

    assert worker["volumeMounts"] == [
             %{"name" => "home", "mountPath" => "/workspace"},
             %{"name" => "cache", "mountPath" => "/var/cache/ankole"}
           ]

    env = Map.new(worker["env"], &{&1["name"], &1})
    assert env["WORKER_ID"]["value"] == "agent-a"
    assert env["ANKOLE_RUNTIME_FABRIC_ENDPOINT"]["value"] == @endpoint

    assert env["ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY"] == %{
             "name" => "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY",
             "valueFrom" => %{
               "secretKeyRef" => %{
                 "name" => name,
                 "key" => "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY"
               }
             }
           }

    secret = Kubernetes.secret_manifest(provider, spec, owner())
    assert secret["metadata"]["name"] == name
    assert secret["metadata"]["labels"]["ankole.io/provider"] == "local"
    assert secret["stringData"] == %{"ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => "token-a"}
  end

  test "Kubernetes mounts shared home by full Agent UID and cache PVC by Agent identity" do
    base = provider(Kubernetes)

    provider =
      provider(Kubernetes, %{
        "storage" => %{"sharedClaim" => "agents"},
        "cache" => %{"claimTemplate" => base.settings["storage"]["claimTemplate"]}
      })

    pod = Kubernetes.pod_manifest(provider, spec(provider), owner())
    home = ProviderKind.storage_name("prod", "agent-a")

    assert pod["spec"]["volumes"] == [
             %{"name" => "home", "persistentVolumeClaim" => %{"claimName" => "agents"}},
             %{"name" => "cache", "persistentVolumeClaim" => %{"claimName" => home <> "-cache"}}
           ]

    [worker] = pod["spec"]["containers"]

    assert %{"name" => "home", "mountPath" => "/workspace", "subPath" => "agent-a"} in worker[
             "volumeMounts"
           ]
  end

  test "Pod observations retain scheduling failures and distinguish a partial Secret" do
    resource = %{
      "metadata" => %{
        "labels" => %{"ankole.io/generation" => "gen0000001"},
        "annotations" => %{"ankole.io/agent-uid" => "agent-a"},
        "creationTimestamp" => "2026-10-03T10:00:00Z"
      }
    }

    assert %{instance_present?: false} = Kubernetes.worker_object(resource, nil)

    assert %{instance_present?: true, phase: :running} =
             Kubernetes.worker_object(resource, %{"status" => %{"phase" => "Running"}})

    assert %{phase: :terminating} =
             Kubernetes.worker_object(resource, %{
               "metadata" => %{"deletionTimestamp" => "2026-10-03T10:05:00Z"},
               "status" => %{"phase" => "Running"}
             })

    assert %{phase: :exited, reason: "Evicted"} =
             Kubernetes.worker_object(resource, %{
               "status" => %{"phase" => "Failed", "reason" => "Evicted"}
             })

    assert %{phase: :starting, reason: "ImagePullBackOff: Back-off pulling image"} =
             Kubernetes.worker_object(resource, %{
               "status" => %{
                 "phase" => "Pending",
                 "containerStatuses" => [
                   %{
                     "state" => %{
                       "waiting" => %{
                         "reason" => "ImagePullBackOff",
                         "message" => "Back-off pulling image"
                       }
                     }
                   }
                 ]
               }
             })

    assert %{phase: :starting, reason: "0/3 nodes are available"} =
             Kubernetes.worker_object(resource, %{
               "status" => %{
                 "phase" => "Pending",
                 "conditions" => [
                   %{"reason" => "Unschedulable", "message" => "0/3 nodes are available"}
                 ]
               }
             })
  end

  defp provider(kind, overrides \\ %{}) do
    {:ok, base} = Configuration.parse(kind.definition().schema, kind.definition().example)

    {:ok, settings} =
      Configuration.parse(
        kind.definition().schema,
        Ankole.JSON.encode!(Map.merge(base, overrides))
      )

    {:ok, runtime} =
      Config.load(
        image: "worker:2",
        installation: "prod",
        runtime_fabric_endpoint: @endpoint,
        observing_since: ~U[2026-10-07 00:00:00Z]
      )

    %{
      provider_id: "local",
      kind: kind.definition().kind,
      settings: settings,
      runtime: runtime,
      secrets: %{}
    }
  end

  defp spec(provider),
    do: WorkerBootstrap.agent_worker_spec(provider, "agent-a", "gen0000001", "token-a")

  defp owner,
    do: %{"apiVersion" => "v1", "kind" => "ConfigMap", "name" => "workers", "uid" => "uid-1"}
end
