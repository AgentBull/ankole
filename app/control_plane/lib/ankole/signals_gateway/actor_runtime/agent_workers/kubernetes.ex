defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Kubernetes do
  @moduledoc """
  Worker instances and storage in one Kubernetes namespace.

  Pods and Secrets belong to a generation. Durable and cache PVCs belong to
  the Agent. A successful Pod DELETE is a request, not proof that its
  process stopped. Only absence from the platform list permits a new writer.
  """

  @behaviour Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind

  # The digest of the cache claim template that made a cache PVC.
  @cache_settings "ankole.io/cache-settings"

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind.Definition
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Kubernetes.{Client, Schema}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.YAML
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.AgentWorkerSpec

  @impl true
  def definition do
    %Definition{
      kind: "kubernetes",
      schema: Schema.schema(),
      credentials: %{"kubeconfig" => %{required: false}},
      pause: false,
      example: """
      # Location and storage cannot change after creation.
      namespace: ankole
      storage:
        claimTemplate:
          storageClassName: ebs-gp3
          accessModes: [ReadWriteOncePod]
          resources:
            requests:
              storage: 20Gi
      # To use an existing shared PVC, replace claimTemplate with sharedClaim.
      # Instance settings are applied when an idle Worker is replaced.
      cache:
        sizeLimit: 5Gi
      serviceAccount: ankole-agent-worker
      podTemplate:
        spec:
          containers:
            - name: worker
              resources:
                requests: {cpu: "1", memory: 4Gi}
                limits: {memory: 4Gi}
      stopGraceSeconds: 60
      idleReleaseAfter: 15m
      """
    }
  end

  @impl true
  def validate_credentials(settings, secrets) do
    if Map.has_key?(secrets, "kubeconfig") do
      with {:ok, _config} <- Client.kubeconfig(secrets["kubeconfig"]) do
        cond do
          settings["ownerConfigMap"] ->
            {:error,
             {:invalid_worker_provider_config,
              [
                %{
                  path: "ownerConfigMap",
                  line: nil,
                  message: "is only available with the in-cluster ServiceAccount"
                }
              ]}}

          not Enum.all?(
            ~w(runtimeFabricUrl relayOrigin aiGatewayUrl),
            &is_binary(get_in(settings, ["endpoints", &1]))
          ) ->
            {:error,
             {:invalid_worker_provider_config,
              [
                %{
                  path: "endpoints",
                  line: nil,
                  message: "all three endpoints are required for a remote cluster"
                }
              ]}}

          true ->
            :ok
        end
      end
    else
      :ok
    end
  end

  @impl true
  def prepare_credentials(provider, previous, values) do
    with {:ok, values} <- inline_ca(values),
         :ok <- same_cluster(provider, previous, values),
         do: {:ok, values}
  end

  # Freeze file-based CA data before encryption, so a later file change
  # cannot change the cluster identity without passing validation.
  defp inline_ca(%{"kubeconfig" => text} = secrets) do
    with {:ok, _config} <- Client.kubeconfig(text),
         {:ok, data, _locations} <- YAML.parse(text),
         {:ok, clusters} <-
           Enum.reduce_while(data["clusters"], {:ok, []}, fn cluster, {:ok, acc} ->
             case cluster["cluster"] do
               %{"certificate-authority" => path} = connection ->
                 case File.read(path) do
                   {:ok, ca} ->
                     connection =
                       connection
                       |> Map.delete("certificate-authority")
                       |> Map.put("certificate-authority-data", Base.encode64(ca))

                     {:cont, {:ok, [Map.put(cluster, "cluster", connection) | acc]}}

                   {:error, _reason} ->
                     {:halt, {:error, :worker_provider_ca_unreadable}}
                 end

               _connection ->
                 {:cont, {:ok, [cluster | acc]}}
             end
           end) do
      {:ok,
       Map.put(
         secrets,
         "kubeconfig",
         Ankole.JSON.encode!(Map.put(data, "clusters", Enum.reverse(clusters)))
       )}
    end
  end

  defp inline_ca(secrets), do: {:ok, secrets}

  defp same_cluster(provider, previous, values) do
    with {:ok, before} <- cluster_identity(previous["kubeconfig"]),
         {:ok, after_cluster} <- cluster_identity(values["kubeconfig"]) do
      if provider.__meta__.state == :loaded and before != after_cluster,
        do: {:error, :worker_provider_cluster_immutable},
        else: :ok
    end
  end

  defp cluster_identity(nil), do: {:ok, nil}

  defp cluster_identity(text) do
    with {:ok, config} <- Client.kubeconfig(text) do
      {:ok,
       Map.take(
         config.current_cluster,
         ~w(server certificate-authority certificate-authority-data insecure-skip-tls-verify tls-server-name proxy-url)
       )}
    end
  end

  @impl true
  def check(provider) do
    permissions =
      [{"get", "pods", nil}, {"get", "pods", "log"}, {"list", "events", nil}] ++
        for(
          resource <- ~w(pods secrets persistentvolumeclaims),
          verb <- ~w(create delete list),
          do: {verb, resource, nil}
        ) ++
        if(provider.settings["ownerConfigMap"], do: [{"get", "configmaps", nil}], else: [])

    Enum.reduce_while(permissions, :ok, fn {verb, resource, subresource}, :ok ->
      attributes =
        %{"namespace" => provider.settings["namespace"], "verb" => verb, "resource" => resource}
        |> maybe_put("subresource", subresource)
        |> maybe_put(
          "name",
          if(resource == "configmaps", do: provider.settings["ownerConfigMap"])
        )

      review = %{
        "apiVersion" => "authorization.k8s.io/v1",
        "kind" => "SelfSubjectAccessReview",
        "spec" => %{"resourceAttributes" => attributes}
      }

      case Client.create(provider, review) do
        {:ok, %{"status" => %{"allowed" => true}}} ->
          {:cont, :ok}

        {:ok, %{"status" => status}} ->
          {:halt, {:error, {:kubernetes_permission_denied, verb, resource, status["reason"]}}}

        error ->
          {:halt, error}
      end
    end)
  end

  @impl true
  def prepare_image(_provider, _image), do: :ok

  @impl true
  def prepare_storage(provider, agent_uid) do
    with {:ok, owner} <- owner_reference(provider),
         :ok <- prepare_home(provider, agent_uid),
         :ok <- prepare_cache(provider, agent_uid, owner),
         do: :ok
  end

  @impl true
  def create_instance(provider, %AgentWorkerSpec{} = spec) do
    with {:ok, owner} <- owner_reference(provider),
         :ok <- create_generation_object(provider, secret_manifest(provider, spec, owner)),
         :ok <- create_generation_object(provider, pod_manifest(provider, spec, owner)) do
      {:ok, nil}
    end
  end

  defp create_generation_object(provider, manifest) do
    case Client.create(provider, manifest) do
      {:ok, _object} ->
        :ok

      {:error, {:kubernetes_api, 409, _reason}} ->
        name = manifest["metadata"]["name"]

        with {:ok, objects} <-
               Client.list(provider, manifest["kind"], field_selectors: [{"metadata.name", name}]) do
          case List.first(objects) do
            nil ->
              {:error, {:kubernetes_creation_not_observed, manifest["kind"], name}}

            object ->
              labels = manifest["metadata"]["labels"]

              if Map.take(object["metadata"]["labels"] || %{}, Map.keys(labels)) == labels and
                   get_in(object, ["metadata", "annotations", "ankole.io/agent-uid"]) ==
                     get_in(manifest, ["metadata", "annotations", "ankole.io/agent-uid"]),
                 do: :ok,
                 else: {:rejected, {:kubernetes_instance_owner_mismatch, name}}
          end
        end

      {:error, {:kubernetes_api, status, _message} = reason}
      when status in [400, 401, 403, 404, 405, 422] ->
        {:rejected, reason}

      error ->
        error
    end
  end

  @impl true
  def delete_instance(provider, instance, mode) do
    name =
      instance.instance_ref ||
        ProviderKind.instance_name(
          provider.runtime.installation,
          instance.agent_uid,
          instance.generation
        )

    grace = if mode == :now, do: 1, else: provider.settings["stopGraceSeconds"]

    with :ok <- Client.delete(provider, "Pod", name, params: [gracePeriodSeconds: grace]),
         {:ok, pod} <- Client.get(provider, "Pod", name) do
      if is_nil(pod), do: Client.delete(provider, "Secret", name), else: :ok
    end
  end

  @impl true
  def pause_instance(_provider, _instance), do: {:error, :pause_not_supported}
  @impl true
  def resume_instance(_provider, _instance), do: {:error, :pause_not_supported}

  @impl true
  def list_instances(provider, agent_uid_or_all) do
    selector = selectors(provider, agent_uid_or_all) ++ [{"ankole.io/task", "worker"}]

    with {:ok, pods} <- Client.list(provider, "Pod", label_selectors: selector),
         {:ok, secrets} <- Client.list(provider, "Secret", label_selectors: selector) do
      pods_by_name = Map.new(pods, &{get_in(&1, ["metadata", "name"]), &1})
      # A Pod remains visible if its Secret was lost. A Secret with no Pod
      # represents a partially created generation and must also be removed.
      objects =
        (pods ++ secrets)
        |> Enum.uniq_by(&get_in(&1, ["metadata", "name"]))
        |> Enum.map(fn resource ->
          worker_object(resource, pods_by_name[get_in(resource, ["metadata", "name"])])
        end)
        |> Enum.filter(&(agent_uid_or_all == :all or &1.agent_uid == agent_uid_or_all))

      if agent_uid_or_all == :all,
        do: {:ok, objects},
        else: {:ok, Enum.map(objects, &diagnostics(provider, &1, pods_by_name[&1.instance_ref]))}
    end
  end

  @impl true
  def current_storage_ref(_provider, _agent_uid), do: {:ok, nil, nil}

  @impl true
  def delete_cache(provider, agent_uid),
    do: delete_claim(provider, agent_uid, storage_name(provider, agent_uid) <> "-cache")

  @impl true
  def delete_storage(provider, agent_uid, storage_ref) do
    with :ok <- delete_cache(provider, agent_uid) do
      case provider.settings["storage"] do
        %{"claimTemplate" => _template} ->
          with :ok <- delete_claim(provider, agent_uid, storage_name(provider, agent_uid)),
               do: {:ok, storage_ref}

        %{"sharedClaim" => _name} ->
          delete_shared_home(provider, agent_uid, storage_ref)
      end
    end
  end

  @doc false
  def pod_manifest(provider, spec, owner) do
    name =
      ProviderKind.instance_name(provider.runtime.installation, spec.agent_uid, spec.generation)

    metadata =
      metadata(provider, spec.agent_uid, name, "worker", owner)
      |> put_in(["labels", "ankole.io/generation"], spec.generation)
      |> put_in(["annotations", "cluster-autoscaler.kubernetes.io/safe-to-evict"], "true")

    env =
      Enum.sort(spec.env)
      |> Enum.map(fn
        {"ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" = key, _token} ->
          %{"name" => key, "valueFrom" => %{"secretKeyRef" => %{"name" => name, "key" => key}}}

        {key, value} ->
          %{"name" => key, "value" => value}
      end)

    {home, home_mount} = home_volume(provider, spec.agent_uid)
    {cache, cache_mount} = cache_volume(provider, spec.agent_uid)
    pod(provider, metadata, spec.image, env, [home, cache], [home_mount, cache_mount])
  end

  @doc false
  def secret_manifest(provider, spec, owner) do
    name =
      ProviderKind.instance_name(provider.runtime.installation, spec.agent_uid, spec.generation)

    %{
      "apiVersion" => "v1",
      "kind" => "Secret",
      "type" => "Opaque",
      "metadata" =>
        metadata(provider, spec.agent_uid, name, "worker", owner)
        |> put_in(["labels", "ankole.io/generation"], spec.generation),
      "stringData" => Map.take(spec.env, ["ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY"])
    }
  end

  defp pod(provider, metadata, image, env, volumes, mounts) do
    spec = provider.settings["podTemplate"]["spec"]
    [worker] = spec["containers"]
    names = MapSet.new(env, & &1["name"])

    env =
      env ++ Enum.reject(Map.get(worker, "env", []), &MapSet.member?(names, &1["name"]))

    worker =
      Map.merge(worker, %{
        "image" => image,
        "env" => env,
        "volumeMounts" => mounts,
        "securityContext" => %{
          "runAsUser" => 0,
          "runAsGroup" => 0,
          "runAsNonRoot" => false,
          "allowPrivilegeEscalation" => false,
          "capabilities" => %{
            "drop" => ["ALL"],
            "add" => ~w(SETUID SETGID CHOWN FOWNER DAC_OVERRIDE KILL)
          },
          "seccompProfile" => %{"type" => "RuntimeDefault"}
        }
      })

    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => metadata,
      "spec" =>
        Map.merge(spec, %{
          "containers" => [worker],
          "volumes" => volumes,
          "restartPolicy" => "Never",
          "automountServiceAccountToken" => false,
          "serviceAccountName" => provider.settings["serviceAccount"],
          "terminationGracePeriodSeconds" => provider.settings["stopGraceSeconds"],
          "securityContext" => %{"fsGroup" => 1000, "fsGroupChangePolicy" => "OnRootMismatch"}
        })
    }
  end

  defp home_volume(provider, agent_uid) do
    case provider.settings["storage"] do
      %{"claimTemplate" => _template} ->
        claim_mount("home", storage_name(provider, agent_uid), "/workspace")

      %{"sharedClaim" => claim} ->
        {volume, mount} = claim_mount("home", claim, "/workspace")
        {volume, Map.put(mount, "subPath", agent_uid)}
    end
  end

  defp cache_volume(provider, agent_uid) do
    case provider.settings["cache"] do
      %{"claimTemplate" => _template} ->
        claim_mount("cache", storage_name(provider, agent_uid) <> "-cache", "/var/cache/ankole")

      cache ->
        {%{"name" => "cache", "emptyDir" => Map.take(cache || %{}, ["sizeLimit"])},
         %{"name" => "cache", "mountPath" => "/var/cache/ankole"}}
    end
  end

  defp claim_mount(name, claim, path),
    do:
      {%{"name" => name, "persistentVolumeClaim" => %{"claimName" => claim}},
       %{"name" => name, "mountPath" => path}}

  defp prepare_home(provider, agent_uid) do
    case provider.settings["storage"] do
      %{"claimTemplate" => template} ->
        ensure_claim(provider, agent_uid, storage_name(provider, agent_uid), template, nil)

      %{"sharedClaim" => name} ->
        case find_claim(provider, name) do
          {:ok, nil} -> {:error, {:kubernetes_shared_claim_missing, name}}
          {:ok, claim} -> claim_available(claim)
          error -> error
        end
    end
  end

  # A PVC spec cannot change after creation. Storage preparation runs while
  # the Agent has no instance, so a cache claim made with other cache settings
  # is replaced here; the cache can be rebuilt. Settings that do not concern
  # the cache keep it.
  defp prepare_cache(provider, agent_uid, owner) do
    name = storage_name(provider, agent_uid) <> "-cache"

    case provider.settings["cache"] do
      %{"claimTemplate" => template} ->
        settings = ProviderKind.hash16(:erlang.term_to_binary(template, [:deterministic]))

        with {:ok, claim} <- find_claim(provider, name),
             :ok <- replace_stale_cache(provider, agent_uid, name, claim, settings) do
          ensure_claim(provider, agent_uid, name, template, owner, %{@cache_settings => settings})
        end

      _empty_dir ->
        delete_claim(provider, agent_uid, name)
    end
  end

  defp replace_stale_cache(provider, agent_uid, name, claim, settings) do
    if claim && get_in(claim, ["metadata", "annotations", @cache_settings]) != settings,
      do: delete_claim(provider, agent_uid, name),
      else: :ok
  end

  defp ensure_claim(provider, agent_uid, name, template, owner, annotations \\ %{}) do
    with {:ok, claim} <- find_claim(provider, name) do
      if claim do
        if owns_storage?(provider, agent_uid, claim) do
          claim_available(claim)
        else
          {:error, {:kubernetes_claim_owner_mismatch, name}}
        end
      else
        metadata =
          update_in(
            metadata(provider, agent_uid, name, "storage", owner)["annotations"],
            &Map.merge(&1, annotations)
          )

        case Client.create(provider, %{
               "apiVersion" => "v1",
               "kind" => "PersistentVolumeClaim",
               "metadata" => metadata,
               "spec" => template
             }) do
          {:ok, _claim} -> :ok
          error -> error
        end
      end
    end
  end

  defp claim_available(%{"metadata" => %{"deletionTimestamp" => _time, "name" => name}}),
    do: {:error, {:kubernetes_claim_deleting, name}}

  defp claim_available(_claim), do: :ok

  defp find_claim(provider, name) do
    with {:ok, claims} <-
           Client.list(provider, "PersistentVolumeClaim",
             field_selectors: [{"metadata.name", name}]
           ),
         do: {:ok, List.first(claims)}
  end

  defp delete_claim(provider, agent_uid, name) do
    with {:ok, claim} <- find_claim(provider, name) do
      cond do
        is_nil(claim) ->
          :ok

        not owns_storage?(provider, agent_uid, claim) ->
          {:error, {:kubernetes_claim_owner_mismatch, name}}

        true ->
          with :ok <- Client.delete(provider, "PersistentVolumeClaim", name),
               {:ok, remaining} <- find_claim(provider, name) do
            if remaining, do: {:error, {:kubernetes_claim_deleting, name}}, else: :ok
          end
      end
    end
  end

  defp delete_shared_home(provider, agent_uid, storage_ref) do
    name = storage_name(provider, agent_uid) <> "-storage"

    with {:ok, helper} <- Client.get(provider, "Pod", name),
         :ok <- check_cleanup_owner(provider, agent_uid, name, helper) do
      case {helper, storage_ref} do
        {nil, _ref} ->
          with {:ok, owner} <- owner_reference(provider),
               {volume, mount} =
                 claim_mount("home", provider.settings["storage"]["sharedClaim"], "/workspace"),
               env = [
                 %{"name" => "WORKER_ID", "value" => agent_uid},
                 %{"name" => "ANKOLE_WORKER_TASK", "value" => "delete_storage"}
               ],
               helper =
                 pod(
                   provider,
                   metadata(provider, agent_uid, name, "storage", owner),
                   provider.runtime.image,
                   env,
                   [volume],
                   [mount]
                 )
                 # Worker probes would restart a long directory deletion.
                 |> update_in(["spec", "containers"], fn [container] ->
                   [Map.drop(container, ~w(livenessProbe readinessProbe startupProbe))]
                 end),
               {:ok, _helper} <- Client.create(provider, helper) do
            {:pending, storage_ref}
          end

        {%{"status" => %{"phase" => "Succeeded"}}, _ref} ->
          with :ok <- Client.delete(provider, "Pod", name, params: [gracePeriodSeconds: 1]),
               do: {:ok, nil}

        {%{"status" => %{"phase" => "Failed"}}, _ref} ->
          reason =
            diagnostics(provider, %{instance_ref: name, reason: pod_reason(helper)}, helper).reason

          with :ok <- Client.delete(provider, "Pod", name, params: [gracePeriodSeconds: 1]),
               do: {:error, {:kubernetes_storage_cleanup_failed, reason}}

        {%{"status" => %{"phase" => "Pending"}}, _ref} ->
          # Show why a cleanup Pod cannot start, for example an unschedulable
          # Pod or a volume that does not mount. The next call checks again.
          reason = pod_reason(helper)
          reason = if starting_reason?(reason), do: nil, else: reason

          case diagnostics(provider, %{instance_ref: name, reason: reason}, helper) do
            %{reason: reason} when is_binary(reason) and reason != "" ->
              {:error, {:kubernetes_storage_cleanup_waiting, reason}}

            _starting ->
              {:pending, storage_ref}
          end

        {_running, _ref} ->
          {:pending, storage_ref}
      end
    end
  end

  defp starting_reason?(nil), do: true

  defp starting_reason?(reason),
    do: String.starts_with?(reason, ["ContainerCreating", "PodInitializing"])

  defp check_cleanup_owner(_provider, _agent_uid, _name, nil), do: :ok

  defp check_cleanup_owner(provider, agent_uid, name, helper) do
    if owns_storage?(provider, agent_uid, helper),
      do: :ok,
      else: {:error, {:kubernetes_storage_cleanup_owner_mismatch, name}}
  end

  defp owns_storage?(provider, agent_uid, resource) do
    expected = Map.new(selectors(provider, agent_uid)) |> Map.put("ankole.io/task", "storage")
    actual = resource["metadata"]

    Map.take(actual["labels"] || %{}, Map.keys(expected)) == expected and
      get_in(actual, ["annotations", "ankole.io/agent-uid"]) == agent_uid
  end

  defp metadata(provider, agent_uid, name, task, owner) do
    %{
      "name" => name,
      "namespace" => provider.settings["namespace"],
      "labels" =>
        Map.new(selectors(provider, agent_uid))
        |> Map.put("ankole.io/task", task)
        |> Map.put("ankole.tenant", Ankole.Repo.tenant_id!()),
      "annotations" => %{"ankole.io/agent-uid" => agent_uid}
    }
    |> maybe_put("ownerReferences", owner && [owner])
  end

  defp selectors(provider, agent_uid_or_all) do
    [
      {"ankole.io/installation", provider.runtime.installation},
      {"ankole.io/provider", provider.provider_id}
    ] ++
      if(agent_uid_or_all == :all,
        do: [],
        else: [{"ankole.io/agent", ProviderKind.hash16(agent_uid_or_all)}]
      )
  end

  defp owner_reference(provider) do
    case provider.settings["ownerConfigMap"] do
      nil ->
        {:ok, nil}

      name ->
        case Client.get(provider, "ConfigMap", name) do
          {:ok, %{"metadata" => %{"uid" => uid}}} ->
            {:ok, %{"apiVersion" => "v1", "kind" => "ConfigMap", "name" => name, "uid" => uid}}

          {:ok, nil} ->
            {:error, {:kubernetes_owner_missing, name}}

          error ->
            error
        end
    end
  end

  defp storage_name(provider, agent_uid),
    do: ProviderKind.storage_name(provider.runtime.installation, agent_uid)

  @doc false
  def worker_object(resource, pod) do
    timestamp =
      (pod && get_in(pod, ["status", "startTime"])) ||
        get_in(resource, ["metadata", "creationTimestamp"])

    {:ok, started_at, _offset} = DateTime.from_iso8601(timestamp)

    %{
      agent_uid: get_in(resource, ["metadata", "annotations", "ankole.io/agent-uid"]),
      generation: get_in(resource, ["metadata", "labels", "ankole.io/generation"]),
      instance_ref: get_in(resource, ["metadata", "name"]),
      started_at: started_at,
      phase: pod_phase(pod),
      instance_present?: not is_nil(pod),
      reason: if(pod, do: pod_reason(pod), else: "Pod is absent; removing its Secret")
    }
  end

  defp pod_phase(nil), do: :exited

  defp pod_phase(pod) do
    cond do
      get_in(pod, ["metadata", "deletionTimestamp"]) ->
        :terminating

      get_in(pod, ["status", "phase"]) in ["Failed", "Succeeded"] ->
        :exited

      Enum.any?(
        get_in(pod, ["status", "containerStatuses"]) || [],
        &get_in(&1, ["state", "waiting"])
      ) ->
        :starting

      get_in(pod, ["status", "phase"]) == "Running" ->
        :running

      true ->
        :starting
    end
  end

  defp pod_reason(pod) do
    statuses = get_in(pod, ["status", "containerStatuses"]) || []
    conditions = get_in(pod, ["status", "conditions"]) || []

    Enum.find_value(statuses, fn status ->
      waiting = get_in(status, ["state", "waiting"])

      terminated =
        get_in(status, ["state", "terminated"]) || get_in(status, ["lastState", "terminated"])

      cond do
        waiting ->
          join_reason([waiting["reason"], waiting["message"]], ": ")

        terminated ->
          "exit code #{terminated["exitCode"]} #{terminated["reason"]}" |> String.trim()

        true ->
          nil
      end
    end) ||
      Enum.find_value(conditions, fn condition ->
        if condition["reason"] == "Unschedulable", do: condition["message"]
      end) || get_in(pod, ["status", "reason"])
  end

  defp diagnostics(provider, object, pod) do
    object =
      if object.reason == nil do
        case Client.list(provider, "Event",
               field_selectors: [
                 {"involvedObject.name", object.instance_ref},
                 {"type", "Warning"}
               ]
             ) do
          {:ok, [_ | _] = events} ->
            newest =
              Enum.max_by(
                events,
                &(&1["lastTimestamp"] || &1["eventTime"] ||
                    get_in(&1, ["metadata", "creationTimestamp"]))
              )

            %{object | reason: join_reason([newest["reason"], newest["message"]])}

          _unavailable ->
            object
        end
      else
        object
      end

    if pod do
      case Client.get(provider, "Pod", object.instance_ref,
             subresource: "log",
             params: [container: "worker", tailLines: 50]
           ) do
        {:ok, body} when is_binary(body) ->
          %{object | reason: join_reason([object.reason, String.trim(body)])}

        _unavailable ->
          object
      end
    else
      object
    end
  end

  defp join_reason(parts, separator \\ "\n"),
    do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(separator)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
