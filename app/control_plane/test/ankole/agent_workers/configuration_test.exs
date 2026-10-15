defmodule Ankole.AgentWorkers.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Ankole.AgentWorkers.Cloudflare
  alias Ankole.AgentWorkers.FunctionCompute
  alias Ankole.AgentWorkers.Kubernetes
  alias Ankole.AgentWorkers.Providers.Configuration
  alias Ankole.AgentWorkers.WorkerBootstrap

  @cloudflare """
  adapterUrl: https://workers.example.test
  endpoints:
    runtimeFabricUrl: wss://ankole.example.test/runtime-fabric/worker
    relayOrigin: https://ankole.example.test
    aiGatewayUrl: https://ankole.example.test/api/v1/ai-gateway
  """

  test "a value that matches no alternative names the keys that can satisfy it" do
    config = """
    namespace: ankole
    storage: {}
    serviceAccount: worker
    podTemplate:
      spec:
        containers:
          - name: worker
    """

    assert {:error, {:invalid_worker_provider_config, errors}} =
             Configuration.parse(Kubernetes.definition().schema, config)

    assert errors == [
             %{path: "storage", line: 2, message: "requires one of: claimTemplate, sharedClaim"}
           ]
  end

  test "an alternative of another form does not hide the missing key of the intended form" do
    schema = Cloudflare.definition().schema

    assert {:error, {:invalid_worker_provider_config, errors}} =
             Configuration.parse(
               schema,
               @cloudflare <> "instance:\n  cpus: 2\n  memoryMiB: 4096\n"
             )

    assert errors == [%{path: "instance.diskMB", line: 6, message: "is required"}]

    assert {:error, {:invalid_worker_provider_config, errors}} =
             Configuration.parse(schema, @cloudflare <> "instance: huge\n")

    assert [_enum, _type] = errors
    assert Enum.all?(errors, &(&1.path == "instance" and &1.line == 6))
  end

  test "a conditional requirement names the missing key, also below the root" do
    schema =
      Configuration.object(%{
        "storage" => Configuration.object(%{"fs" => %{"type" => "string"}}),
        "vpc" => %{"type" => "string"},
        "inner" =>
          Configuration.object(%{
            "kind" => %{"type" => "string"},
            "size" => %{"type" => "integer"}
          })
          |> Map.merge(%{
            "if" => %{"required" => ["kind"], "properties" => %{"kind" => %{"const" => "big"}}},
            "then" => %{"required" => ["size"], "properties" => %{"size" => %{"minimum" => 10}}}
          })
      })
      |> Map.merge(%{
        "if" => %{
          "required" => ["storage"],
          "properties" => %{"storage" => %{"required" => ["fs"]}}
        },
        "then" => %{"required" => ["vpc"]}
      })

    assert {:error, {:invalid_worker_provider_config, [%{path: "vpc", line: 1}]}} =
             Configuration.parse(schema, "storage:\n  fs: one\n")

    assert {:ok, _settings} = Configuration.parse(schema, "storage: {}\n")

    assert {:error, {:invalid_worker_provider_config, [%{path: "inner.size", line: 1}]}} =
             Configuration.parse(schema, "inner:\n  kind: big\n")

    assert {:error,
            {:invalid_worker_provider_config,
             [%{path: "inner.size", line: 3, message: "Expected the value to be >= 10"}]}} =
             Configuration.parse(schema, "inner:\n  kind: big\n  size: 1\n")
  end

  test "Function Compute AgenticFS storage without vpc names vpc" do
    schema = FunctionCompute.definition().schema
    {:ok, settings} = Configuration.parse(schema, FunctionCompute.definition().example)

    assert {:error, {:invalid_worker_provider_config, [%{path: "vpc", message: "is required"}]}} =
             Configuration.parse(schema, Ankole.JSON.encode!(Map.delete(settings, "vpc")))

    oss = %{"oss" => %{"bucket" => "ankole-agents", "root" => "/ankole"}}

    assert {:ok, _settings} =
             Configuration.parse(
               schema,
               Ankole.JSON.encode!(settings |> Map.delete("vpc") |> Map.put("storage", oss))
             )
  end

  test "a Pod template cannot set the fields that the control plane owns" do
    schema = Kubernetes.definition().schema

    pod_fields =
      ~w(volumes restartPolicy terminationGracePeriodSeconds serviceAccount serviceAccountName
      automountServiceAccountToken securityContext initContainers ephemeralContainers hostNetwork
      hostPID hostIPC)

    container_fields = ~w(image command args volumeMounts volumeDevices securityContext envFrom)

    for field <- pod_fields do
      assert pod_errors(schema, %{field => "x"}, %{}) == [
               %{
                 path: "podTemplate.spec." <> field,
                 message: "Schema does not allow additional properties."
               }
             ]
    end

    for field <- container_fields do
      assert pod_errors(schema, %{}, %{field => "x"}) == [
               %{
                 path: "podTemplate.spec.containers.0." <> field,
                 message: "Schema does not allow additional properties."
               }
             ]
    end

    for name <- WorkerBootstrap.contract_env_names() do
      assert [%{path: "podTemplate.spec.containers.0.env.0.name"}] =
               pod_errors(schema, %{}, %{"env" => [%{"name" => name, "value" => "x"}]})
    end

    assert [%{path: "podTemplate.spec.containers.0.name"}] =
             pod_errors(schema, %{}, %{"name" => "sidecar"})

    assert [%{path: "podTemplate.spec.containers"}] =
             pod_errors(
               schema,
               %{"containers" => [%{"name" => "worker"}, %{"name" => "worker"}]},
               %{}
             )
  end

  defp pod_errors(schema, pod, container) do
    config = %{
      "namespace" => "ankole",
      "storage" => %{"sharedClaim" => "agents"},
      "serviceAccount" => "worker",
      "podTemplate" => %{
        "spec" => Map.merge(%{"containers" => [Map.merge(%{"name" => "worker"}, container)]}, pod)
      }
    }

    {:error, {:invalid_worker_provider_config, errors}} =
      Configuration.parse(schema, Ankole.JSON.encode!(config))

    Enum.map(errors, &Map.delete(&1, :line))
  end
end
