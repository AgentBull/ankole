defmodule Ankole.RuntimeEvents.Scheduler do
  @moduledoc false

  use GenServer

  alias Ankole.Logging
  alias Ankole.RuntimeEvents.Handlers

  @actor_session_ready "ankole_actor_session_ready"
  @outbox_due "ankole_outbox_due"
  @inbound_batch_due "ankole_inbound_batch_due"
  @worker_deadline "ankole_worker_deadline"
  @worker_stale @worker_deadline <> ":stale"
  @worker_delete @worker_deadline <> ":delete"
  @activation_deadline "ankole_activation_deadline"
  @ai_message_deadline "ankole_ai_message_deadline"

  @type timer_key :: term()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec notify(GenServer.server(), String.t(), map()) :: :ok
  def notify(server \\ __MODULE__, channel, payload) do
    GenServer.cast(server, {:notify, channel, payload})
  end

  @spec hydrate(GenServer.server()) :: :ok
  def hydrate(server \\ __MODULE__) do
    GenServer.cast(server, :hydrate)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       task_supervisor: Keyword.get(opts, :task_supervisor, Ankole.RuntimeEvents.TaskSupervisor),
       timers: %{}
     }}
  end

  @impl true
  def handle_cast(:hydrate, state) do
    state =
      Handlers.snapshot_events()
      |> Enum.reduce(state, fn {channel, payload}, acc ->
        schedule_or_run(acc, channel, payload)
      end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:notify, channel, payload}, state) do
    {:noreply, schedule_or_run(state, channel, payload)}
  end

  @impl true
  def handle_info({:deadline, key, ref}, state) do
    case Map.get(state.timers, key) do
      %{ref: ^ref, channel: channel, payload: payload} ->
        state = %{state | timers: Map.delete(state.timers, key)}
        run_handler(state, channel, payload)
        {:noreply, state}

      _stale_timer ->
        {:noreply, state}
    end
  end

  defp schedule_or_run(state, channel, payload) do
    channel
    |> expand_payload(payload)
    |> Enum.reduce(state, fn {event_channel, event_payload}, acc ->
      case due_at(event_channel, event_payload) do
        nil ->
          run_handler(acc, event_channel, event_payload)
          acc

        %DateTime{} = due_at ->
          schedule_at(acc, event_channel, event_payload, due_at)
      end
    end)
  end

  defp expand_payload(channel, payload) when channel == @worker_deadline do
    []
    |> maybe_add_deadline(@worker_stale, payload, "stale_at")
    |> maybe_add_deadline(@worker_delete, payload, "delete_at")
  end

  defp expand_payload(channel, payload), do: [{channel, payload}]

  defp maybe_add_deadline(events, channel, payload, field) do
    case payload[field] do
      value when is_binary(value) -> [{channel, Map.put(payload, "due_at", value)} | events]
      _value -> events
    end
  end

  defp due_at(channel, payload) when channel == @actor_session_ready,
    do: decode_datetime(payload["due_at"])

  defp due_at(channel, payload) when channel == @outbox_due,
    do: decode_datetime(payload["due_at"])

  defp due_at(channel, payload) when channel == @inbound_batch_due,
    do: decode_datetime(payload["due_at"])

  defp due_at(channel, payload) when channel == @activation_deadline,
    do: decode_datetime(payload["lease_expires_at"])

  defp due_at(channel, payload) when channel == @ai_message_deadline,
    do: decode_datetime(payload["orphan_at"])

  defp due_at(channel, payload)
       when channel in [@worker_stale, @worker_delete],
       do: decode_datetime(payload["due_at"])

  defp due_at(_channel, _payload), do: nil

  defp schedule_at(state, channel, payload, due_at) do
    now = DateTime.utc_now(:microsecond)

    case DateTime.compare(due_at, now) do
      :gt ->
        key = timer_key(channel, payload)
        state = cancel_existing_timer(state, key)
        ref = make_ref()
        delay_ms = max(DateTime.diff(due_at, now, :millisecond), 0)
        timer = Process.send_after(self(), {:deadline, key, ref}, delay_ms)

        put_in(state, [:timers, key], %{
          ref: ref,
          timer: timer,
          channel: channel,
          payload: payload
        })

      _due ->
        run_handler(state, channel, payload)
        state
    end
  end

  defp cancel_existing_timer(state, key) do
    case Map.get(state.timers, key) do
      %{timer: timer} -> Process.cancel_timer(timer, async: true, info: false)
      _missing -> :ok
    end

    %{state | timers: Map.delete(state.timers, key)}
  end

  defp run_handler(state, channel, payload) do
    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           Handlers.handle(channel, payload)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "runtime_events.scheduler.handler_start_failed",
          "runtime event handler start failed",
          %{
            channel: channel,
            reason: inspect(reason)
          }
        )
    end
  end

  defp timer_key(channel, %{"agent_uid" => agent_uid, "session_id" => session_id})
       when channel == @actor_session_ready,
       do: {channel, agent_uid, session_id}

  defp timer_key(channel, %{
         "agent_uid" => agent_uid,
         "binding_name" => binding_name,
         "outbound_key" => outbound_key
       })
       when channel == @outbox_due,
       do: {channel, agent_uid, binding_name, outbound_key}

  defp timer_key(channel, %{"batch_id" => batch_id})
       when channel == @inbound_batch_due,
       do: {channel, batch_id}

  defp timer_key(channel, %{"worker_id" => worker_id})
       when channel in [@worker_stale, @worker_delete],
       do: {channel, worker_id}

  defp timer_key(channel, %{"activation_uid" => activation_uid})
       when channel == @activation_deadline,
       do: {channel, activation_uid}

  defp timer_key(channel, %{"message_id" => message_id})
       when channel == @ai_message_deadline,
       do: {channel, message_id}

  defp timer_key(channel, payload), do: {channel, payload}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp decode_datetime(_value), do: nil
end
