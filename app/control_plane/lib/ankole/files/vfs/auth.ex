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
    result =
      Repo.transact_top_level(fn ->
        with {:ok, _} <- context_in_tx(payload, library_only),
             {:ok, refreshed_payload, disclosure_changed?} <- refreshed_payload_in_tx(payload),
             {:ok, token} <-
               SecretKeyBase.seal(Torque.encode!(refreshed_payload), "drive.vfs", []) do
          {:ok, {token, disclosure_changed?}}
        end
      end)

    case result do
      {:ok, {token, true}} ->
        Phoenix.PubSub.broadcast(
          Ankole.PubSub,
          "drive-vfs-access:" <> Repo.tenant_id!(),
          :vfs_access_changed
        )

        {:ok, token}

      {:ok, {token, false}} ->
        {:ok, token}

      error ->
        error
    end
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
        "signal_id" => signal_id,
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
           if(library_only,
             do: {:ok, access},
             else: Brain.Access.for_context(context, access)
           ) do
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

  defp refreshed_payload_in_tx(payload) do
    expires_at = System.system_time(:second) + 3600

    cond do
      Map.has_key?(payload, "signal_id") ->
        recompute_disclosure_in_tx(payload, payload["signal_id"], expires_at)

      is_binary(payload["job_signal_id"]) and payload["job_signal_id"] != "" ->
        recompute_disclosure_in_tx(payload, payload["job_signal_id"], expires_at)

      true ->
        {:ok, Map.put(payload, "expires_at", expires_at), false}
    end
  end

  defp recompute_disclosure_in_tx(payload, signal_id, expires_at) do
    case Brain.RequestContext.build(payload["agent_uid"], %{"signal_id" => signal_id}) do
      {:ok, context} ->
        previous = normalized_disclosure(payload["disclosure"])
        current = normalized_disclosure(context.disclosure)

        refreshed =
          payload
          |> Map.put("disclosure", context.disclosure)
          |> Map.put("conversation_id", context.conversation_id)
          |> Map.put("expires_at", expires_at)

        {:ok, refreshed, previous != current}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  defp normalized_disclosure(value) do
    parsed = disclosure(value || %{})
    %{parsed | present_uids: Enum.sort(parsed.present_uids)}
  end

  defp disclosure(value) do
    raw_mode = Map.get(value, "mode", Map.get(value, :mode))

    %{
      mode: if(raw_mode in ["strict", :strict], do: :strict, else: :relaxed),
      asker_uid: Map.get(value, "asker_uid", Map.get(value, :asker_uid)),
      present_uids: Map.get(value, "present_uids", Map.get(value, :present_uids)) || []
    }
  end

  defp scope_key(payload, projection) do
    parsed = normalized_disclosure(payload["disclosure"])

    Kernel.vfs_fingerprint(
      Torque.encode!([
        payload["tenant_id"],
        payload["agent_uid"],
        Atom.to_string(parsed.mode),
        parsed.asker_uid,
        parsed.present_uids,
        projection
      ])
    )
  end
end
