defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Lambda do
  @moduledoc "Lambda MicroVMs with one persistent Agent directory on shared EFS."
  @behaviour Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind

  import Ecto.Query
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Lambda.{Client, Images}
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind.Definition
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Configuration, as: C
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  # One object sweep interval (SweepJob runs it every five minutes).
  @orphan_age_seconds 300

  @impl true
  def definition do
    common =
      C.common("15m", 50)
      |> put_in(["endpoints", "required"], ~w(runtimeFabricUrl relayOrigin aiGatewayUrl))
      |> put_in(["stopGraceSeconds", "maximum"], 59)

    %Definition{
      kind: "lambda",
      credentials:
        Map.new(~w(accessKeyId secretAccessKey sessionToken), &{&1, %{required: false}}),
      pause: true,
      max_instance_lifetime: 28_800,
      schema:
        C.object(
          Map.merge(common, %{
            "region" =>
              C.field(
                %{"type" => "string", "pattern" => "^[a-z]{2}(-[a-z]+)+-[0-9]+$"},
                :location
              ),
            "efs" =>
              C.field(
                C.object(
                  %{
                    "address" => %{"type" => "string", "pattern" => "^[a-zA-Z0-9.-]+$"},
                    "root" => %{
                      "type" => "string",
                      "pattern" => "^/"
                    }
                  },
                  ~w(address root)
                ),
                :location
              ),
            "networkConnectorArn" =>
              C.field(
                %{
                  "type" => "string",
                  "pattern" =>
                    "^arn:aws:lambda:[^:]+:[0-9]{12}:network-connector:[a-zA-Z0-9_-]+(:[1-9][0-9]*)?$"
                },
                :instance
              ),
            "buildBucket" =>
              C.field(
                %{"type" => "string", "pattern" => "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"},
                :lifecycle
              ),
            "buildRoleArn" =>
              C.field(
                %{"type" => "string", "pattern" => "^arn:aws:iam::[0-9]{12}:role/.+"},
                :lifecycle
              ),
            "memoryMiB" => C.field(%{"enum" => [4096, 8192], "default" => 4096}, :instance),
            # The image has at most 50 variables; the entry point sets three.
            "env" => C.field(Map.put(C.environment(), "maxProperties", 47), :instance)
          }),
          ~w(region efs networkConnectorArn buildBucket buildRoleArn endpoints)
        ),
      example: """
      # Region and EFS location cannot change after creation.
      region: us-east-1
      efs:
        address: fs-0123456789abcdef0.efs.us-east-1.amazonaws.com
        root: /ankole-agents
      # Instance settings. An idle Worker is replaced after a change.
      networkConnectorArn: arn:aws:lambda:us-east-1:123456789012:network-connector:worker-vpc
      memoryMiB: 4096
      env: {}
      endpoints:
        runtimeFabricUrl: wss://ankole.example.com/runtime-fabric/worker
        relayOrigin: https://ankole.example.com
        aiGatewayUrl: https://ankole.example.com/api/v1/ai-gateway
      # Image builds use this bucket and role. Lifecycle settings do not
      # replace a Worker.
      buildBucket: ankole-microvm-builds
      buildRoleArn: arn:aws:iam::123456789012:role/AnkoleMicrovmBuild
      stopGraceSeconds: 50
      idleReleaseAfter: 15m
      """
    }
  end

  @impl true
  def validate_credentials(_settings, secrets) when map_size(secrets) > 0 do
    if is_binary(secrets["accessKeyId"]) and is_binary(secrets["secretAccessKey"]),
      do: :ok,
      else:
        {:error,
         {:invalid_worker_provider_credentials,
          "accessKeyId and secretAccessKey are required together; sessionToken is optional"}}
  end

  def validate_credentials(_settings, _secrets), do: :ok

  @impl true
  def check(provider), do: with({:ok, _} <- Images.owned(provider, "worker"), do: :ok)

  @impl true
  def prepare_image(provider, image),
    do: Images.prepare(%{provider | runtime: %{provider.runtime | image: image}}, "worker")

  @impl true
  def prepare_storage(_provider, _uid), do: :ok

  @impl true
  def create_instance(provider, spec) do
    # Only a retry can have an earlier VM with a lost create response.
    # clientToken does not prove identity forever, so inspect possible owners.
    with :ok <- check_create_retry(provider, spec),
         {:ok, image} <- Images.selected(provider, "worker") do
      env = image["environmentVariables"]

      # The run hook accepts exactly these keys; the image supplies Skill roots.
      contract =
        spec.env
        |> Map.take(~w(WORKER_ID ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY))
        |> Map.merge(%{
          "ANKOLE_RUNTIME_FABRIC_ENDPOINT" => env["ANKOLE_RUNTIME_FABRIC_ENDPOINT"],
          "ANKOLE_WORKER_STORAGE" => "nfs",
          "ANKOLE_WORKER_NFS_SOURCE" => nfs_source(provider)
        })

      with {:ok, body} <-
             run_request(image, contract, token({spec.agent_uid, spec.generation}), 28_800) do
        case Client.request(provider, :post, "/microvms", body) do
          {:ok, %{"microvmId" => id}} ->
            {:ok, id}

          {:error, {:lambda_api, status, code} = reason}
          when status in [400, 403] and code in ~w(AccessDeniedException ValidationException) ->
            {:rejected, reason}

          error ->
            error
        end
      end
    end
  end

  @impl true
  def list_instances(provider, :all) do
    # The sweep needs the live VMs and their owners only. Saved references of
    # VMs that the list no longer shows are checked per Agent.
    with {:ok, instances} <- listed(provider) do
      refs = Map.new(rows(provider), &{&1.instance_ref, &1})

      {:ok,
       for instance <- instances, instance["state"] != "TERMINATED" do
         observe(instance, refs[instance["microvmId"]])
       end}
    end
  end

  def list_instances(provider, uid) do
    with {:ok, instances} <- listed(provider) do
      # Only this Agent's references are checked, so one bad row cannot stop
      # the other Agents on the provider.
      worker = Enum.find(rows(provider), &(&1.agent_uid == uid))
      ref = worker && worker.instance_ref

      with {:ok, instances} <- saved_instance(provider, worker, ref, instances) do
        {:ok,
         for instance <- instances,
             ref != nil and instance["microvmId"] == ref,
             instance["state"] != "TERMINATED" or is_nil(worker.instance_seen_at) do
           observe(instance, worker)
         end}
      end
    end
  end

  @impl true
  def delete_instance(provider, %{agent_uid: nil} = instance, _mode) do
    # A create saves its reference within seconds of RunMicrovm. A VM that is
    # still unattributed one sweep later is an orphan. If this deletes a VM
    # whose reference commits later, that Agent sees its VM end and starts a
    # new generation; two writers cannot result.
    if young?(instance) do
      :ok
    else
      with {:ok, state} <- get(provider, instance.instance_ref) do
        assigned? = Enum.any?(rows(provider), &(&1.instance_ref == instance.instance_ref))

        if assigned? or state["state"] == "TERMINATED",
          do: :ok,
          else: accepted(Client.request(provider, :delete, instance_path(instance.instance_ref)))
      end
    end
  end

  def delete_instance(provider, instance, _mode) do
    with {:ok, state} <- get(provider, instance.instance_ref) do
      if state["state"] == "TERMINATED",
        do: :ok,
        else: accepted(Client.request(provider, :delete, instance_path(instance.instance_ref)))
    end
  end

  @impl true
  def pause_instance(provider, instance) do
    with {:ok, state} <- get(provider, instance.instance_ref) do
      cond do
        state["state"] == "TERMINATED" ->
          {:error, :gone}

        state["state"] in ~w(SUSPENDING SUSPENDED) ->
          :ok

        true ->
          accepted(
            Client.request(
              provider,
              :post,
              instance_path(instance.instance_ref) <> "/suspend",
              %{}
            )
          )
      end
    end
  end

  @impl true
  def resume_instance(provider, instance) do
    with {:ok, state} <- get(provider, instance.instance_ref) do
      cond do
        state["state"] == "TERMINATED" ->
          {:error, :gone}

        state["state"] in ~w(PENDING RUNNING) ->
          :ok

        true ->
          accepted(
            Client.request(
              provider,
              :post,
              instance_path(instance.instance_ref) <> "/resume",
              %{}
            )
          )
      end
    end
  end

  @impl true
  def current_storage_ref(_provider, _uid), do: {:ok, nil, nil}

  @impl true
  def delete_cache(_provider, _uid), do: :ok

  @impl true
  def delete_storage(provider, uid, nil), do: start_storage_deletion(provider, uid, nil)

  def delete_storage(provider, uid, %{"previousMicrovmId" => _id} = ref),
    do: start_storage_deletion(provider, uid, ref)

  def delete_storage(provider, _uid, %{"microvmId" => id} = ref) do
    with {:ok, state} <- get(provider, id) do
      cond do
        # The image run hook waits for entry-ready, which delete_storage writes
        # only after it removes the Agent directory and prior deletion debris.
        state["state"] == "RUNNING" ->
          with :ok <- accepted(Client.request(provider, :delete, instance_path(id))),
               do: {:ok, nil}

        state["state"] == "TERMINATED" ->
          {:pending, %{"previousMicrovmId" => id}}

        true ->
          {:pending, ref}
      end
    end
  end

  defp start_storage_deletion(provider, uid, ref) do
    client_token =
      token(
        if ref, do: {uid, :delete_storage, ref["previousMicrovmId"]}, else: {uid, :delete_storage}
      )

    with :ok <- Images.prepare(provider, "storage"),
         {:ok, image} <- Images.selected(provider, "storage"),
         {:ok, request} <-
           run_request(
             image,
             %{
               "WORKER_ID" => uid,
               "ANKOLE_WORKER_STORAGE" => "nfs",
               "ANKOLE_WORKER_NFS_SOURCE" => nfs_source(provider)
             },
             client_token,
             3600
           ),
         {:ok, %{"microvmId" => id}} <- Client.request(provider, :post, "/microvms", request) do
      {:pending, %{"microvmId" => id}}
    else
      {:pending, _reason} -> {:pending, ref}
      error -> error
    end
  end

  defp run_request(image, contract, client_token, duration) do
    # runHookPayload is a string to AWS. Keep its bytes stable across retries.
    payload =
      "{" <>
        Enum.map_join(Enum.sort(contract), ",", fn {key, value} ->
          Ankole.JSON.encode!(key) <> ":" <> Ankole.JSON.encode!(value)
        end) <> "}"

    if byte_size(payload) <= 4096 do
      {:ok,
       %{
         "imageIdentifier" => image["imageArn"],
         "egressNetworkConnectors" => image["egressNetworkConnectors"],
         "clientToken" => client_token,
         "maximumDurationInSeconds" => duration,
         "idlePolicy" => %{
           "autoResumeEnabled" => false,
           "maxIdleDurationSeconds" => duration,
           "suspendedDurationSeconds" => duration
         },
         "runHookPayload" => payload
       }}
    else
      {:error, :lambda_run_hook_payload_too_large}
    end
  end

  defp listed(provider) do
    with {:ok, images} <- Images.owned(provider, "worker"),
         do: collect(images, &Client.list(provider, "/microvms", imageIdentifier: &1["imageArn"]))
  end

  defp rows(provider),
    do:
      Repo.across_tenants(fn ->
        Repo.all(from w in AgentWorker, where: w.provider_id == ^provider.provider_id)
      end)

  defp check_create_retry(_provider, %{create_retry?: false}), do: :ok

  defp check_create_retry(provider, %{create_retry?: true, create_sent_at: sent_at}) do
    with {:ok, instances} <- listed(provider), do: no_orphans(provider, instances, sent_at)
  end

  defp no_orphans(provider, instances, sent_at) do
    refs = MapSet.new(rows(provider), & &1.instance_ref)
    earliest = DateTime.to_unix(sent_at, :microsecond) / 1_000_000 - 60

    if Enum.any?(
         instances,
         &(&1["state"] != "TERMINATED" and not MapSet.member?(refs, &1["microvmId"]) and
             (is_nil(&1["startedAt"]) or &1["startedAt"] >= earliest))
       ),
       do: {:error, :lambda_waiting_for_provider_orphans},
       else: :ok
  end

  # The list does not show a terminated VM after some time. Read the saved
  # reference directly. Right after RunMicrovm a read can still return 404,
  # so a 404 ends only a VM that was observed before.
  defp saved_instance(_provider, _worker, nil, instances), do: {:ok, instances}

  defp saved_instance(provider, worker, ref, instances) do
    if Enum.any?(instances, &(&1["microvmId"] == ref)) do
      {:ok, instances}
    else
      case get(provider, ref) do
        {:ok, instance} ->
          {:ok, [instance | instances]}

        {:error, {:lambda_api, 404, _code}} when not is_nil(worker.instance_seen_at) ->
          {:ok, instances}

        error ->
          error
      end
    end
  end

  defp get(provider, id), do: Client.request(provider, :get, instance_path(id))

  defp young?(%{started_at: %DateTime{} = started_at}),
    do: DateTime.diff(DateTime.utc_now(), started_at, :second) < @orphan_age_seconds

  defp young?(_instance), do: true

  defp observe(instance, worker) do
    %{
      agent_uid: worker && worker.agent_uid,
      generation: worker && worker.generation,
      instance_ref: instance["microvmId"],
      phase: phase(instance["state"]),
      reason: instance["stateReason"],
      started_at:
        instance["startedAt"] &&
          DateTime.from_unix!(round(instance["startedAt"] * 1000), :millisecond)
    }
  end

  defp phase("PENDING"), do: :starting
  defp phase(state) when state in ~w(RUNNING SUSPENDING), do: :running
  defp phase("SUSPENDED"), do: :paused
  defp phase("TERMINATING"), do: :terminating
  defp phase("TERMINATED"), do: :exited
  defp instance_path(id), do: "/microvms/" <> Client.path(id)

  defp nfs_source(provider),
    do: provider.settings["efs"]["address"] <> ":" <> provider.settings["efs"]["root"]

  defp accepted({:ok, _}), do: :ok
  defp accepted(error), do: error

  defp token(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        error -> {:halt, error}
      end
    end)
  end
end
