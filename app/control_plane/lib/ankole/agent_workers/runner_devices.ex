defmodule Ankole.AgentWorkers.RunnerDevices do
  @moduledoc "Member enrollment, private Agent bindings, and placement for device-backed Jobs."

  require Ash.Query
  alias Ankole.{AgentWorkers, AuthZ.Actor, BackgroundAgentJobs, Principals, Repo}
  alias Ankole.AgentWorkers.{Config, RunnerBinding, RunnerDevice, WorkerRoute}
  alias Ankole.Authn.SecretDigest

  @pairing_seconds 600
  @heartbeat_seconds 60

  def list(%Actor{} = actor) do
    with {:ok, owner} <- member(actor) do
      RunnerDevice
      |> Ash.Query.filter(owner_uid == ^owner.uid and is_nil(revoked_at))
      |> Ash.Query.sort(name: :asc, id: :asc)
      |> Ankole.Ash.read!()
      |> Enum.filter(fn device ->
        device.owner_access_version == owner.access_version and
          (device.token_digest != nil or pending?(device))
      end)
      |> Enum.map(&project(&1, bindings(&1.id)))
      |> then(&{:ok, &1})
    end
  end

  def list_for_agent(uid, agent_uid) when is_binary(uid) do
    with {:ok, owner} <- member(uid),
         true <- owned_agent?(agent_uid, owner.uid),
         {:ok, devices} <- list(Actor.new(owner)) do
      Enum.filter(devices, fn device ->
        device.status != "pairing" and Enum.any?(device.bindings, &(&1.agentUID == agent_uid))
      end)
    else
      _ -> []
    end
  end

  def list_for_agent(_, _), do: []

  def register(%Actor{} = actor, name, origin) do
    with {:ok, owner} <- member(actor),
         {:ok, %{agent: assistant}} <- Principals.ensure_personal_assistant(owner.uid),
         {:ok, config} <- Config.fetch() do
      code = SecretDigest.token()

      Repo.transact_top_level(fn ->
        with {:ok, %{principal: %{membership: :member} = principal}} <-
               Principals.lock_active_human_in_tx(owner.uid),
             true <- principal.access_version == owner.access_version,
             {:ok, device} <-
               Ankole.Ash.create(RunnerDevice, :register, %{
                 id: Ash.UUIDv7.generate(),
                 owner_uid: owner.uid,
                 owner_access_version: principal.access_version,
                 name: name,
                 pairing_digest: digest(code),
                 pairing_expires_at: DateTime.add(Repo.now!(), @pairing_seconds)
               }),
             {:ok, _binding} <- register_binding(device.id, assistant.uid, origin, config) do
          {:ok, %{id: device.id, code: code, url: origin}}
        else
          false -> {:error, :runner_unavailable}
          {:error, _} = error -> error
          _ -> {:error, :runner_unavailable}
        end
      end)
    end
  end

  def bind(%Actor{} = actor, runner_id, agent_uid, origin) do
    with {:ok, owner} <- member(actor),
         true <- owned_agent?(agent_uid, owner.uid),
         {:ok, config} <- Config.fetch() do
      Repo.transact_top_level(fn ->
        with %RunnerDevice{owner_uid: uid, revoked_at: nil} = device when uid == owner.uid <-
               lock_runner_in_tx(runner_id),
             true <- device.owner_access_version == owner.access_version,
             true <- owned_agent?(agent_uid, owner.uid),
             {:ok, _} <- existing_or_register(runner_id, agent_uid, origin, config) do
          {:ok, project(device, bindings(runner_id))}
        else
          {:error, _} = error -> error
          _ -> {:error, :runner_unavailable}
        end
      end)
    else
      false -> {:error, :runner_unavailable}
      {:error, _} = error -> error
    end
  end

  def revoke(%Actor{} = actor, runner_id) do
    with {:ok, owner} <- member(actor) do
      Repo.transact_top_level(
        fn ->
          case lock_runner_in_tx(runner_id) do
            %RunnerDevice{owner_uid: uid, revoked_at: nil} = device when uid == owner.uid ->
              now = Repo.now!()

              with {:ok, _} <-
                     Ankole.Ash.update(device, :credentials, %{
                       revoked_at: now,
                       pairing_digest: nil,
                       pairing_expires_at: nil,
                       token_digest: nil
                     }),
                   {:ok, routes} <- disconnect_bindings_in_tx(runner_id),
                   {:ok, job} <-
                     BackgroundAgentJobs.fail_revoked_runner_job_in_tx(runner_id, now) do
                {:ok, %{routes: routes, job: job}}
              end

            %RunnerDevice{owner_uid: uid} when uid == owner.uid ->
              {:ok, %{routes: [], job: nil}}

            _ ->
              {:error, :runner_unavailable}
          end
        end,
        after_commit: fn %{routes: routes, job: job} ->
          Enum.each(routes, fn {uid, route} ->
            if route, do: WorkerRoute.close_connection(uid, route, :runner_revoked)
            AgentWorkers.notify_changed(uid)
          end)

          if job, do: BackgroundAgentJobs.publish_status_commit(job)
        end
      )
    end
  end

  def pair(code) when is_binary(code) and byte_size(code) == 43 do
    with %RunnerDevice{} = candidate <- by_credential(RunnerDevice, :pairing_digest, code) do
      Repo.with_tenant(candidate.tenant_id, fn ->
        Repo.transact_top_level(fn -> pair_in_tx(candidate, digest(code)) end)
      end)
    else
      _ -> {:error, :invalid_runner_credential}
    end
  end

  def pair(_), do: {:error, :invalid_runner_credential}

  defp pair_in_tx(candidate, pairing_digest) do
    with {:ok, %{principal: %{membership: :member} = owner}} <-
           Principals.lock_active_human_in_tx(candidate.owner_uid),
         %RunnerDevice{revoked_at: nil, pairing_digest: ^pairing_digest} = device <-
           lock_runner_in_tx(candidate.id),
         true <- owner.access_version == device.owner_access_version,
         true <- pending?(device, Repo.now!()) do
      token = SecretDigest.token()

      with {:ok, _} <-
             Ankole.Ash.update(device, :credentials, %{
               pairing_digest: nil,
               pairing_expires_at: nil,
               token_digest: digest(token)
             }) do
        {:ok, %{runner_id: device.id, token: token}}
      end
    else
      _ -> {:error, :invalid_runner_credential}
    end
  end

  def bootstrap(token, origin) when is_binary(token) and byte_size(token) == 43 do
    with %RunnerDevice{} = candidate <- by_credential(RunnerDevice, :token_digest, token),
         {:ok, config} <- Config.fetch() do
      Repo.with_tenant(candidate.tenant_id, fn ->
        Repo.transact_top_level(fn ->
          bootstrap_in_tx(candidate.id, digest(token), origin, config)
        end)
      end)
    else
      nil -> {:error, :invalid_runner_credential}
      {:error, _} = error -> error
    end
  end

  def bootstrap(_, _), do: {:error, :invalid_runner_credential}

  defp bootstrap_in_tx(id, token_digest, origin, config) do
    with %RunnerDevice{revoked_at: nil, token_digest: ^token_digest} = device <-
           lock_runner_in_tx(id),
         true <- active_owner?(device) do
      id
      |> bindings()
      |> Enum.filter(&owned_agent?(&1.agent_uid, device.owner_uid))
      |> Enum.reduce_while({:ok, []}, fn binding, {:ok, acc} ->
        with {:ok, binding} <- current_generation(binding, origin, config),
             {:ok, spec} <- launch_spec(binding) do
          {:cont, {:ok, [spec | acc]}}
        else
          error -> {:halt, error}
        end
      end)
    else
      _ -> {:error, :invalid_runner_credential}
    end
  end

  def authenticate(agent_uid, token) when is_binary(token) and byte_size(token) == 43 do
    case by_credential(RunnerBinding, :token_digest, token) do
      %RunnerBinding{agent_uid: ^agent_uid} = binding ->
        Repo.with_tenant(binding.tenant_id, fn ->
          if active_binding?(agent_uid, binding.runner_id, binding.generation) do
            {:ok, Map.take(binding, [:tenant_id, :generation, :runner_id])}
          else
            {:error, :invalid_worker_credential}
          end
        end)

      _ ->
        {:error, :invalid_worker_credential}
    end
  end

  def authenticate(_, _), do: {:error, :invalid_worker_credential}

  def active_binding?(agent_uid, runner_id, generation) do
    with %RunnerBinding{generation: ^generation} <- get_binding(agent_uid, runner_id),
         %RunnerDevice{revoked_at: nil, token_digest: token} = device when is_binary(token) <-
           get_runner(runner_id) do
      active_owner?(device) and owned_agent?(agent_uid, device.owner_uid)
    else
      _ -> false
    end
  end

  def authorize_for_job(%Actor{} = actor, agent_uid, runner_id) do
    if Actor.tenant_id(actor) == Repo.tenant_id!(),
      do: authorize_for_job(Actor.uid(actor), agent_uid, runner_id),
      else: {:error, :runner_unavailable}
  end

  def authorize_for_job(owner_uid, agent_uid, runner_id) when is_binary(owner_uid) do
    with %RunnerDevice{owner_uid: ^owner_uid} <- get_runner(runner_id),
         %RunnerBinding{generation: generation} <- get_binding(agent_uid, runner_id),
         true <- active_binding?(agent_uid, runner_id, generation) do
      :ok
    else
      _ -> {:error, :runner_unavailable}
    end
  end

  def authorize_for_job(_, _, _), do: {:error, :runner_unavailable}

  def connected_worker(agent_uid, runner_id) do
    case get_binding(agent_uid, runner_id) do
      %RunnerBinding{state: state, generation: generation} = binding
      when state in [:ready, :draining] ->
        if fresh?(binding) and active_binding?(agent_uid, runner_id, generation),
          do: {:ok, binding},
          else: {:error, :agent_worker_unavailable}

      _ ->
        {:error, :agent_worker_unavailable}
    end
  end

  def reserve_slot_in_tx(agent_uid, runner_id) do
    with {:ok, %RunnerBinding{state: :ready} = binding} <- connected_worker(agent_uid, runner_id) do
      if is_integer(binding.capacity["available_slots"]) and
           binding.capacity["available_slots"] > 0 and
           is_nil(BackgroundAgentJobs.running_for_runner(runner_id)) do
        {:ok, binding}
      else
        {:error, :no_worker_capacity}
      end
    else
      {:ok, _draining} -> {:error, :agent_worker_unavailable}
      {:error, _} = error -> error
    end
  end

  def get_runner(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      RunnerDevice
      |> Ash.Query.filter(id == ^id)
      |> Ankole.Ash.read_one!()
    else
      _ -> nil
    end
  end

  def get_binding(agent_uid, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      RunnerBinding
      |> Ash.Query.filter(runner_id == ^id and agent_uid == ^agent_uid)
      |> Ankole.Ash.read_one!()
    else
      _ -> nil
    end
  end

  def by_route(route) when is_binary(route) do
    RunnerBinding
    |> Ash.Query.filter(transport_route == ^route)
    |> Ankole.Ash.read_one!()
  end

  def by_route(_), do: nil

  def lock_runner_in_tx(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      RunnerDevice
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"runner_devices", id})
    else
      _ -> nil
    end
  end

  def lock_binding_in_tx(agent_uid, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      RunnerBinding
      |> Ash.Query.filter(runner_id == ^id and agent_uid == ^agent_uid)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"runner_bindings", {id, agent_uid}})
    else
      _ -> nil
    end
  end

  defp bindings(id) do
    RunnerBinding
    |> Ash.Query.filter(runner_id == ^id)
    |> Ash.Query.sort(agent_uid: :asc)
    |> Ankole.Ash.read!()
  end

  defp disconnect_bindings_in_tx(id) do
    Enum.reduce_while(bindings(id), {:ok, []}, fn row, {:ok, routes} ->
      locked = lock_binding_in_tx(row.agent_uid, id)

      case Ankole.Ash.update(locked, :connection, %{
             state: :stale,
             transport_route: nil,
             last_worker_heartbeat_at: nil,
             capacity: %{},
             load: %{}
           }) do
        {:ok, _} -> {:cont, {:ok, [{locked.agent_uid, locked.transport_route} | routes]}}
        error -> {:halt, error}
      end
    end)
  end

  defp existing_or_register(id, uid, origin, config) do
    case get_binding(uid, id) do
      nil -> register_binding(id, uid, origin, config)
      binding -> {:ok, binding}
    end
  end

  defp register_binding(id, uid, origin, config) do
    with {:ok, attrs} <- generation_attrs(id, origin, config) do
      Ankole.Ash.create(
        RunnerBinding,
        :register,
        Map.merge(attrs, %{agent_uid: uid, runner_id: id})
      )
    end
  end

  defp current_generation(binding, origin, config) do
    if binding.protocol_version == config.protocol_version and binding.image == config.image and
         binding.instance_settings == settings(origin) do
      {:ok, binding}
    else
      with %RunnerBinding{} = locked <- lock_binding_in_tx(binding.agent_uid, binding.runner_id),
           {:ok, attrs} <- generation_attrs(binding.runner_id, origin, config) do
        Ankole.Ash.update(locked, :replace_generation, attrs)
      else
        nil -> {:error, :runner_unavailable}
        error -> error
      end
    end
  end

  defp generation_attrs(id, origin, config) do
    generation = SecretDigest.token()
    token = SecretDigest.token()

    with {:ok, encrypted} <-
           Ankole.SecretKeyBase.seal(token, "runner_worker_credential", [
             Repo.tenant_id!(),
             id,
             generation
           ]) do
      {:ok,
       %{
         generation: generation,
         token_digest: digest(token),
         token_ciphertext: encrypted,
         protocol_version: config.protocol_version,
         image: config.image,
         instance_settings: settings(origin)
       }}
    end
  end

  defp settings(origin) do
    origin = worker_origin(origin)
    uri = URI.parse(origin)

    socket =
      URI.to_string(%{
        uri
        | scheme: if(uri.scheme == "https", do: "wss", else: "ws"),
          path: "/runtime-fabric/worker"
      })

    %{
      "endpoints" => %{
        "runtimeFabricUrl" => socket,
        "relayOrigin" => origin,
        "aiGatewayUrl" => origin <> "/api/v1/ai-gateway"
      }
    }
  end

  defp worker_origin(origin) do
    case {URI.parse(origin), Application.get_env(:ankole, :runtime_fabric_internal_origin)} do
      {%URI{scheme: "http", host: host}, "http://host.docker.internal:" <> _ = docker_origin}
      when is_binary(host) ->
        if host in ["localhost", "127.0.0.1", "::1"] or String.ends_with?(host, ".localhost"),
          do: docker_origin,
          else: origin

      _ ->
        origin
    end
  end

  defp launch_spec(binding) do
    with {:ok, token} <-
           Ankole.SecretKeyBase.unseal(binding.token_ciphertext, "runner_worker_credential", [
             binding.tenant_id,
             binding.runner_id,
             binding.generation
           ]) do
      {:ok,
       %{
         agent_uid: binding.agent_uid,
         tenant_id: binding.tenant_id,
         generation: binding.generation,
         image: binding.image,
         worker_token: token,
         runtime_fabric_url: get_in(binding.instance_settings, ["endpoints", "runtimeFabricUrl"])
       }}
    end
  end

  defp by_credential(resource, field, token) do
    resource
    |> Ash.Query.for_read(:by_credential)
    |> Ash.Query.filter(^[{field, digest(token)}])
    |> Ankole.Ash.read_across_tenants!()
    |> List.first()
  end

  defp member(%Actor{} = actor) do
    if Actor.tenant_id(actor) == Repo.tenant_id!(),
      do: member(Actor.uid(actor)),
      else: {:error, :runner_unavailable}
  end

  defp member(uid) do
    case Principals.get_principal(uid) do
      {:ok, %{type: :human, status: :active, membership: :member} = principal} ->
        {:ok, principal}

      _ ->
        {:error, :runner_unavailable}
    end
  end

  defp active_owner?(device) do
    case member(device.owner_uid) do
      {:ok, owner} -> owner.access_version == device.owner_access_version
      _ -> false
    end
  end

  defp owned_agent?(uid, owner) do
    match?(
      {:ok, %{agent: %{owner_principal_uid: ^owner}, principal: %{status: :active}}},
      Principals.get_agent(uid)
    )
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp pending?(device, now \\ DateTime.utc_now()) do
    is_struct(device.pairing_expires_at, DateTime) and
      DateTime.after?(device.pairing_expires_at, now)
  end

  defp fresh?(%RunnerBinding{last_worker_heartbeat_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at) < @heartbeat_seconds

  defp fresh?(_), do: false

  defp project(device, rows) do
    %{
      id: device.id,
      name: device.name,
      status:
        cond do
          device.token_digest == nil -> "pairing"
          Enum.any?(rows, &(fresh?(&1) and &1.state == :ready)) -> "online"
          true -> "offline"
        end,
      bindings: Enum.map(rows, &%{agentUID: &1.agent_uid})
    }
  end
end
