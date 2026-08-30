defmodule Ankole.SignalsGateway.ActorRuntime.AmbientIntervention do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs.Queries, as: BackgroundAgentJobQueries
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.ChannelContext
  alias Ankole.SignalsGateway.Utils

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @spec process(actor_key(), ActorEvent.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def process(actor_key, %ActorEvent{} = event, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case resolve(event, now) do
      {:ok, %{status: :ambient_fresh, actor_event: fresh_event}} ->
        actor_key
        |> TurnLifecycle.start_worker_turn(fresh_event, turn_opts(opts, fresh_event, now))
        |> finalize_admission_race(fresh_event, now)

      result ->
        result
    end
  end

  defp resolve(%ActorEvent{} = event, now) do
    Repo.transact(fn repo ->
      :ok = Actors.lock_actor_session_in_tx(repo, event.agent_uid, event.session_id)

      case Actors.lock_actor_event_in_tx(repo, event.id) do
        %ActorEvent{completed_at: %DateTime{}} = completed_event ->
          {:ok, %{status: :already_completed, actor_event: completed_event}}

        %ActorEvent{input_state: "open"} = locked_event ->
          resolve_locked_event(repo, locked_event, now)

        %ActorEvent{} = unavailable_event ->
          {:ok, %{status: :ambient_unavailable, actor_event: unavailable_event}}

        nil ->
          {:ok, %{status: :idle}}
      end
    end)
  end

  defp resolve_locked_event(repo, event, now) do
    pending_events = lock_pending_ambient_events(repo, event)
    current_scene_fingerprint = current_scene_fingerprint(repo, event.signal_channel_id)

    classified =
      Enum.map(pending_events, fn pending_event ->
        {pending_event, stale_reason(repo, pending_event, now, current_scene_fingerprint)}
      end)

    latest_fresh_event =
      classified
      |> Enum.filter(fn {_event, reason} -> is_nil(reason) end)
      |> List.last()
      |> case do
        {%ActorEvent{} = fresh_event, nil} -> fresh_event
        nil -> nil
      end

    latest_fresh_event_id = latest_fresh_event && latest_fresh_event.id

    superseded =
      Enum.flat_map(classified, fn
        {%ActorEvent{id: id}, nil} when id == latest_fresh_event_id ->
          []

        {%ActorEvent{} = pending_event, nil} ->
          [{pending_event, :newer_ambient_event}]

        {%ActorEvent{} = pending_event, reason} ->
          [{pending_event, reason}]
      end)

    with {:ok, completed_by_id} <- complete_superseded(repo, superseded, now) do
      case Map.get(completed_by_id, event.id) do
        {%ActorEvent{} = completed_event, reason} ->
          {:ok,
           %{
             status: :ambient_superseded,
             reason: reason,
             actor_event: completed_event,
             superseded_count: map_size(completed_by_id)
           }}

        nil when latest_fresh_event_id == event.id ->
          {:ok,
           %{
             status: :ambient_fresh,
             actor_event: latest_fresh_event,
             superseded_count: map_size(completed_by_id)
           }}

        nil ->
          {:ok, %{status: :ambient_unavailable, actor_event: event}}
      end
    end
  end

  defp lock_pending_ambient_events(repo, %ActorEvent{} = event) do
    live_states = ActorEventDelivery.live_states()

    live_event_ids =
      ActorEventDelivery
      |> where([delivery], delivery.state in ^live_states)
      |> select([delivery], delivery.actor_event_id)

    ActorEvent
    |> where([pending], pending.agent_uid == ^event.agent_uid)
    |> where([pending], pending.session_id == ^event.session_id)
    |> where([pending], pending.type == "im.message.may_intervene")
    |> where([pending], pending.input_state == "open")
    |> where([pending], is_nil(pending.completed_at))
    |> where([pending], pending.id not in subquery(live_event_ids))
    |> same_signal_channel(event.signal_channel_id)
    |> order_by([pending], asc: pending.queue_sequence)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp same_signal_channel(query, signal_channel_id) when is_binary(signal_channel_id) do
    where(query, [pending], pending.signal_channel_id == ^signal_channel_id)
  end

  defp same_signal_channel(query, nil) do
    where(query, [pending], is_nil(pending.signal_channel_id))
  end

  defp complete_superseded(repo, superseded, now) do
    Enum.reduce_while(superseded, {:ok, %{}}, fn {event, reason}, {:ok, completed_by_id} ->
      case Actors.mark_event_completed_in_tx(repo, event, now) do
        {:ok, completed_event} ->
          completed_by_id = Map.put(completed_by_id, event.id, {completed_event, reason})
          {:cont, {:ok, completed_by_id}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp turn_opts(opts, event, now) do
    downstream_admission = Keyword.get(opts, :admit_in_tx)

    opts
    |> Keyword.put_new(:profile, "light")
    |> Keyword.put(:admit_in_tx, fn repo, turn_start_spec ->
      with {:ok, locked_event} <- admit_fresh_in_tx(repo, event, now),
           {:ok, downstream_overrides} <-
             run_downstream_admission(repo, turn_start_spec, downstream_admission) do
        {:ok, put_work_candidates(repo, locked_event, downstream_overrides)}
      end
    end)
  end

  defp admit_fresh_in_tx(repo, %ActorEvent{} = event, now) do
    :ok = Actors.lock_actor_session_in_tx(repo, event.agent_uid, event.session_id)

    case Actors.lock_actor_event_in_tx(repo, event.id) do
      %ActorEvent{completed_at: nil, input_state: "open"} = locked_event ->
        case ensure_fresh_in_tx(repo, locked_event, now) do
          :ok -> {:ok, locked_event}
          {:error, _reason} = error -> error
        end

      %ActorEvent{} ->
        {:error, {:ambient_unavailable, event.id}}

      nil ->
        {:error, {:ambient_unavailable, event.id}}
    end
  end

  defp run_downstream_admission(_repo, _turn_start_spec, nil), do: {:ok, %{}}

  defp run_downstream_admission(repo, turn_start_spec, callback) when is_function(callback, 2),
    do: normalize_downstream_admission(callback.(repo, turn_start_spec))

  defp run_downstream_admission(repo, _turn_start_spec, callback) when is_function(callback, 1),
    do: normalize_downstream_admission(callback.(repo))

  defp run_downstream_admission(_repo, _turn_start_spec, callback),
    do: {:error, {:invalid_turn_admission_callback, callback}}

  defp normalize_downstream_admission(:ok), do: {:ok, %{}}
  defp normalize_downstream_admission({:ok, %{} = overrides}), do: {:ok, overrides}
  defp normalize_downstream_admission({:error, _reason} = error), do: error

  defp normalize_downstream_admission(other),
    do: {:error, {:invalid_turn_admission_result, other}}

  defp put_work_candidates(repo, %ActorEvent{} = event, overrides) do
    candidates =
      BackgroundAgentJobQueries.ambient_candidates_in_tx(
        repo,
        event.agent_uid,
        event.session_id,
        event.signal_channel_id,
        event.binding_name
      )
      |> work_candidates_payload()

    request_context =
      overrides
      |> Map.get(:request_context, %{})
      |> Map.put("ambient_work_candidates", candidates)

    Map.put(overrides, :request_context, request_context)
  end

  defp work_candidates_payload(%{complete: complete, jobs: jobs}) do
    %{
      "complete" => complete,
      "jobs" =>
        Enum.map(jobs, fn job ->
          %{
            "job_id" => Integer.to_string(job.job_id),
            "title" => job.title,
            "status" => job.status,
            "task_excerpt" => job.task_excerpt
          }
        end)
    }
  end

  defp finalize_admission_race({:error, {:ambient_stale, _reason}}, event, now),
    do: resolve(event, now)

  defp finalize_admission_race({:error, {:ambient_unavailable, _event_id}}, event, now),
    do: resolve(event, now)

  defp finalize_admission_race(result, _event, _now), do: result

  defp stale_reason(repo, %ActorEvent{} = event, now) do
    current_scene_fingerprint = current_scene_fingerprint(repo, event.signal_channel_id)
    stale_reason(repo, event, now, current_scene_fingerprint)
  end

  @doc false
  @spec ensure_fresh_in_tx(module(), ActorEvent.t(), DateTime.t()) ::
          :ok | {:error, {:ambient_stale, atom()}}
  def ensure_fresh_in_tx(repo, %ActorEvent{} = event, %DateTime{} = now) do
    case stale_reason(repo, event, now) do
      nil -> :ok
      reason -> {:error, {:ambient_stale, reason}}
    end
  end

  defp stale_reason(repo, %ActorEvent{} = event, now, current_scene_fingerprint) do
    ambient_batch = get_in(event.payload, ["data", "ambient_batch"])
    stored_fingerprint = map_value(ambient_batch, "scene_fingerprint")
    expires_at = ambient_batch |> map_value("expires_at") |> Utils.parse_datetime()

    cond do
      not current_binding_allows_intervention?(repo, event) ->
        :binding_policy_changed

      not is_binary(stored_fingerprint) or is_nil(expires_at) ->
        :missing_freshness_snapshot

      DateTime.compare(now, expires_at) != :lt ->
        :expired

      not is_binary(event.signal_channel_id) ->
        :missing_signal_channel

      current_scene_fingerprint != stored_fingerprint ->
        :scene_changed

      true ->
        nil
    end
  end

  defp current_scene_fingerprint(repo, signal_channel_id) when is_binary(signal_channel_id),
    do: ChannelContext.ambient_scene_fingerprint(repo, signal_channel_id)

  defp current_scene_fingerprint(_repo, _signal_channel_id), do: nil

  defp current_binding_allows_intervention?(repo, %ActorEvent{} = event) do
    binding =
      Binding
      |> where([binding], binding.agent_uid == ^event.agent_uid)
      |> where([binding], binding.name == ^event.binding_name)
      |> lock("FOR SHARE")
      |> repo.one()

    case binding do
      %Binding{
        enabled: true,
        unavailable_reason: nil,
        unaddressed_group_message_policy: :may_intervene
      } ->
        true

      _binding ->
        false
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key)
  defp map_value(_value, _key), do: nil
end
