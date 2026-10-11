defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Decision do
  @moduledoc """
  The next action for one Agent's Worker.

  An unobserved generation is an unsettled create, not an absent instance.
  It can only be sent again, including during Agent deletion. A new
  generation requires confirmed absence of every previous instance.
  """

  @heartbeat_fresh_ms 30_000
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind

  @spec next(map()) :: atom() | tuple()
  def next(%{worker: worker, objects: objects} = facts) do
    {current, stray} = Enum.split_with(objects, &ProviderKind.current_instance?(worker, &1))
    current = List.first(current)

    cond do
      stray != [] -> {:delete_object, hd(stray)}
      current && not ProviderKind.instance_present?(current) -> partial(worker, current)
      worker.state == "deleting" -> deleting(worker, current)
      worker.state == "absent" -> if(wanted?(facts), do: :begin_create, else: :none)
      is_nil(current) and is_nil(worker.instance_seen_at) -> :create
      connected?(worker) and (is_nil(current) or current.phase == :exited) -> wait(worker)
      is_nil(current) -> :mark_absent
      worker.state == "draining" -> draining(facts, current)
      current.phase == :exited -> {:replace, "exited", :now}
      worker.state == "paused" -> paused(facts, current)
      true -> running(facts, current)
    end
  end

  # A Secret cannot prove that a Pod create finished. Retry the same generation
  # until a Pod is observed or the platform rejects creation.
  defp partial(%{instance_seen_at: nil}, _current), do: :create
  defp partial(_worker, current), do: {:delete_object, current}

  defp deleting(%{generation: nil}, nil), do: :delete_storage
  defp deleting(%{instance_seen_at: nil}, nil), do: :create
  defp deleting(_worker, nil), do: :mark_absent
  defp deleting(_worker, current), do: {:delete_object, current}

  defp draining(facts, current) do
    cond do
      current.phase == :exited ->
        :delete_now

      current.phase == :paused and pause_release?(facts.definition, facts.worker.drain_reason) ->
        :mark_paused

      past?(facts, facts.worker.state_changed_at, facts.settings.stop_grace_ms) ->
        :delete_now

      pause_release?(facts.definition, facts.worker.drain_reason) ->
        :pause

      true ->
        wait(facts.worker)
    end
  end

  defp paused(facts, current) do
    cond do
      changed?(facts) or lifetime_due?(facts, current) -> {:replace, "replacement", :now}
      wanted?(facts) -> :resume
      current.phase in [:running, :starting] -> {:replace, "not_needed", :now}
      true -> :none
    end
  end

  defp running(%{worker: worker} = facts, current) do
    cond do
      differs?(facts, :protocol_version) ->
        {:replace, "replacement", :now}

      (changed?(facts) or lifetime_due?(facts, current)) and idle?(facts) ->
        {:replace, "replacement", :graceful}

      worker.state in ["starting", "stale"] and not_ready_too_long?(facts) ->
        {:replace, "rebuild", :now}

      true ->
        running_instance(facts, current)
    end
  end

  defp running_instance(%{worker: worker} = facts, current) do
    cond do
      # An instance that never joined has no work to keep. Delete it rather
      # than pause it, also for a disabled Agent.
      worker.state == "starting" and not wanted?(facts) ->
        {:release, "not_needed"}

      worker.state == "stale" and facts.agent != :active and not facts.turn_in_progress? ->
        {:release, "agent_inactive"}

      worker.state == "stale" and not wanted?(facts) and not idle_below_release?(facts) ->
        {:release, "not_needed"}

      worker.state == "ready" and facts.agent != :active and inactive_idle?(facts) ->
        {:release, "agent_inactive"}

      worker.state == "ready" and idle_release?(facts) ->
        {:release, "idle_release"}

      worker.state == "starting" ->
        starting_instance(facts, current)

      true ->
        :none
    end
  end

  defp starting_instance(%{worker: worker} = facts, current) do
    cond do
      facts.definition.pause and current.phase == :paused ->
        :resume

      current.phase == :starting and
          is_nil(worker.incarnation_id) ->
        :create

      true ->
        wait(worker)
    end
  end

  defp not_ready_too_long?(facts) do
    timeout = facts.settings.ready_timeout_ms

    Enum.all?(
      [facts.worker.instance_seen_at, facts.worker.state_changed_at, facts.observing_since],
      &past?(facts, &1, timeout)
    )
  end

  defp lifetime_due?(%{definition: %{max_instance_lifetime: nil}}, _current), do: false

  defp lifetime_due?(facts, current),
    do: lifetime_due?(current.started_at, facts.definition.max_instance_lifetime, facts.now)

  @doc "An idle or paused release keeps the instance when the platform can pause it."
  @spec pause_release?(map(), String.t() | nil) :: boolean()
  def pause_release?(definition, reason),
    do: definition.pause and reason in ~w(idle_release agent_inactive)

  @doc "An instance past 90% of the platform lifetime limit is replaced when idle."
  @spec lifetime_due?(DateTime.t() | nil, pos_integer() | nil, DateTime.t()) :: boolean()
  def lifetime_due?(%DateTime{} = started_at, lifetime_s, now) when is_integer(lifetime_s),
    do: DateTime.diff(now, started_at, :millisecond) >= lifetime_s * 900

  def lifetime_due?(_started_at, _lifetime_s, _now), do: false

  defp wanted?(%{agent: :active} = facts), do: requested?(facts) or facts.turn_in_progress?
  defp wanted?(_facts), do: false

  defp requested?(%{worker: %{wanted_until: %DateTime{} = until}, now: now}),
    do: DateTime.compare(until, now) == :gt

  defp requested?(_facts), do: false

  defp idle_below_release?(%{settings: %{idle_release_after_ms: :never}}), do: true

  defp idle_below_release?(facts),
    do: Map.get(facts.worker.load, "idle_for_ms", 0) < facts.settings.idle_release_after_ms

  defp idle_release?(%{settings: %{idle_release_after_ms: :never}}), do: false

  defp idle_release?(facts) do
    facts.agent == :active and heartbeat_fresh?(facts) and
      Map.get(facts.worker.load, "active_tasks") == 0 and
      Map.get(facts.worker.load, "idle_for_ms", 0) >= facts.settings.idle_release_after_ms and
      not facts.turn_in_progress? and not requested?(facts)
  end

  defp inactive_idle?(facts),
    do:
      heartbeat_fresh?(facts) and Map.get(facts.worker.load, "active_tasks") == 0 and
        not facts.turn_in_progress?

  defp idle?(facts),
    do: Map.get(facts.worker.load, "active_tasks", 0) == 0 and not facts.turn_in_progress?

  defp heartbeat_fresh?(%{worker: %{last_worker_heartbeat_at: %DateTime{} = at}} = facts),
    do: not past?(facts, at, @heartbeat_fresh_ms)

  defp heartbeat_fresh?(_facts), do: false

  defp changed?(facts),
    do: Enum.any?([:image, :protocol_version, :settings_digest], &differs?(facts, &1))

  defp differs?(%{worker: worker, target: target}, key),
    do: Map.get(worker, key) != Map.get(target, key)

  defp connected?(worker), do: not is_nil(worker.transport_route)
  defp wait(worker), do: {:wait, worker.state_changed_at}
  defp past?(_facts, nil, _ms), do: false

  defp past?(%{now: now}, %DateTime{} = since, ms),
    do: DateTime.diff(now, since, :millisecond) >= ms
end
