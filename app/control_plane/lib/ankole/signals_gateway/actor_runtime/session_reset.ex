defmodule Ankole.SignalsGateway.ActorRuntime.SessionReset do
  @moduledoc false

  import Ecto.Query, warn: false
  import Ankole.SignalsGateway.ActorRuntime.Common, only: [collect_results: 1]

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.SignalsGateway.ActorEventTypes
  alias Ankole.SystemConfig

  @daily_reset_time ~T[04:30:00]
  @session_lifecycle_binding_name "control-plane:session-lifecycle"

  @spec enqueue_daily_session_resets(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_daily_session_resets(opts \\ [])

  def enqueue_daily_session_resets(opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, boundary_at, timezone} <- daily_reset_boundary_at(now, opts) do
      enqueue_daily_session_resets(boundary_at, Keyword.put(opts, :timezone, timezone))
    end
  end

  def enqueue_daily_session_resets(%DateTime{} = boundary_at) do
    enqueue_daily_session_resets(boundary_at, [])
  end

  @spec enqueue_daily_session_resets(DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def enqueue_daily_session_resets(%DateTime{} = boundary_at, opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    timezone = Keyword.get(opts, :timezone, SystemConfig.default_timezone())

    Repo.transact(fn repo ->
      conversations = due_daily_reset_conversations(repo, boundary_at, opts)

      conversations
      |> Enum.map(&enqueue_session_reset_due_in_tx(repo, &1, boundary_at, now, opts))
      |> collect_results()
      |> case do
        {:ok, events} ->
          {:ok,
           %{
             status: :enqueued,
             boundary_at: boundary_at,
             timezone: timezone,
             due_sessions: length(conversations),
             actor_events: events
           }}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp daily_reset_boundary_at(%DateTime{} = now, opts) do
    with {:ok, timezone} <- daily_reset_timezone(opts),
         {:ok, reset_time} <- daily_reset_time(opts),
         {:ok, local_now} <- shift_zone(now, timezone),
         date <- daily_reset_date(local_now, reset_time),
         {:ok, local_boundary} <- datetime_in_timezone(date, reset_time, timezone),
         {:ok, boundary_at} <- DateTime.shift_zone(local_boundary, "Etc/UTC") do
      {:ok, boundary_at, timezone}
    end
  end

  defp daily_reset_timezone(opts) do
    case Keyword.fetch(opts, :timezone) do
      {:ok, timezone} when is_binary(timezone) ->
        {:ok, normalize_timezone(timezone)}

      {:ok, _timezone} ->
        {:error, :invalid_timezone}

      :error ->
        SystemConfig.timezone()
    end
  end

  defp normalize_timezone("UTC"), do: "Etc/UTC"
  defp normalize_timezone(timezone), do: timezone

  defp daily_reset_time(opts) do
    opts
    |> Keyword.get(:reset_time, @daily_reset_time)
    |> normalize_reset_time()
  end

  defp normalize_reset_time(%Time{} = time), do: {:ok, Time.truncate(time, :second)}
  defp normalize_reset_time({hour, minute}), do: Time.new(hour, minute, 0)
  defp normalize_reset_time({hour, minute, second}), do: Time.new(hour, minute, second)
  defp normalize_reset_time(_value), do: {:error, :invalid_reset_time}

  defp shift_zone(%DateTime{} = now, timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, local_now} -> {:ok, local_now}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp daily_reset_date(%DateTime{} = local_now, %Time{} = reset_time) do
    date = DateTime.to_date(local_now)

    case Time.compare(DateTime.to_time(local_now), reset_time) do
      :lt -> Date.add(date, -1)
      _comparison -> date
    end
  end

  defp datetime_in_timezone(%Date{} = date, %Time{} = time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first_datetime, _second_datetime} -> {:ok, first_datetime}
      {:gap, _before_gap, after_gap} -> {:ok, after_gap}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp due_daily_reset_conversations(repo, %DateTime{} = boundary_at, opts) do
    AIGatewayLink.daily_reset_candidates_in_tx(repo, boundary_at, opts)
  end

  defp enqueue_session_reset_due_in_tx(
         repo,
         %{subject_uid: subject_uid, conversation_key: conversation_key} = conversation,
         %DateTime{} = boundary_at,
         %DateTime{} = now,
         opts
       ) do
    timezone = Keyword.get(opts, :timezone, SystemConfig.default_timezone())
    binding_name = Keyword.get(opts, :binding_name, @session_lifecycle_binding_name)
    event_id = session_reset_due_event_id(conversation, boundary_at)

    with {:ok, reset_time} <- daily_reset_time(opts) do
      Actors.append_actor_event_in_tx(repo, %{
        agent_uid: subject_uid,
        binding_name: binding_name,
        session_id: conversation_key,
        source_event_id: event_id,
        type: "session.reset_due",
        available_at: now,
        sender_key: nil,
        payload:
          session_reset_due_payload(
            conversation,
            event_id,
            boundary_at,
            timezone,
            reset_time,
            now,
            binding_name
          )
      })
    end
  end

  defp session_reset_due_event_id(
         %{subject_uid: subject_uid, conversation_key: conversation_key},
         %DateTime{} = boundary_at
       ) do
    "session.reset_due:daily:" <>
      subject_uid <>
      ":" <>
      conversation_key <>
      ":" <>
      DateTime.to_iso8601(boundary_at)
  end

  defp session_reset_due_payload(
         %{subject_uid: subject_uid, conversation_key: conversation_key},
         event_id,
         %DateTime{} = boundary_at,
         timezone,
         %Time{} = reset_time,
         %DateTime{} = now,
         binding_name
       ) do
    %{
      "specversion" => "1.0",
      "id" => event_id,
      "source" => "control-plane://session-reset/daily",
      "subject" => "sessions:#{conversation_key}",
      "time" => DateTime.to_iso8601(now),
      "type" => "session.reset_due",
      "data" => %{
        "session" => %{
          "agent_uid" => subject_uid,
          "session_id" => conversation_key,
          "binding_name" => binding_name
        },
        "reset" => %{
          "kind" => "daily",
          "boundary_at" => DateTime.to_iso8601(boundary_at),
          "timezone" => timezone,
          "local_time" => reset_time_label(reset_time)
        }
      }
    }
  end

  defp reset_time_label(%Time{} = reset_time) do
    reset_time
    |> Time.to_iso8601()
    |> String.replace_suffix(":00", "")
  end

  def process_due(actor_key, %ActorEvent{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    reset_at = reset_boundary_at(input, now)

    Repo.transact(fn repo ->
      with %ActorEvent{} = input <- Actors.lock_actor_event_in_tx(repo, input.id),
           false <- TurnLifecycle.live_delivery_for_session?(repo, actor_key),
           {:ok, closed_conversation} <- close_current_session_for_reset(repo, actor_key, now),
           {:ok, conversation} <-
             ensure_successor_conversation(repo, actor_key, closed_conversation),
           {:ok, stale_events} <- discard_stale_system_events_after_reset(repo, actor_key, input),
           {:ok, cron_reset} <-
             Schedule.cancel_due_cron_events_for_reset_in_tx(repo, actor_key, reset_at, now),
           {:ok, completed_event} <-
             Actors.complete_session_lifecycle_event_in_tx(repo, input, completed_at: now) do
        {:ok,
         %{
           status: :session_reset,
           reset_event: input,
           closed_conversation: closed_conversation,
           conversation: conversation,
           stale_system_events: stale_events,
           cron_reset: cron_reset,
           actor_event: completed_event
         }}
      else
        nil ->
          {:ok, %{status: :idle}}

        true ->
          {:ok,
           %{status: :waiting_for_generation, reason: :session_reset_due, actor_event: input}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp reset_boundary_at(%ActorEvent{payload: payload, available_at: available_at}, fallback)
       when is_map(payload) do
    case get_in(payload, ["data", "reset", "boundary_at"]) do
      boundary_at when is_binary(boundary_at) ->
        case DateTime.from_iso8601(boundary_at) do
          {:ok, datetime, _offset} ->
            DateTime.shift_zone!(datetime, "Etc/UTC")

          {:error, _reason} ->
            available_at || fallback
        end

      _value ->
        available_at || fallback
    end
  end

  defp reset_boundary_at(%ActorEvent{available_at: available_at}, fallback),
    do: available_at || fallback

  defp close_current_session_for_reset(repo, actor_key, now) do
    actor_event_id = current_actor_event_id_for_actor(repo, actor_key)

    case AIGatewayLink.active_conversation_for_update(
           repo,
           actor_key.agent_uid,
           actor_key.session_id
         ) do
      %{} ->
        with {:ok, _cancelled_turn} <-
               TurnLifecycle.cancel_started_turn_in_tx(
                 repo,
                 actor_key,
                 actor_event_id,
                 now,
                 "session.reset_due"
               ),
             {:ok, conversation} <-
               AIGatewayLink.end_active_conversation_in_tx(
                 repo,
                 actor_key.agent_uid,
                 actor_key.session_id,
                 now
               ) do
          {:ok, conversation}
        end

      nil ->
        {:ok, nil}
    end
  end

  defp current_actor_event_id_for_actor(repo, actor_key) do
    case TurnLifecycle.lock_live_activation(repo, actor_key) do
      %{current_actor_event_id: actor_event_id} when is_binary(actor_event_id) -> actor_event_id
      _activation -> nil
    end
  end

  defp ensure_successor_conversation(_repo, _actor_key, nil), do: {:ok, nil}

  defp ensure_successor_conversation(repo, actor_key, %{} = previous_conversation) do
    AIGatewayLink.ensure_conversation_in_tx(
      repo,
      actor_key.agent_uid,
      actor_key.session_id,
      AIGatewayLink.successor_brain_metadata(previous_conversation)
    )
  end

  defp discard_stale_system_events_after_reset(repo, actor_key, %ActorEvent{} = reset_event) do
    stale_events =
      ActorEvent
      |> where([input], input.agent_uid == ^actor_key.agent_uid)
      |> where([input], input.session_id == ^actor_key.session_id)
      |> where([input], input.input_state == "open")
      |> where([input], input.queue_sequence > ^reset_event.queue_sequence)
      |> order_by([input], asc: input.queue_sequence)
      |> lock("FOR UPDATE")
      |> repo.all()
      |> Enum.filter(&ActorEventTypes.stale_after_session_reset?/1)

    stale_event_ids = Enum.map(stale_events, & &1.id)

    with :ok <- delete_delivery_projections(repo, stale_event_ids),
         :ok <- delete_actor_events(repo, stale_event_ids) do
      {:ok, stale_events}
    end
  end

  defp delete_delivery_projections(_repo, []), do: :ok

  defp delete_delivery_projections(repo, actor_event_ids) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id in ^actor_event_ids)
    |> repo.delete_all()

    :ok
  end

  defp delete_actor_events(_repo, []), do: :ok

  defp delete_actor_events(repo, actor_event_ids) do
    ActorEvent
    |> where([input], input.id in ^actor_event_ids)
    |> repo.delete_all()

    :ok
  end
end
