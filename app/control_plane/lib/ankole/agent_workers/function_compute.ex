defmodule Ankole.AgentWorkers.FunctionCompute do
  @moduledoc "Function Compute sandboxes with persistent AgenticFS or OSS storage."
  @behaviour Ankole.AgentWorkers.ProviderKind

  import Ecto.Query
  alias Ankole.Repo
  alias Ankole.AgentWorkers.FunctionCompute.Client
  alias Ankole.AgentWorkers.FunctionCompute.Images
  alias Ankole.AgentWorkers.FunctionCompute.Storage
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.ProviderKind.Definition
  alias Ankole.AgentWorkers.Providers.Configuration, as: C
  alias Ankole.AgentWorkers.AgentWorker

  @impl true
  def definition do
    text = %{"type" => "string", "minLength" => 1}

    common =
      C.common("15m")
      |> put_in(["endpoints", "required"], ~w(runtimeFabricUrl relayOrigin aiGatewayUrl))

    storage =
      C.object(%{
        "agenticFs" =>
          C.object(
            %{
              "fileSystemId" => text,
              "zone" => text,
              "sizeLimitGiB" => %{"type" => "integer", "minimum" => 10, "maximum" => 1_024_000},
              "fileCountLimit" => %{
                "type" => "integer",
                "minimum" => 10_000,
                "maximum" => 100_000_000
              }
            },
            ~w(fileSystemId zone sizeLimitGiB fileCountLimit)
          ),
        "oss" =>
          C.object(
            %{"bucket" => text, "root" => %{"type" => "string", "pattern" => "^/[^.][^\\x00]*$"}},
            ~w(bucket root)
          )
      })
      |> Map.put("oneOf", [%{"required" => ["agenticFs"]}, %{"required" => ["oss"]}])

    schema =
      C.object(
        Map.merge(common, %{
          "region" => C.field(%{"type" => "string", "pattern" => "^[a-z0-9-]+$"}, :location),
          "teamId" => C.field(text, :location),
          "apiDomain" =>
            C.field(%{"type" => "string", "pattern" => "^api\\.[a-z0-9.-]+$"}, :location),
          "storage" => C.field(storage, :location),
          "vpc" =>
            C.field(
              C.object(
                %{
                  "vpcId" => text,
                  "securityGroupId" => text,
                  "vSwitchIds" => %{"type" => "array", "minItems" => 1, "items" => text}
                },
                ~w(vpcId securityGroupId vSwitchIds)
              ),
              :instance
            ),
          "ramRole" => C.field(text, :instance),
          "imageRepository" => C.field(text, :instance),
          "cpus" => C.field(%{"type" => "number", "minimum" => 0.05, "default" => 2}, :instance),
          "memoryMiB" =>
            C.field(%{"type" => "integer", "minimum" => 128, "default" => 4096}, :instance),
          "env" => C.field(C.environment(), :instance)
        }),
        ~w(region teamId apiDomain storage ramRole imageRepository endpoints)
      )
      # AgenticFS mounts need a VPC; OSS mounts do not.
      |> Map.merge(%{
        "if" => %{
          "required" => ["storage"],
          "properties" => %{"storage" => %{"required" => ["agenticFs"]}}
        },
        "then" => %{"required" => ["vpc"]}
      })

    %Definition{
      kind: "function_compute",
      schema: schema,
      credentials: %{
        "apiKey" => %{required: true},
        "accessKeyId" => %{required: true},
        "accessKeySecret" => %{required: true},
        "securityToken" => %{required: false}
      },
      pause: true,
      max_instance_lifetime: 86_400,
      example: """
      # Region, team, API domain, and storage cannot change after creation.
      region: cn-hangzhou
      teamId: team_example
      apiDomain: api.cn-hangzhou.sandbox.aliyuncs.com
      storage:
        agenticFs:
          fileSystemId: fs-example
          zone: cn-hangzhou-h
          sizeLimitGiB: 100
          fileCountLimit: 100000
      # Instance settings. An idle Worker is replaced after a change.
      # AgenticFS storage requires vpc.
      vpc:
        vpcId: vpc-example
        vSwitchIds: [vsw-example]
        securityGroupId: sg-example
      ramRole: acs:ram::123456789:role/ankole-worker
      imageRepository: instance-registry-vpc.cn-hangzhou.cr.aliyuncs.com/ankole/worker
      cpus: 2
      memoryMiB: 4096
      env: {}
      endpoints:
        runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
        relayOrigin: https://ankole.example.com
        aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
      # Lifecycle settings do not replace a Worker.
      stopGraceSeconds: 60
      idleReleaseAfter: 15m
      """
    }
  end

  @impl true
  def check(provider),
    do:
      with(
        {:ok, _} <- Images.list(provider),
        {:ok, _} <- Client.sandboxes(provider, labels(provider)),
        do: :ok
      )

  @impl true
  def prepare_image(provider, image), do: Images.prepare(provider, image)
  @impl true
  def prepare_storage(provider, uid), do: Storage.prepare(provider, uid)
  @impl true
  def delete_storage(provider, uid, ref), do: Storage.delete(provider, uid, ref)
  @impl true
  def current_storage_ref(_provider, _uid), do: {:ok, nil, nil}
  @impl true
  def delete_cache(_provider, _uid), do: :ok

  @impl true
  def create_instance(provider, %{instance_ref: nil} = spec) do
    with {:ok, template} <- Images.selected(provider, spec.image) do
      body =
        create_request(
          provider,
          spec.agent_uid,
          template,
          Map.merge(labels(provider), %{
            "ankole-agent" => ProviderKind.hash16(spec.agent_uid),
            "ankole-generation" => spec.generation,
            "ankole.tenant" => Ankole.Repo.tenant_id!()
          }),
          86_400
        )

      case Client.api(provider, :post, "/sandboxes", json: body) do
        {:ok, %{"sandboxID" => id}} ->
          {:ok, id}

        {:error, {:function_compute_api, status, _, _} = reason}
        when status in [400, 401, 403, 422] ->
          {:rejected, reason}

        error ->
          error
      end
    end
  end

  def create_instance(provider, spec) do
    with {:ok, sandbox} <- get(provider, spec.instance_ref),
         :ok <- owned(provider, sandbox),
         {:ok, _} <-
           Client.file(
             provider,
             sandbox,
             :post,
             "/run/ankole/contract.json",
             Ankole.JSON.encode!(contract(provider, spec))
           ) do
      {:ok, spec.instance_ref}
    end
  end

  @impl true
  def list_instances(provider, uid_or_all) do
    filter =
      if uid_or_all == :all,
        do: labels(provider),
        else: Map.put(labels(provider), "ankole-agent", ProviderKind.hash16(uid_or_all))

    with {:ok, items} <- Client.sandboxes(provider, filter) do
      # Read rows after the platform. A concurrent committed create must not
      # become an orphan because the row snapshot was older than the list.
      query = from w in AgentWorker, where: w.provider_id == ^provider.provider_id

      rows =
        if uid_or_all == :all,
          do: Repo.across_tenants(fn -> Repo.all(query) end),
          else: Repo.all(from w in query, where: w.agent_uid == ^uid_or_all)

      items = Enum.filter(items, &(owned(provider, &1) == :ok))

      with {:ok, missing} <- missing_instances(provider, rows, items, uid_or_all) do
        objects =
          for item <- items ++ missing,
              object = observation(item, rows, uid_or_all),
              not is_nil(object),
              do: object

        {:ok, objects}
      end
    end
  end

  @impl true
  def delete_instance(provider, object, _mode) do
    case Client.api(provider, :delete, instance_path(object.instance_ref)) do
      {:ok, _} -> :ok
      {:error, {:function_compute_api, 404, _, _}} -> :ok
      error -> error
    end
  end

  @impl true
  def pause_instance(provider, object),
    do:
      accepted(
        Client.api(provider, :post, instance_path(object.instance_ref) <> "/pause",
          json: %{memory: true}
        )
      )

  @impl true
  def resume_instance(provider, object) do
    case Client.api(provider, :post, instance_path(object.instance_ref) <> "/connect",
           json: %{timeout: 86_400}
         ) do
      {:ok, sandbox} -> resume_storage(provider, object, sandbox)
      {:error, {:function_compute_api, 404, _, _}} -> {:error, :gone}
      error -> error
    end
  end

  # The resumed Worker rejoins as soon as `connect` returns, so a failed
  # reconnection cannot be retried on this instance: a later reconciliation
  # sees a running, ready Worker. End the instance instead. Home is durable in
  # OSS; the next reconciliation rebuilds the generation from it.
  defp resume_storage(%{settings: %{"storage" => %{"oss" => _}}} = provider, object, sandbox) do
    case Client.restore_oss_connections(provider, sandbox) do
      :ok ->
        :ok

      {:error, reason} ->
        with :ok <- delete_instance(provider, object, :now), do: {:error, reason}
    end
  end

  defp resume_storage(_provider, _object, _sandbox), do: :ok

  def labels(provider),
    do: %{
      "ankole-installation" => provider.runtime.installation,
      "ankole-provider" => provider.provider_id
    }

  def get(provider, id), do: Client.api(provider, :get, instance_path(id))

  def create_request(provider, uid, template, metadata, timeout) do
    mounts = Storage.mounts(provider, uid)

    %{
      "templateID" => template,
      "timeout" => timeout,
      "secure" => true,
      "metadata" => Map.merge(metadata, mounts.metadata)
    }
    |> Map.merge(mounts.body)
  end

  defp contract(provider, spec), do: Map.merge(provider.settings["env"], spec.env)

  defp owned(provider, sandbox) do
    metadata = sandbox["metadata"] || %{}

    if Enum.all?(labels(provider), fn {k, v} -> metadata[k] == v end),
      do: :ok,
      else: {:error, :function_compute_instance_outside_provider}
  end

  defp missing_instances(provider, rows, items, uid) do
    rows
    |> Enum.filter(fn row ->
      (uid == :all or row.agent_uid == uid) and not is_nil(row.instance_ref) and
        not Enum.any?(items, &(&1["sandboxID"] == row.instance_ref))
    end)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case get(provider, row.instance_ref) do
        {:ok, item} ->
          case owned(provider, item) do
            :ok -> {:cont, {:ok, [item | acc]}}
            error -> {:halt, error}
          end

        # The create returned this ID after the sandbox ran. If its first
        # observation finds it gone, report it once so the generation can end.
        {:error, {:function_compute_api, 404, _, _}} when is_nil(row.instance_seen_at) ->
          {:cont, {:ok, [{:ended, row} | acc]}}

        {:error, {:function_compute_api, 404, _, _}} ->
          {:cont, {:ok, acc}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp observation({:ended, row}, _rows, _uid) do
    %{
      agent_uid: row.agent_uid,
      generation: row.generation,
      instance_ref: row.instance_ref,
      phase: :exited,
      reason: "sandbox not found",
      started_at: nil
    }
  end

  defp observation(item, rows, uid) do
    meta = item["metadata"]
    row = Enum.find(rows, &(ProviderKind.hash16(&1.agent_uid) == meta["ankole-agent"]))
    helper? = meta["ankole-task"] == "storage"

    selected_helper? =
      row && get_in(row.storage_ref || %{}, ["task_id"]) == meta["ankole-task-id"]

    cond do
      helper? and (uid != :all or selected_helper?) ->
        nil

      uid != :all and meta["ankole-agent"] != ProviderKind.hash16(uid) ->
        nil

      true ->
        phase =
          cond do
            item["state"] == "paused" -> :paused
            row && row.generation == meta["ankole-generation"] && row.incarnation_id -> :running
            true -> :starting
          end

        {:ok, started, _} = DateTime.from_iso8601(item["endAt"])

        %{
          agent_uid: if(helper?, do: nil, else: if(row, do: row.agent_uid, else: nil)),
          generation: meta["ankole-generation"],
          instance_ref: item["sandboxID"],
          phase: phase,
          reason: nil,
          started_at: if(phase == :paused, do: nil, else: DateTime.add(started, -86_400))
        }
    end
  end

  defp accepted({:ok, _}), do: :ok
  defp accepted(error), do: error
  defp instance_path(id), do: "/sandboxes/" <> Client.path(id)
end
