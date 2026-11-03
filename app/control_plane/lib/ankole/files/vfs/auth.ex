defmodule Ankole.Files.Vfs.Auth do
  @moduledoc "Seals the runtime's existing disclosure context for one Worker incarnation."
  alias Ankole.{AgentWorkers, Brain, Kernel, Repo, SecretKeyBase}
  alias Ankole.AuthZ.Actor

  def runtime_config(agent_uid, signal_id) do
    case AgentWorkers.get_agent_worker(agent_uid) do
      {:ok, %{capacity: %{"drive_vfs" => true}}} -> mounted_config(agent_uid, signal_id)
      {:ok, _} -> {:ok, nil}
      error -> error
    end
  end

  defp mounted_config(agent_uid, signal_id) do
    with {:ok, config} <- issue(agent_uid, %{"signal_id" => signal_id}),
         {:ok, endpoints} <- AgentWorkers.Providers.connection_endpoints(agent_uid) do
      {:ok,
       struct(
         Ankole.RuntimeFabric.V1.DriveVfsConfig,
         Map.merge(config, %{
           endpoint:
             String.trim_trailing(
               endpoints["relayOrigin"] || Ankole.WorkerFiles.Relay.origin(),
               "/"
             ) <>
               "/api/v1/vfs/dav",
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
    with {:ok, context} <- Brain.RequestContext.build(agent_uid, metadata),
         {:ok, projection} <-
           Ankole.BackgroundAgentJobs.RuntimeProjection.for_signal(
             agent_uid,
             Brain.RequestContext.signal_id(metadata)
           ),
         {:ok, worker} when not is_nil(worker) <- AgentWorkers.get_agent_worker(agent_uid),
         true <- is_binary(worker.incarnation_id) do
      payload = %{
        "tenant_id" => Repo.tenant_id!(),
        "skill_selection" => projection,
        "agent_uid" => agent_uid,
        "disclosure" => context.disclosure,
        "conversation_id" => context.conversation_id,
        "generation" => worker.generation,
        "incarnation" => worker.incarnation_id,
        "expires_at" => System.system_time(:second) + 3600
      }

      with {:ok, token} <- SecretKeyBase.seal(Torque.encode!(payload), "drive.vfs", []) do
        {:ok,
         %{
           token: token,
           scope: scope_key(payload),
           library_scope:
             Kernel.vfs_fingerprint(Torque.encode!([payload["tenant_id"], agent_uid, projection])),
           view: view_key(payload),
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
         disclosure = disclosure(payload["disclosure"]),
         context = %{querier_uid: principal.uid, disclosure: disclosure},
         {:ok, access} <-
           if(library_only,
             do: {:ok, %Brain.Access{querier_uid: principal.uid}},
             else: Brain.Access.for_context(context)
           ) do
      {:ok,
       %{
         actor: Actor.new(principal),
         context: context,
         access: access,
         library_only: library_only,
         runtime_projection: payload["skill_selection"],
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

  defp scope_key(payload) do
    disclosure = payload["disclosure"] |> Torque.encode!() |> Torque.decode!()

    Kernel.vfs_fingerprint(
      Torque.encode!([
        payload["tenant_id"],
        payload["agent_uid"],
        disclosure["mode"],
        disclosure["asker_uid"],
        Enum.sort(disclosure["present_uids"] || []),
        payload["skill_selection"]
      ])
    )
  end

  defp view_key(payload),
    do: Kernel.vfs_fingerprint(Torque.encode!([scope_key(payload), payload["conversation_id"]]))
end
