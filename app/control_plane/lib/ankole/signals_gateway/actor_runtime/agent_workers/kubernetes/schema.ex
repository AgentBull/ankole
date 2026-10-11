defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Kubernetes.Schema do
  @moduledoc "Native Kubernetes types with the fields owned by the Worker contract removed."

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Configuration, as: C
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap

  @external_resource Path.expand(
                       "../../../../../../priv/worker_provider_schemas/kubernetes.json",
                       __DIR__
                     )
  @native :json.decode(File.read!(@external_resource))
  @pod "io.k8s.api.core.v1.PodSpec"
  @container "io.k8s.api.core.v1.Container"
  @pvc "io.k8s.api.core.v1.PersistentVolumeClaimSpec"

  def schema do
    definitions = @native["definitions"]

    container =
      definitions[@container]
      |> without(~w(image command args volumeMounts volumeDevices securityContext envFrom))
      |> put_in(["properties", "name"], %{"type" => "string", "enum" => ["worker"]})
      |> put_in(["properties", "env", "items"], env_schema(definitions))

    pod =
      definitions[@pod]
      |> without(
        ~w(volumes restartPolicy terminationGracePeriodSeconds serviceAccount serviceAccountName automountServiceAccountToken
        securityContext initContainers ephemeralContainers hostNetwork hostPID hostIPC)
      )
      |> put_in(["properties", "containers"], %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 1,
        "items" => container
      })

    claim =
      definitions[@pvc]
      |> Map.put("required", ~w(accessModes resources))
      |> put_in(["properties", "accessModes"], %{
        "type" => "array",
        "minItems" => 1,
        "items" => %{"enum" => ~w(ReadWriteOnce ReadWriteOncePod ReadWriteMany)}
      })
      |> put_in(["properties", "volumeMode"], %{"enum" => ["Filesystem"]})
      |> put_in(["properties", "resources"], %{
        "allOf" => [
          definitions["io.k8s.api.core.v1.VolumeResourceRequirements"],
          %{
            "required" => ["requests"],
            "properties" => %{"requests" => %{"required" => ["storage"]}}
          }
        ]
      })

    storage =
      C.object(%{"claimTemplate" => claim, "sharedClaim" => name()}, [])
      |> Map.put("oneOf", [%{"required" => ["claimTemplate"]}, %{"required" => ["sharedClaim"]}])

    cache =
      C.object(
        %{
          "claimTemplate" => claim,
          "sizeLimit" => %{
            "$ref" => "#/definitions/io.k8s.apimachinery.pkg.api.resource.Quantity"
          }
        },
        []
      )
      |> Map.put("oneOf", [%{"required" => ["claimTemplate"]}, %{"required" => ["sizeLimit"]}])

    C.object(
      Map.merge(C.common("15m"), %{
        "namespace" => C.field(name(), :location),
        "ownerConfigMap" => C.field(name(), :location),
        "storage" => C.field(storage, :location),
        "cache" => C.field(cache, :instance),
        "serviceAccount" => C.field(name(), :instance),
        "podTemplate" => C.field(C.object(%{"spec" => pod}, ["spec"]), :instance)
      }),
      ~w(namespace storage serviceAccount podTemplate)
    )
    |> Map.put("definitions", definitions)
  end

  defp name,
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 253,
      "pattern" => "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"
    }

  defp without(schema, fields) do
    schema = Map.update!(schema, "properties", &Map.drop(&1, fields))

    case Map.get(schema, "required", []) -- fields do
      [] -> Map.delete(schema, "required")
      required -> Map.put(schema, "required", required)
    end
  end

  defp env_schema(definitions) do
    definitions["io.k8s.api.core.v1.EnvVar"]
    |> put_in(["properties", "name"], %{
      "type" => "string",
      "pattern" => "^[A-Za-z_][A-Za-z0-9_]*$",
      "not" => %{"enum" => WorkerBootstrap.contract_env_names()}
    })
  end
end
