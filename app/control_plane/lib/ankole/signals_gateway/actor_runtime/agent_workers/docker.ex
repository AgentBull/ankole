defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Docker do
  @moduledoc """
  Docker Engine 1.42 over a local Unix socket.

  Agent Home and cache use separate local named volumes. Removing a
  generation removes only its container. The control plane must observe
  that all containers are gone before it creates another generation.
  """

  @behaviour Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind.Definition
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Configuration, as: C
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap.AgentWorkerSpec

  @api "/v1.42"
  @request_timeout_ms 30_000
  @source_target "/repo/app/agent_computer/src"

  @impl true
  def definition do
    %Definition{
      kind: "docker",
      credentials: %{},
      pause: false,
      schema:
        C.object(
          Map.merge(C.common("15m"), %{
            "socket" =>
              C.field(
                %{"type" => "string", "pattern" => "^/", "default" => "/var/run/docker.sock"},
                :location
              ),
            "network" =>
              C.field(%{"type" => "string", "minLength" => 1, "default" => "bridge"}, :instance),
            "runtime" => C.field(%{"type" => "string", "minLength" => 1}, :instance),
            "cpus" => C.field(%{"type" => "number", "exclusiveMinimum" => 0}, :instance),
            "memoryMiB" => C.field(%{"type" => "integer", "minimum" => 1}, :instance),
            "env" => C.field(C.environment(), :instance)
          })
        ),
      example: """
      # Local Docker Engine; cannot change after creation.
      socket: /var/run/docker.sock
      # Instance settings. An idle Worker is replaced after a change.
      network: ankole_workers
      cpus: 2
      memoryMiB: 4096
      env:
        ANKOLE_MAX_CONCURRENT_SLOTS: "12"
      # Lifecycle settings do not replace a Worker.
      stopGraceSeconds: 60
      idleReleaseAfter: 15m
      """
    }
  end

  @impl true
  def check(provider) do
    case request(provider, :get, "/_ping") do
      {:ok, %{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @impl true
  def prepare_image(provider, image) do
    case request(provider, :get, "/images/#{image}/json") do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 404}} ->
        # The body is a stream of JSON lines with a JSON content type. A
        # failed pull still answers 200 and reports the error in a line.
        case request(provider, :post, "/images/create",
               params: [fromImage: image],
               receive_timeout: 600_000,
               decode_body: false
             ) do
          {:ok, %{status: 200, body: body}} -> pull_result(body)
          other -> error(other)
        end

      other ->
        error(other)
    end
  end

  @impl true
  def prepare_storage(provider, agent_uid) do
    with :ok <- create_volume(provider, agent_uid, storage_name(provider, agent_uid)),
         do: create_volume(provider, agent_uid, storage_name(provider, agent_uid) <> "-cache")
  end

  @impl true
  def create_instance(provider, %AgentWorkerSpec{} = spec) do
    name =
      ProviderKind.instance_name(provider.runtime.installation, spec.agent_uid, spec.generation)

    body = container_body(provider, spec)
    owner_labels = body["Labels"]

    case request(provider, :post, "/containers/create", params: [name: name], json: body) do
      {:ok, %{status: 201}} ->
        start_container(provider, name)

      {:ok, %{status: 409}} ->
        with {:ok, %{status: 200, body: existing}} <-
               request(provider, :get, "/containers/#{name}/json"),
             true <-
               Map.take(get_in(existing, ["Config", "Labels"]) || %{}, Map.keys(owner_labels)) ==
                 owner_labels do
          start_container(provider, name)
        else
          false -> {:rejected, {:docker_container_owner_mismatch, name}}
          other -> error(other)
        end

      {:ok, %{status: status}} = response when status in [400, 404] ->
        {:error, reason} = error(response)
        {:rejected, reason}

      other ->
        error(other)
    end
  end

  defp start_container(provider, name) do
    case request(provider, :post, "/containers/#{name}/start") do
      {:ok, %{status: status}} when status in [204, 304] -> {:ok, nil}
      # The create already succeeded. A start failure cannot reject this generation.
      other -> error(other)
    end
  end

  @impl true
  def delete_instance(provider, instance, :now) do
    signal_and_remove(provider, instance, "SIGKILL")
  end

  def delete_instance(provider, instance, :graceful) do
    signal_and_remove(provider, instance, "SIGTERM")
  end

  defp signal_and_remove(provider, instance, signal) do
    name = instance_name(provider, instance)

    case request(provider, :post, "/containers/#{name}/kill", params: [signal: signal]) do
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 404}} -> :ok
      # Engine 1.42 defines this status as "container is not running".
      {:ok, %{status: 409}} -> remove_container(provider, name)
      other -> error(other)
    end
  end

  @impl true
  def pause_instance(_provider, _instance), do: {:error, :pause_not_supported}
  @impl true
  def resume_instance(_provider, _instance), do: {:error, :pause_not_supported}

  @impl true
  def list_instances(provider, agent_uid_or_all) do
    labels =
      [
        "ankole.worker=1",
        "ankole.installation=#{provider.runtime.installation}",
        "ankole.provider=#{provider.provider_id}"
      ] ++
        if(agent_uid_or_all == :all, do: [], else: ["ankole.agent-uid=#{agent_uid_or_all}"])

    case request(provider, :get, "/containers/json",
           params: [all: true, filters: Ankole.JSON.encode!(%{"label" => labels})]
         ) do
      {:ok, %{status: 200, body: containers}} when is_list(containers) ->
        objects = Enum.map(containers, &worker_object/1)

        if agent_uid_or_all == :all,
          do: {:ok, objects},
          else: {:ok, Enum.map(objects, &with_log_tail(provider, &1))}

      other ->
        error(other)
    end
  end

  @impl true
  def current_storage_ref(_provider, _agent_uid), do: {:ok, nil, nil}

  @impl true
  def delete_cache(provider, agent_uid),
    do: delete_volume(provider, agent_uid, storage_name(provider, agent_uid) <> "-cache")

  @impl true
  def delete_storage(provider, agent_uid, storage_ref) do
    with :ok <- delete_volume(provider, agent_uid, storage_name(provider, agent_uid)),
         :ok <- delete_cache(provider, agent_uid),
         do: {:ok, storage_ref}
  end

  @doc false
  def container_body(provider, %AgentWorkerSpec{} = spec) do
    settings = provider.settings
    runtime = provider.runtime

    env =
      settings["env"]
      |> Map.merge(spec.env)
      |> then(fn env ->
        if runtime.internal_skills_root,
          do: Map.put(env, "ANKOLE_INTERNAL_SKILLS_ROOT", WorkerBootstrap.internal_skills_root()),
          else: env
      end)

    name = storage_name(provider, spec.agent_uid)

    mounts =
      [
        %{"Type" => "volume", "Source" => name, "Target" => "/workspace"},
        %{"Type" => "volume", "Source" => name <> "-cache", "Target" => "/var/cache/ankole"},
        bind(runtime.source_root, @source_target),
        bind(runtime.internal_skills_root, WorkerBootstrap.internal_skills_root())
      ]
      |> Enum.reject(&is_nil/1)

    host_config =
      %{
        "SecurityOpt" => ["no-new-privileges"],
        "ExtraHosts" => ["host.docker.internal:host-gateway"],
        "NetworkMode" => settings["network"],
        "RestartPolicy" => %{"Name" => "no"},
        "Mounts" => mounts
      }
      |> maybe_put("Memory", settings["memoryMiB"] && settings["memoryMiB"] * 1_048_576)
      |> maybe_put("NanoCpus", settings["cpus"] && round(settings["cpus"] * 1_000_000_000))
      |> maybe_put("Runtime", settings["runtime"])

    %{
      "Image" => spec.image,
      "User" => "0:0",
      "Env" => env |> Enum.sort() |> Enum.map(fn {key, value} -> "#{key}=#{value}" end),
      "Labels" =>
        labels(provider, spec.agent_uid)
        |> Map.put("ankole.tenant", Ankole.Repo.tenant_id!())
        |> Map.merge(%{"ankole.worker" => "1", "ankole.generation" => spec.generation}),
      "HostConfig" => host_config
    }
    |> then(fn body ->
      if runtime.source_root,
        do: Map.put(body, "Cmd", ["bun", "--watch", "src/main.ts"]),
        else: body
    end)
  end

  defp create_volume(provider, agent_uid, name) do
    case request(provider, :post, "/volumes/create",
           json: %{
             "Name" => name,
             "Driver" => "local",
             "Labels" =>
               Map.put(labels(provider, agent_uid), "ankole.tenant", Ankole.Repo.tenant_id!())
           }
         ) do
      {:ok, %{status: 201, body: volume}} ->
        owned_local_volume(provider, agent_uid, name, volume)

      other ->
        error(other)
    end
  end

  defp delete_volume(provider, agent_uid, name) do
    case request(provider, :get, "/volumes/#{name}") do
      {:ok, %{status: 404}} ->
        :ok

      {:ok, %{status: 200, body: volume}} ->
        with :ok <- owned_local_volume(provider, agent_uid, name, volume) do
          case request(provider, :delete, "/volumes/#{name}") do
            {:ok, %{status: status}} when status in [204, 404] -> :ok
            other -> error(other)
          end
        end

      other ->
        error(other)
    end
  end

  defp owned_local_volume(provider, agent_uid, name, volume) do
    expected = labels(provider, agent_uid)

    cond do
      volume["Driver"] != "local" or volume["Options"] not in [nil, %{}] ->
        {:error, {:docker_volume_not_local, name}}

      Map.take(volume["Labels"] || %{}, Map.keys(expected)) != expected ->
        {:error, {:docker_volume_owner_mismatch, name}}

      true ->
        :ok
    end
  end

  defp remove_container(provider, name) do
    case request(provider, :delete, "/containers/#{name}", params: [force: false]) do
      {:ok, %{status: status}} when status in [204, 404] -> :ok
      other -> error(other)
    end
  end

  defp storage_name(provider, agent_uid),
    do: ProviderKind.storage_name(provider.runtime.installation, agent_uid)

  defp instance_name(provider, instance),
    do:
      instance.instance_ref ||
        ProviderKind.instance_name(
          provider.runtime.installation,
          instance.agent_uid,
          instance.generation
        )

  defp labels(provider, agent_uid),
    do: %{
      "ankole.installation" => provider.runtime.installation,
      "ankole.provider" => provider.provider_id,
      "ankole.agent-uid" => agent_uid
    }

  defp bind(nil, _target), do: nil

  defp bind(source, target),
    do: %{"Type" => "bind", "Source" => source, "Target" => target, "ReadOnly" => true}

  defp worker_object(container) do
    labels = container["Labels"]

    %{
      agent_uid: labels["ankole.agent-uid"],
      generation: labels["ankole.generation"],
      instance_ref: container["Id"],
      phase: phase(container["State"]),
      reason: container["Status"],
      started_at: DateTime.from_unix!(container["Created"])
    }
  end

  defp phase(state) when state in ["created", "restarting"], do: :starting
  defp phase("running"), do: :running
  defp phase("paused"), do: :paused
  defp phase("removing"), do: :terminating
  defp phase(state) when state in ["exited", "dead"], do: :exited

  defp with_log_tail(provider, object) do
    case request(provider, :get, "/containers/#{object.instance_ref}/logs",
           params: [stdout: true, stderr: true, tail: 50],
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        lines = body |> demultiplex() |> IO.iodata_to_binary() |> String.trim()

        %{
          object
          | reason: Enum.join(Enum.reject([object.reason, lines], &(&1 in [nil, ""])), "\n")
        }

      _unavailable ->
        object
    end
  end

  # Non-TTY output has an eight-byte header before each stdout/stderr frame.
  @doc false
  def demultiplex(<<_stream, 0, 0, 0, size::32, payload::binary-size(size), rest::binary>>),
    do: [payload | demultiplex(rest)]

  def demultiplex(<<>>), do: []
  def demultiplex(raw), do: [raw]

  defp pull_result(body) do
    Enum.reduce_while(String.split(body, "\n", trim: true), :ok, fn line, :ok ->
      case Ankole.JSON.decode(line) do
        {:ok, %{"error" => message}} -> {:halt, {:error, {:docker_pull_failed, message}}}
        {:ok, _progress} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:docker_pull_response, reason}}}
      end
    end)
  end

  defp request(provider, method, path, opts \\ []) do
    Req.request(
      Keyword.merge(
        [
          method: method,
          base_url: "http://docker" <> @api,
          url: path,
          unix_socket: provider.settings["socket"],
          receive_timeout: @request_timeout_ms,
          retry: false,
          decode_body: true
        ],
        opts
      )
      |> Keyword.merge(Application.get_env(:ankole, :docker_api_req_options, []))
    )
  end

  defp error({:ok, %{status: status, body: body}}),
    do: {:error, {:docker_api, status, body_message(body)}}

  defp error({:error, reason}), do: {:error, {:docker_unreachable, reason}}
  defp body_message(%{"message" => message}), do: message
  defp body_message(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp body_message(body), do: inspect(body)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
