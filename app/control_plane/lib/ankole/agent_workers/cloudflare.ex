defmodule Ankole.AgentWorkers.Cloudflare do
  @moduledoc """
  Cloudflare Containers through the AgentWorker Durable Object adapter.

  The adapter backs up Agent Home to R2 after all Worker processes exit.
  Reconciliation commits the backup record through `current_storage_ref/2`
  before it makes the row absent. A new instance receives that committed ref.
  """

  @behaviour Ankole.AgentWorkers.ProviderKind

  alias Ankole.AgentWorkers.ProviderKind.Definition
  alias Ankole.AgentWorkers.Providers.Configuration, as: C

  @impl true
  def definition do
    common =
      C.common("15m", 300)
      |> put_in(["endpoints", "required"], ~w(runtimeFabricUrl relayOrigin aiGatewayUrl))

    %Definition{
      kind: "cloudflare",
      credentials: %{"adapterToken" => %{required: true}},
      pause: false,
      schema:
        C.object(
          Map.merge(common, %{
            "adapterUrl" =>
              C.field(%{"type" => "string", "pattern" => "^https://[^/]+"}, :location),
            "instance" =>
              C.field(
                %{
                  "default" => "standard-3",
                  "oneOf" => [
                    %{"enum" => ~w(lite standard-1 standard-2 standard-3 standard-4)},
                    C.object(
                      %{
                        "cpus" => positive("number"),
                        "memoryMiB" => positive("integer"),
                        "diskMB" => positive("integer")
                      },
                      ~w(cpus memoryMiB diskMB)
                    )
                  ]
                },
                :instance
              ),
            "env" => C.field(C.environment(), :instance)
          }),
          ~w(adapterUrl endpoints)
        ),
      example: """
      # Adapter and R2 storage location; cannot change after creation.
      adapterUrl: https://ankole-agent-workers.example.workers.dev
      # Instance settings. The disk must also hold Agent Home after restore.
      instance: standard-3
      env: {}
      endpoints:
        runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
        relayOrigin: https://ankole.example.com
        aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
      # Allow time for drain and directory backup.
      stopGraceSeconds: 300
      idleReleaseAfter: 15m
      """
    }
  end

  @impl true
  def check(provider) do
    case request(provider, :get, "/health") do
      {:ok, %{status: 200}} -> :ok
      other -> error(other)
    end
  end

  @impl true
  def prepare_image(provider, image) do
    case request(provider, :get, "/health") do
      {:ok, %{status: 200, body: %{"images" => images}}} ->
        if image in images, do: :ok, else: {:error, {:cloudflare_image_not_deployed, image}}

      other ->
        error(other)
    end
  end

  @impl true
  def prepare_storage(_provider, _agent_uid), do: :ok

  @impl true
  def create_instance(provider, spec) do
    env =
      provider.settings["env"]
      |> Map.merge(spec.env)
      |> Map.merge(%{
        "ANKOLE_WORKER_STORAGE" => "adapter",
        "ANKOLE_WORKER_ADAPTER_URL" => provider.settings["adapterUrl"]
      })

    body = %{
      provider_id: provider.provider_id,
      generation: spec.generation,
      image: spec.image,
      env: env,
      instance: instance(provider.settings["instance"]),
      storage_ref: spec.storage_ref
    }

    # The platform can pull a cold image before it sets the idle timeout.
    case request(provider, :put, worker_path(provider, spec.agent_uid),
           json: body,
           receive_timeout: :timer.minutes(5)
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        {:ok, nil}

      {:ok, %{status: status}} = response when status in [400, 401, 403, 422] ->
        {:error, reason} = error(response)
        {:rejected, reason}

      other ->
        error(other)
    end
  end

  @impl true
  def delete_instance(provider, instance, mode) do
    body = %{
      provider_id: provider.provider_id,
      generation: instance.generation,
      mode: mode,
      grace_seconds: provider.settings["stopGraceSeconds"]
    }

    case request(provider, :delete, worker_path(provider, instance.tenant_id, instance.agent_uid),
           json: body
         ) do
      {:ok, %{status: status}} when status in [200, 202, 404] -> :ok
      other -> error(other)
    end
  end

  @impl true
  def pause_instance(_provider, _instance), do: {:error, :pause_not_supported}
  @impl true
  def resume_instance(_provider, _instance), do: {:error, :pause_not_supported}

  @impl true
  def list_instances(provider, :all) do
    case request(provider, :get, "/workers", params: [provider_id: provider.provider_id]) do
      {:ok, %{status: 200, body: %{"workers" => workers}}} ->
        {:ok, Enum.map(workers, &observation/1)}

      other ->
        error(other)
    end
  end

  def list_instances(provider, agent_uid) do
    case request(provider, :get, worker_path(provider, agent_uid),
           params: [provider_id: provider.provider_id]
         ) do
      {:ok, %{status: 200, body: worker}} -> {:ok, [observation(worker)]}
      {:ok, %{status: 404}} -> {:ok, []}
      other -> error(other)
    end
  end

  @impl true
  def current_storage_ref(provider, agent_uid) do
    case request(provider, :get, storage_path(provider, agent_uid),
           params: [provider_id: provider.provider_id]
         ) do
      {:ok, %{status: 200, body: %{"storage_ref" => ref, "reason" => reason}}} ->
        {:ok, ref, reason}

      other ->
        error(other)
    end
  end

  @impl true
  def delete_cache(_provider, _agent_uid), do: :ok

  @impl true
  def delete_storage(provider, agent_uid, _storage_ref) do
    case request(provider, :delete, storage_path(provider, agent_uid),
           params: [provider_id: provider.provider_id]
         ) do
      {:ok, %{status: 200}} -> {:ok, nil}
      other -> error(other)
    end
  end

  defp positive(type), do: %{"type" => type, "exclusiveMinimum" => 0}

  defp instance(%{"cpus" => cpu, "memoryMiB" => memory, "diskMB" => disk}),
    do: %{vcpu: cpu, memoryMib: memory, diskMb: disk}

  defp instance(name), do: name

  defp observation(worker) do
    {:ok, started_at, _offset} = DateTime.from_iso8601(worker["started_at"])

    %{
      tenant_id: worker["tenant_id"],
      agent_uid: worker["agent_uid"],
      generation: worker["generation"],
      instance_ref: nil,
      phase: phase(worker["phase"]),
      reason: worker["reason"],
      started_at: started_at
    }
  end

  defp phase("starting"), do: :starting
  defp phase("running"), do: :running
  defp phase("terminating"), do: :terminating

  defp worker_path(provider, agent_uid),
    do: worker_path(provider, Ankole.Repo.tenant_id!(), agent_uid)

  defp worker_path(provider, tenant_id, agent_uid),
    do: "/agents/" <> storage_key(provider, tenant_id, agent_uid) <> "/worker"

  defp storage_path(provider, agent_uid),
    do: "/agents/" <> storage_key(provider, Ankole.Repo.tenant_id!(), agent_uid) <> "/storage"

  defp storage_key(provider, tenant_id, agent_uid),
    do:
      "ankole-#{provider.runtime.installation}-#{Ankole.AgentWorkers.ProviderKind.agent_hash(tenant_id, agent_uid)}"

  defp request(provider, method, path, opts \\ []) do
    [
      base_url: provider.settings["adapterUrl"],
      auth: {:bearer, provider.secrets["adapterToken"]},
      retry: false,
      receive_timeout: 30_000
    ]
    |> Keyword.merge(Application.get_env(:ankole, :cloudflare_adapter_req_options, []))
    |> Req.new()
    |> Req.request([method: method, url: path] ++ opts)
  end

  defp error({:ok, %{status: status, body: %{"error" => code} = body}}),
    do: {:error, {:cloudflare_adapter, status, code, body["message"]}}

  defp error({:ok, %{status: status, body: body}}),
    do: {:error, {:cloudflare_adapter, status, inspect(body) |> String.slice(0, 500)}}

  defp error({:error, reason}), do: {:error, {:cloudflare_adapter_unreachable, reason}}
end
