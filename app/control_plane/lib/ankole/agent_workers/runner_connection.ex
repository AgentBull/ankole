defmodule Ankole.AgentWorkers.RunnerConnection do
  @moduledoc "Owns the RuntimeFabric connection fence for a paired device's Agent binding."

  alias Ankole.AgentWorkers.{RunnerBinding, RunnerDevices}
  alias Ankole.Repo
  alias Ankole.RuntimeFabric

  @heartbeat_timeout_seconds 60

  def admit_in_tx(%{agent_uid: uid, runner_id: runner_id} = input) do
    case active_binding_in_tx(uid, runner_id, input.generation) do
      %RunnerBinding{} = binding -> admit(binding, input)
      nil -> {:error, :stale_worker_generation}
    end
  end

  defp admit(binding, input) do
    now = Repo.now!()

    cond do
      binding.protocol_version != RuntimeFabric.protocol_version() ->
        {:error, :protocol_mismatch}

      binding.transport_route && binding.incarnation_id != input.incarnation &&
          fresh?(binding, now) ->
        {:error, :worker_incarnation_active}

      true ->
        replaced_route =
          if binding.transport_route != input.route, do: binding.transport_route

        with {:ok, worker} <-
               update(binding, %{
                 state: :ready,
                 transport_route: input.route,
                 incarnation_id: input.incarnation,
                 last_worker_heartbeat_at: now,
                 capacity: input.capacity
               }),
             do: {:ok, %{worker: worker, replaced_route: replaced_route}}
    end
  end

  def renew_in_tx(
        %{agent_uid: uid, runner_id: runner_id, route: route, incarnation: incarnation} = input
      ) do
    case active_binding_in_tx(uid, runner_id, input.generation) do
      %RunnerBinding{transport_route: ^route, incarnation_id: ^incarnation, state: state} =
          binding
      when state in [:ready, :draining] ->
        now = Repo.now!()

        capacity =
          if state == :draining,
            do: Map.put(input.capacity, "available_slots", 0),
            else: input.capacity

        with true <- fresh?(binding, now) || {:error, :stale_transport_route},
             {:ok, worker} <-
               update(binding, %{
                 capacity: capacity,
                 load: input.load,
                 last_worker_heartbeat_at: now
               }),
             do: {:ok, %{worker: worker, changed?: binding.capacity != capacity}}

      _ ->
        {:error, :stale_transport_route}
    end
  end

  def drain_in_tx(%{agent_uid: uid, runner_id: runner_id, route: route, generation: generation}) do
    case active_binding_in_tx(uid, runner_id, generation) do
      %RunnerBinding{transport_route: ^route, state: state} = binding
      when state in [:ready, :draining] ->
        update(binding, %{
          state: :draining,
          capacity: Map.put(binding.capacity, "available_slots", 0)
        })

      _ ->
        {:error, :worker_not_ready}
    end
  end

  def release_in_tx(route) do
    with %RunnerBinding{agent_uid: uid, runner_id: runner_id} <- RunnerDevices.by_route(route),
         %RunnerBinding{transport_route: ^route} = binding <-
           RunnerDevices.lock_binding_in_tx(uid, runner_id) do
      update(binding, %{
        state: :stale,
        transport_route: nil,
        capacity: Map.put(binding.capacity, "available_slots", 0)
      })
    else
      _ -> {:ok, nil}
    end
  end

  def current?(connection), do: match?(%RunnerBinding{}, current(connection))

  def current(%{worker_id: uid, runner_id: runner_id} = connection) do
    case RunnerDevices.get_binding(uid, runner_id) do
      %RunnerBinding{transport_route: route, state: state} = binding
      when is_binary(route) and state in [:ready, :draining] ->
        if matches?(binding, connection) and fresh?(binding, Repo.now!()) and
             RunnerDevices.active_binding?(uid, runner_id, binding.generation),
           do: binding

      _ ->
        nil
    end
  end

  def current(_connection), do: nil

  def lock_current_in_tx(
        %{worker_id: uid, runner_id: runner_id, generation: generation} = connection
      ) do
    case active_binding_in_tx(uid, runner_id, generation) do
      %RunnerBinding{transport_route: route, state: state} = binding
      when is_binary(route) and state in [:ready, :draining] ->
        if matches?(binding, connection) and fresh?(binding, Repo.now!()),
          do: :ok,
          else: {:error, :stale_transport_route}

      _ ->
        {:error, :stale_transport_route}
    end
  end

  def lock_current_in_tx(_connection), do: {:error, :stale_transport_route}

  defp active_binding_in_tx(uid, runner_id, generation) do
    with %{} <- RunnerDevices.lock_runner_in_tx(runner_id),
         %RunnerBinding{generation: ^generation} = binding <-
           RunnerDevices.lock_binding_in_tx(uid, runner_id),
         true <- RunnerDevices.active_binding?(uid, runner_id, generation),
         do: binding,
         else: (_ -> nil)
  end

  defp matches?(binding, connection) do
    Enum.all?([:generation, :incarnation_id, :transport_route], fn field ->
      not Map.has_key?(connection, field) or
        Map.get(binding, field) == Map.fetch!(connection, field)
    end)
  end

  defp fresh?(%{last_worker_heartbeat_at: %DateTime{} = heartbeat}, now),
    do: DateTime.diff(now, heartbeat, :microsecond) < @heartbeat_timeout_seconds * 1_000_000

  defp fresh?(_binding, _now), do: false

  defp update(binding, attrs), do: Ankole.Ash.update(binding, :connection, attrs)
end
