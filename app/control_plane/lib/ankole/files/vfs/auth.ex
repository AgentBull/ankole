defmodule Ankole.Files.Vfs.Auth do
  @moduledoc "Seals the runtime's existing disclosure context for one Worker incarnation."
  alias Ankole.{AgentWorkers, Brain, Kernel, Repo, SecretKeyBase}
  alias Ankole.AuthZ.Actor
  alias Ankole.BackgroundAgentJobs.RuntimeProjection

  def runtime_config(agent_uid, signal_id) do
    case AgentWorkers.get_agent_worker(agent_uid) do
      {:ok, %{capacity: %{"drive_vfs" => true}}} -> mounted_config(agent_uid, signal_id)
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  defp mounted_config(agent_uid, signal_id) do
    # A Drive mount outlives the request that configured it, and every
    # control-plane node serves the DAV path, so the endpoint must not name the
    # node that issues it.
    with {:ok, config} <- issue(agent_uid, %{"signal_id" => signal_id}),
         {:ok, endpoints} <- AgentWorkers.Providers.connection_endpoints(agent_uid),
         {:ok, origin} <- AgentWorkers.Providers.control_plane_origin(endpoints) do
      {:ok,
       struct(
         Ankole.RuntimeFabric.V1.DriveVfsConfig,
         Map.merge(config, %{
           endpoint: origin <> "/api/v1/vfs/dav",
           conversation_id: config.conversation_id || ""
         })
       )}
    end
  end

  def refresh(payload, library_only \\ false) do
    Repo.transact_top_level(fn ->
      with {:ok, _} <- context_in_tx(payload, library_only),
           do:
             SecretKeyBase.seal(
               Torque.encode!(Map.put(payload, "expires_at", System.system_time(:second) + 3600)),
               "drive.vfs",
               []
             )
    end)
  end

  def issue(agent_uid, metadata) do
    signal_id = Brain.RequestContext.signal_id(metadata)

    with {:ok, context} <- Brain.RequestContext.build(agent_uid, metadata),
         {:ok, projection} <- RuntimeProjection.for_signal(agent_uid, signal_id),
         {:ok, worker} when not is_nil(worker) <- AgentWorkers.get_agent_worker(agent_uid),
         true <- is_binary(worker.incarnation_id) do
      # The bearer token must fit in one HTTP header, so a Job's token names its
      # Signal and each request rereads the Job's frozen Skill selection.
      payload = %{
        "tenant_id" => Repo.tenant_id!(),
        "job_signal_id" => if(projection, do: signal_id),
        "agent_uid" => agent_uid,
        "disclosure" => context.disclosure,
        "conversation_id" => context.conversation_id,
        "generation" => worker.generation,
        "incarnation" => worker.incarnation_id,
        "expires_at" => System.system_time(:second) + 3600
      }

      scope = scope_key(payload, projection)

      with {:ok, token} <- SecretKeyBase.seal(Torque.encode!(payload), "drive.vfs", []) do
        {:ok,
         %{
           token: token,
           scope: scope,
           library_scope:
             Kernel.vfs_fingerprint(Torque.encode!([payload["tenant_id"], agent_uid, projection])),
           view: Kernel.vfs_fingerprint(Torque.encode!([scope, payload["conversation_id"]])),
           conversation_id: context.conversation_id
         }}
      end
    else
      false -> {:error, :worker_not_connected}
      {:ok, nil} -> {:error, :worker_not_connected}
      error -> error
    end
  end

  def decode(token, opts \\ []) do
    with {:ok, json} <- SecretKeyBase.unseal(token, "drive.vfs", []),
         {:ok, payload} <- Torque.decode(json),
         true <-
           is_integer(payload["expires_at"]) &&
             (Keyword.get(opts, :refresh, false) ||
                payload["expires_at"] > System.system_time(:second)),
         {:ok, _} <- Ecto.UUID.cast(payload["tenant_id"]),
         do: {:ok, payload},
         else: (_ -> {:error, :unauthorized})
  end

  def context(payload, library_only \\ false),
    do: Repo.transact_top_level(fn -> context_in_tx(payload, library_only) end)

  defp context_in_tx(payload, library_only) do
    with {:ok, worker} when not is_nil(worker) <-
           AgentWorkers.get_agent_worker(payload["agent_uid"]),
         true <-
           worker.generation == payload["generation"] &&
             worker.incarnation_id == payload["incarnation"] &&
             worker.state in [:ready, :stale, :draining],
         {:ok, %{status: :active} = principal} <-
           Ankole.Principals.get_principal(payload["agent_uid"]),
         {:ok, projection} <-
           RuntimeProjection.for_signal(payload["agent_uid"], payload["job_signal_id"]),
         disclosure = disclosure(payload["disclosure"]),
         context = %{querier_uid: principal.uid, disclosure: disclosure},
         {:ok, access} <-
           if(library_only,
             do: {:ok, %Brain.Access{querier_uid: principal.uid}},
             else: Brain.Access.for_querier(principal.uid)
           ),
         {:ok, brain_access} <-
           if(library_only, do: {:ok, access}, else: Brain.Access.for_context(context)) do
      {:ok,
       %{
         actor: Actor.new(principal),
         context: context,
         access: access,
         brain_access: brain_access,
         library_only: library_only,
         runtime_projection: projection,
         conversation_id: payload["conversation_id"]
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp disclosure(value) do
    %{
      mode: if(value["mode"] == "strict", do: :strict, else: :relaxed),
      asker_uid: value["asker_uid"],
      present_uids: value["present_uids"] || []
    }
  end

  defp scope_key(payload, projection) do
    disclosure = payload["disclosure"] |> Torque.encode!() |> Torque.decode!()

    Kernel.vfs_fingerprint(
      Torque.encode!([
        payload["tenant_id"],
        payload["agent_uid"],
        disclosure["mode"],
        disclosure["asker_uid"],
        Enum.sort(disclosure["present_uids"] || []),
        projection
      ])
    )
  end
end
