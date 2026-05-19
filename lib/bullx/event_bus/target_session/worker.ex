defmodule BullX.EventBus.TargetSession.Worker do
  @moduledoc """
  Alive TargetSession Oban worker — one durable actor per (rule, scope, window).

  ## What a TargetSession is

  In an OpenClaw / Hermes-style harness, "the session" usually means *the
  conversation you are having with the agent* — a single, ambient context. In
  BullX, sessions are derived: each combination of routing rule + scope key
  (channel, thread, user, …) + time window gets its own TargetSession, and
  one Agent will typically have many sessions live at once — a DM with each
  of 50 users, the ambient observer for 12 group channels, a batch of
  scheduled ticks — each progressing independently but serialized internally.

  All events matching the same routing key land in the same session and are
  processed one at a time by a single worker, so a downstream Agent never
  needs locks around its LLM call, retry handling, or cross-event reasoning —
  concurrency control is structural. The actor identity comes from routing
  facts rather than being declared statically, its inbox is a Postgres-backed
  side-channel rather than an in-memory queue, and its state survives crashes:
  the worker can die and resume on another node by re-claiming the same
  TargetSession row.

  ## Internal contract

  One worker owns one active TargetSession window until terminal state or hard
  max runtime. Event payloads stay in side-channel entries, not job args.
  """

  use Oban.Worker, queue: :target_sessions, max_attempts: 20

  import Ecto.Query

  alias BullX.EventBus
  alias BullX.EventBus.{Config, Target, TargetSession, TargetSessionEntry}
  alias BullX.EventBus.TargetSession.Resolver
  alias BullX.Repo

  @registry BullX.EventBus.TargetSession.Registry

  @impl Oban.Worker
  def timeout(_job), do: :timer.hours(24) + :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"target_session_id" => target_session_id}}) do
    case Repo.get(TargetSession, target_session_id) do
      nil ->
        :ok

      %TargetSession{} ->
        register(target_session_id)
        # Targets call `TargetSession.close/1` and `attempt_close/1` without
        # receiving the session id explicitly; they read it from the process
        # dictionary. The close flag is buffered here until the current entry
        # finishes so an in-flight invocation can request close mid-callback
        # without racing the next `drain_one`.
        Process.put({TargetSession, :current_target_session_id}, target_session_id)
        emit(:started, %{target_session_id: target_session_id})

        try do
          case loop(target_session_id) do
            {:error, reason} = error ->
              emit(:failed, %{
                target_session_id: target_session_id,
                diagnostic_code: safe_reason(reason)
              })

              error

            other ->
              other
          end
        after
          Process.delete({TargetSession, :current_target_session_id})
          Process.delete({TargetSession, :close_requested})
        end
    end
  end

  def perform(_job), do: :ok

  def nudge(target_session_id) when is_binary(target_session_id) do
    Registry.dispatch(@registry, target_session_id, fn entries ->
      Enum.each(entries, fn {pid, _value} -> send(pid, :drain_pending_entries) end)
    end)
  rescue
    ArgumentError -> :ok
  end

  defp register(target_session_id) do
    case Registry.register(@registry, target_session_id, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp loop(target_session_id) do
    case terminal_state(target_session_id) do
      :active ->
        case drain_one(target_session_id) do
          :drained -> loop(target_session_id)
          :idle -> wait_idle(target_session_id)
          {:error, reason} -> {:error, reason}
        end

      :terminal ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wait_idle(target_session_id) do
    receive do
      :drain_pending_entries -> loop(target_session_id)
    after
      Config.target_session_idle_tick_ms() -> loop(target_session_id)
    end
  end

  # Not a pure read: when the locked session is active-but-past-expiry, this
  # transitions it to `:expired` inside the same `FOR UPDATE` so no concurrent
  # nudge can revive an expired window. Callers observe `:terminal` either way.
  defp terminal_state(target_session_id) do
    Repo.transaction(fn ->
      target_session_id
      |> lock_session_query()
      |> Repo.one()
      |> locked_terminal_state(DateTime.utc_now(:microsecond))
    end)
    |> case do
      {:ok, state} -> state
      {:error, reason} -> {:error, reason}
    end
  end

  defp locked_terminal_state(nil, _now), do: :terminal

  defp locked_terminal_state(%TargetSession{status: status}, _now)
       when status in [:closed, :failed, :expired],
       do: :terminal

  defp locked_terminal_state(%TargetSession{} = session, now) do
    case Resolver.expiry_reason(session, now) do
      nil -> :active
      reason -> expire_session(session, reason)
    end
  end

  defp expire_session(%TargetSession{} = session, reason) do
    session
    |> TargetSession.changeset(%{status: :expired, terminal_reason: reason})
    |> Repo.update()
    |> case do
      {:ok, _session} -> :terminal
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp lock_session_query(target_session_id) do
    TargetSession
    |> where([s], s.id == ^target_session_id)
    |> lock("FOR UPDATE")
  end

  defp drain_one(target_session_id) do
    with %TargetSession{} = session <- Repo.get(TargetSession, target_session_id),
         %TargetSessionEntry{} = entry <- next_entry(session),
         :ok <- invoke(session, entry),
         {:ok, _session} <- advance_progress(session, entry) do
      emit(:completed_entry, %{
        target_session_id: session.id,
        target_session_entry_id: entry.id,
        entry_seq: entry.entry_seq
      })

      maybe_close_after_entry(target_session_id)
      :drained
    else
      nil -> :idle
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_entry(%TargetSession{} = session) do
    TargetSessionEntry
    |> where([e], e.target_session_id == ^session.id)
    |> where([e], e.entry_seq > ^session.last_processed_entry_seq)
    |> order_by([e], asc: e.entry_seq)
    |> limit(1)
    |> Repo.one()
  end

  defp invoke(%TargetSession{} = session, %TargetSessionEntry{} = entry) do
    invocation = %{
      target_session_id: session.id,
      event_routing_rule_id: session.event_routing_rule_id,
      target_type: session.target_type,
      target_ref: session.target_ref,
      scope_key: session.scope_key,
      window_key: session.window_key,
      close: fn -> TargetSession.close(session.id) end,
      fail: fn reason -> TargetSession.fail(session.id, reason) end,
      output: EventBus.StreamingOutput
    }

    side_channel_entry = %{
      id: entry.id,
      entry_seq: entry.entry_seq,
      target_session_id: entry.target_session_id,
      event_source: entry.event_source,
      event_id: entry.event_id,
      cloud_event: entry.cloud_event,
      routing_context: entry.routing_context,
      appended_at: entry.appended_at
    }

    Target.dispatch(invocation, side_channel_entry)
  end

  defp advance_progress(%TargetSession{} = session, %TargetSessionEntry{} = entry) do
    Repo.transaction(fn ->
      locked =
        TargetSession
        |> where([s], s.id == ^session.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case locked do
        nil ->
          Repo.rollback(:target_session_missing)

        %TargetSession{} = locked ->
          locked
          |> TargetSession.changeset(%{last_processed_entry_seq: entry.entry_seq})
          |> Repo.update()
          |> case do
            {:ok, session} -> session
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  defp maybe_close_after_entry(target_session_id) do
    case Process.get({TargetSession, :close_requested}) do
      true ->
        Process.delete({TargetSession, :close_requested})
        TargetSession.attempt_close(target_session_id)

      _other ->
        :ok
    end
  end

  defp emit(event, metadata) do
    :telemetry.execute([:bullx, :event_bus, :target_session, :worker, event], %{}, metadata)
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :error
end
