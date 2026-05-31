defmodule BullX.MailBox.Runtime do
  @moduledoc """
  Ephemeral MailBox scheduler.

  PostgreSQL stores accepted pending mail. This process owns the short-lived
  scheduling state around those rows: queue order, timers, coalesce pressure,
  and in-flight markers. If it crashes, it rebuilds from `mailbox_entries`.
  """

  use GenServer

  import Ecto.Query

  alias BullX.MailBox.Entry
  alias BullX.Repo

  @task_supervisor BullX.MailBox.RuntimeTaskSupervisor
  @default_claim_limit 20
  @default_interval_ms 500

  @type process_result ::
          {:ok, [String.t()]}
          | {:defer, non_neg_integer()}
          | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec accepted(Entry.t(), GenServer.server()) :: :ok
  def accepted(%Entry{} = entry, name \\ __MODULE__) do
    call_or_default(name, {:accepted, entry}, :ok)
  end

  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(name \\ __MODULE__) do
    with {:ok, entries} <- load_pending_entries() do
      call_or_default(name, {:replace_entries, entries}, {:error, :mailbox_runtime_not_started})
    end
  end

  @spec process_ready(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_ready(limit \\ @default_claim_limit, opts \\ [])
      when is_integer(limit) and limit > 0 and is_list(opts) do
    name = Keyword.get(opts, :runtime, __MODULE__)

    case claim_ready(limit, name) do
      {:ok, entries} ->
        process_claimed(entries, opts)
        {:ok, length(entries)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec next_ready_at(GenServer.server()) :: DateTime.t() | nil
  def next_ready_at(name \\ __MODULE__) do
    call_or_default(name, :next_ready_at, nil)
  end

  @spec force_ready(GenServer.server()) :: :ok
  def force_ready(name \\ __MODULE__) do
    call_or_default(name, :force_ready, :ok)
  end

  @spec in_flight?(String.t(), GenServer.server()) :: boolean()
  def in_flight?(entry_id, name \\ __MODULE__) when is_binary(entry_id) do
    call_or_default(name, {:in_flight?, entry_id}, false)
  end

  @spec mark_in_flight([Entry.t()], String.t(), GenServer.server()) :: :ok
  def mark_in_flight(entries, queue_key, name \\ __MODULE__)
  def mark_in_flight([], _queue_key, _name), do: :ok

  def mark_in_flight(entries, queue_key, name)
      when is_list(entries) and is_binary(queue_key) do
    ids = Enum.map(entries, & &1.id)
    call_or_default(name, {:mark_in_flight, ids, queue_key}, :ok)
  end

  @spec replace_entry(Entry.t(), GenServer.server()) :: :ok
  def replace_entry(%Entry{} = entry, name \\ __MODULE__) do
    call_or_default(name, {:replace_entry, entry}, :ok)
  end

  @spec complete(String.t(), process_result(), GenServer.server()) :: :ok
  def complete(entry_id, result, name \\ __MODULE__) when is_binary(entry_id) do
    call_or_default(name, {:complete, entry_id, result}, :ok)
  end

  @impl true
  def init(opts) do
    state =
      new_state(opts)
      |> put_loaded_entries(load_pending_entries_for_init())

    state =
      case state.dispatch? do
        true -> schedule_next(state, 0)
        false -> state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:accepted, %Entry{} = entry}, _from, state) do
    state =
      state
      |> put_entry(entry)
      |> maybe_dispatch_immediate_control(entry)
      |> maybe_schedule_next()

    {:reply, :ok, state}
  end

  def handle_call({:replace_entries, entries}, _from, state) when is_list(entries) do
    state =
      state
      |> reset_entries()
      |> put_loaded_entries(entries)
      |> maybe_schedule_next()

    {:reply, :ok, state}
  end

  def handle_call({:mark_in_flight, ids, queue_key}, _from, state)
      when is_list(ids) and is_binary(queue_key) do
    {:reply, :ok, mark_ids_in_flight(state, ids, queue_key, true)}
  end

  def handle_call({:replace_entry, %Entry{} = entry}, _from, state) do
    {:reply, :ok, %{state | entries: Map.put(state.entries, entry.id, entry)}}
  end

  def handle_call({:complete, entry_id, result}, _from, state) do
    state =
      state
      |> apply_completion(entry_id, result)
      |> maybe_schedule_next()

    {:reply, :ok, state}
  end

  def handle_call({:in_flight?, entry_id}, _from, state) do
    {:reply, Map.has_key?(state.in_flight, entry_id), state}
  end

  def handle_call({:claim_ready, limit}, _from, state) do
    {entries, state} = claim_ready_entries(state, limit, utc_now())
    {:reply, {:ok, entries}, maybe_schedule_next(state)}
  end

  def handle_call(:next_ready_at, _from, state) do
    {:reply, next_due_at(state, utc_now()), state}
  end

  def handle_call(:force_ready, _from, state) do
    ids = Map.keys(state.entries)

    state =
      %{state | ready_ids: MapSet.union(state.ready_ids, MapSet.new(ids))}
      |> maybe_schedule_next()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:dispatch, timer_id}, %{timer_id: timer_id} = state) do
    state = %{state | timer_id: nil, timer_ref: nil}
    {entries, state} = claim_ready_entries(state, state.claim_limit, utc_now())
    process_claimed(entries, async?: true)

    {:noreply, maybe_schedule_next(state)}
  end

  def handle_info({:dispatch, _stale_timer_id}, state), do: {:noreply, state}

  defp claim_ready(limit, name) do
    call_or_default(name, {:claim_ready, limit}, {:error, :mailbox_runtime_not_started})
  end

  defp process_claimed(entries, opts) do
    async? = Keyword.get(opts, :async?, false)
    Enum.each(entries, &process_or_start(&1, opts, async?))
  end

  defp process_or_start(%Entry{} = entry, opts, true) do
    start_child(fn -> process_claimed_entry(entry, opts) end)
  end

  defp process_or_start(%Entry{} = entry, opts, false) do
    _result = process_claimed_entry(entry, opts)
    :ok
  end

  defp process_claimed_entry(%Entry{} = entry, opts) do
    result = BullX.MailBox.process_entry_result(entry, opts)
    complete(entry.id, result)

    case result do
      {:error, reason} -> {:error, reason}
      _ok_or_defer -> :ok
    end
  end

  defp start_child(fun) when is_function(fun, 0) do
    case Process.whereis(@task_supervisor) do
      nil ->
        _result = Task.start(fun)
        :ok

      _pid ->
        _result = Task.Supervisor.start_child(@task_supervisor, fun)
        :ok
    end
  end

  defp new_state(opts) do
    %{
      entries: %{},
      in_flight: %{},
      active_queues: MapSet.new(),
      deferred_until: %{},
      ready_ids: MapSet.new(),
      pressure: %{},
      dispatch?: Keyword.get(opts, :dispatch?, true),
      control_dispatch?: Keyword.get(opts, :control_dispatch?, true),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      claim_limit: Keyword.get(opts, :claim_limit, @default_claim_limit),
      timer_ref: nil,
      timer_id: nil
    }
  end

  defp reset_entries(state) do
    %{
      state
      | entries: %{},
        in_flight: %{},
        active_queues: MapSet.new(),
        deferred_until: %{},
        ready_ids: MapSet.new(),
        pressure: %{}
    }
  end

  defp put_loaded_entries(state, entries) do
    Enum.reduce(entries, state, &put_entry(&2, &1))
  end

  defp put_entry(state, %Entry{} = entry) do
    state
    |> put_in([:entries, entry.id], entry)
    |> record_coalesce_pressure(entry)
  end

  defp claim_ready_entries(state, limit, now) do
    candidates =
      state.entries
      |> Map.values()
      |> Enum.reject(&Map.has_key?(state.in_flight, &1.id))
      |> Enum.sort_by(&entry_sort_key/1)

    {controls, state} = claim_controls(candidates, state, limit, now)
    remaining = max(limit - length(controls), 0)
    blocked_scopes = MapSet.new(controls, &queue_scope/1)

    {normal_entries, state} =
      claim_normal_entries(candidates, state, remaining, now, blocked_scopes)

    {controls ++ normal_entries, state}
  end

  defp claim_controls(_candidates, state, 0, _now), do: {[], state}

  defp claim_controls(candidates, state, limit, now) do
    entries =
      candidates
      |> Enum.filter(&control_entry?/1)
      |> Enum.filter(&due?(&1, state, now))
      |> Enum.take(limit)

    {entries, mark_entries_in_flight(state, entries, false)}
  end

  defp claim_normal_entries(_candidates, state, 0, _now, _blocked_scopes), do: {[], state}

  defp claim_normal_entries(candidates, state, limit, now, blocked_scopes) do
    entries =
      candidates
      |> Enum.reject(&control_entry?/1)
      |> Enum.reject(&MapSet.member?(state.active_queues, queue_scope(&1)))
      |> Enum.reject(&MapSet.member?(blocked_scopes, queue_scope(&1)))
      |> Enum.filter(&due?(&1, state, now))
      |> Enum.group_by(&queue_scope/1)
      |> Enum.map(fn {_scope, entries} -> Enum.min_by(entries, &entry_sort_key/1) end)
      |> Enum.sort_by(&entry_sort_key/1)
      |> Enum.take(limit)

    {entries, mark_entries_in_flight(state, entries, true)}
  end

  defp mark_entries_in_flight(state, entries, blocks_queue?) do
    Enum.reduce(entries, state, fn entry, acc ->
      mark_ids_in_flight(acc, [entry.id], entry.queue_key, blocks_queue?)
    end)
  end

  defp mark_ids_in_flight(state, ids, queue_key, blocks_queue?) do
    in_flight =
      Enum.reduce(ids, state.in_flight, fn id, acc ->
        entry = Map.get(state.entries, id)

        Map.put(acc, id, %{
          queue_scope: queue_scope(entry, queue_key),
          blocks_queue?: blocks_queue?
        })
      end)

    %{state | in_flight: in_flight}
    |> rebuild_active_queues()
  end

  defp apply_completion(state, _entry_id, {:ok, ids}) when is_list(ids) do
    remove_entry_ids(state, ids)
  end

  defp apply_completion(state, entry_id, {:defer, delay_ms})
       when is_integer(delay_ms) and delay_ms >= 0 do
    retry_at = DateTime.add(utc_now(), delay_ms, :millisecond)

    state
    |> release_in_flight([entry_id])
    |> put_in([:deferred_until, entry_id], retry_at)
  end

  defp apply_completion(state, entry_id, {:error, _reason}) do
    remove_entry_ids(state, [entry_id])
  end

  defp remove_entry_ids(state, ids) do
    id_set = MapSet.new(ids)

    %{
      state
      | entries: Map.drop(state.entries, ids),
        in_flight: Map.drop(state.in_flight, ids),
        deferred_until: Map.drop(state.deferred_until, ids),
        ready_ids: MapSet.difference(state.ready_ids, id_set),
        pressure: drop_pressure_ids(state.pressure, id_set)
    }
    |> rebuild_active_queues()
  end

  defp release_in_flight(state, ids) do
    %{state | in_flight: Map.drop(state.in_flight, ids)}
    |> rebuild_active_queues()
  end

  defp rebuild_active_queues(state) do
    active_queues =
      state.in_flight
      |> Map.values()
      |> Enum.filter(& &1.blocks_queue?)
      |> Enum.map(& &1.queue_scope)
      |> MapSet.new()

    %{state | active_queues: active_queues}
  end

  defp due?(%Entry{} = entry, state, now) do
    entry
    |> due_at(state)
    |> DateTime.compare(now)
    |> case do
      :gt -> false
      _lte -> true
    end
  end

  defp next_due_at(state, now) do
    state.entries
    |> Map.values()
    |> Enum.reject(&Map.has_key?(state.in_flight, &1.id))
    |> Enum.reject(&blocked_by_active_queue?(&1, state))
    |> Enum.map(&due_at(&1, state))
    |> Enum.reject(&is_nil/1)
    |> min_datetime()
    |> normalize_elapsed(now)
  end

  defp blocked_by_active_queue?(%Entry{} = entry, state) do
    not control_entry?(entry) and MapSet.member?(state.active_queues, queue_scope(entry))
  end

  defp due_at(%Entry{} = entry, state) do
    cond do
      MapSet.member?(state.ready_ids, entry.id) ->
        entry_timestamp(entry)

      Map.has_key?(state.deferred_until, entry.id) ->
        Map.fetch!(state.deferred_until, entry.id)

      true ->
        coalesce_due_at(entry)
    end
  end

  defp normalize_elapsed(nil, _now), do: nil

  defp normalize_elapsed(%DateTime{} = datetime, now) do
    case DateTime.compare(datetime, now) do
      :lt -> now
      _gte -> datetime
    end
  end

  defp maybe_schedule_next(%{dispatch?: false} = state), do: state

  defp maybe_schedule_next(%{dispatch?: true} = state) do
    case next_due_at(state, utc_now()) do
      nil -> cancel_timer(state)
      %DateTime{} = due_at -> schedule_earlier(state, delay_until(due_at))
    end
  end

  defp schedule_earlier(%{timer_ref: nil} = state, delay_ms),
    do: schedule_next(state, delay_ms)

  defp schedule_earlier(%{timer_ref: timer_ref} = state, delay_ms) do
    case Process.read_timer(timer_ref) do
      remaining_ms when is_integer(remaining_ms) and remaining_ms <= delay_ms ->
        state

      _remaining_ms ->
        state
        |> cancel_timer()
        |> schedule_next(delay_ms)
    end
  end

  defp schedule_next(%{dispatch?: false} = state, _delay_ms), do: state

  defp schedule_next(state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    timer_id = make_ref()
    timer_ref = Process.send_after(self(), {:dispatch, timer_id}, delay_ms)
    %{state | timer_id: timer_id, timer_ref: timer_ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil, timer_id: nil}
  end

  defp record_coalesce_pressure(state, %Entry{} = entry) do
    case coalesce_config(entry) do
      {:ok, window_ms, max_chars} ->
        now = utc_now()
        key = {entry.agent_uid, entry.queue_key, coalesce_actor_key(entry)}
        pressure = drop_expired_pressure(state.pressure, key, now)

        batch =
          Map.get(pressure, key) ||
            %{ids: [], chars: 0, deadline: coalesce_due_at(entry, window_ms)}

        batch = %{
          batch
          | ids: batch.ids ++ [entry.id],
            chars: batch.chars + text_chars(entry),
            deadline: earliest_datetime(batch.deadline, coalesce_due_at(entry, window_ms))
        }

        case batch.chars >= max_chars do
          true ->
            %{
              state
              | pressure: Map.delete(pressure, key),
                ready_ids: MapSet.union(state.ready_ids, MapSet.new(batch.ids))
            }

          false ->
            %{state | pressure: Map.put(pressure, key, batch)}
        end

      :skip ->
        state
    end
  end

  defp drop_expired_pressure(pressure, key, now) do
    case Map.fetch(pressure, key) do
      {:ok, %{deadline: deadline}} ->
        case DateTime.compare(deadline, now) do
          :gt -> pressure
          _expired -> Map.delete(pressure, key)
        end

      :error ->
        pressure
    end
  end

  defp drop_pressure_ids(pressure, id_set) do
    pressure
    |> Enum.reduce(%{}, fn {key, batch}, acc ->
      ids = Enum.reject(batch.ids, &MapSet.member?(id_set, &1))

      case ids do
        [] -> acc
        [_ | _] -> Map.put(acc, key, %{batch | ids: ids})
      end
    end)
  end

  defp coalesce_config(%Entry{
         cloud_event: %{
           "type" => "bullx.message.received",
           "data" => %{"coalesce" => %{} = config}
         }
       }) do
    window_ms = integer_value(config["window_ms"], 0)
    max_chars = integer_value(config["max_chars"], 0)

    case window_ms > 0 and max_chars > 0 do
      true -> {:ok, window_ms, max_chars}
      false -> :skip
    end
  end

  defp coalesce_config(_entry), do: :skip

  defp coalesce_due_at(%Entry{} = entry) do
    case coalesce_config(entry) do
      {:ok, window_ms, _max_chars} -> coalesce_due_at(entry, window_ms)
      :skip -> entry_timestamp(entry)
    end
  end

  defp coalesce_due_at(%Entry{} = entry, window_ms) do
    entry
    |> entry_timestamp()
    |> DateTime.add(window_ms, :millisecond)
  end

  defp control_entry?(%Entry{cloud_event: %{"type" => type}}),
    do: BullX.MailBox.control_event_type?(type)

  defp control_entry?(_entry), do: false

  defp maybe_dispatch_immediate_control(%{control_dispatch?: true} = state, %Entry{} = entry) do
    case control_entry?(entry) do
      true ->
        {entries, state} = claim_controls([entry], state, 1, utc_now())
        process_claimed(entries, async?: true)
        state

      false ->
        state
    end
  end

  defp maybe_dispatch_immediate_control(state, _entry), do: state

  defp coalesce_actor_key(%Entry{} = entry) do
    data = get_in(entry.cloud_event, ["data"]) || %{}

    get_in(data, ["actor", "principal", "uid"]) ||
      get_in(data, ["actor", "external_account_id"]) ||
      get_in(data, ["actor", "id"]) ||
      ""
  end

  defp text_chars(%Entry{} = entry), do: String.length(entry_text(entry))

  defp entry_text(%Entry{} = entry) do
    entry.cloud_event
    |> get_in(["data", "content"])
    |> List.wrap()
    |> Enum.flat_map(&content_text/1)
    |> Enum.join("\n")
  end

  defp content_text(%{"type" => "text", "text" => text}) when is_binary(text), do: [text]
  defp content_text(%{"text" => text}) when is_binary(text), do: [text]
  defp content_text(_block), do: []

  defp entry_timestamp(%Entry{inserted_at: %DateTime{} = inserted_at}), do: inserted_at
  defp entry_timestamp(_entry), do: utc_now()

  defp entry_sort_key(%Entry{entry_seq: entry_seq}) when is_integer(entry_seq), do: entry_seq
  defp entry_sort_key(%Entry{id: id}), do: id

  defp queue_scope(%Entry{agent_uid: agent_uid, queue_key: queue_key}), do: {agent_uid, queue_key}
  defp queue_scope(nil, queue_key), do: {nil, queue_key}
  defp queue_scope(%Entry{} = entry, _queue_key), do: queue_scope(entry)

  defp earliest_datetime(left, right) do
    case DateTime.compare(left, right) do
      :lt -> left
      _gte -> right
    end
  end

  defp min_datetime([]), do: nil
  defp min_datetime([datetime | rest]), do: Enum.reduce(rest, datetime, &earliest_datetime/2)

  defp delay_until(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.diff(utc_now(), :millisecond)
    |> max(0)
  end

  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default

  defp load_pending_entries do
    {:ok,
     Entry
     |> order_by([entry], asc: entry.entry_seq)
     |> Repo.all()}
  rescue
    reason -> {:error, reason}
  end

  defp load_pending_entries_for_init do
    case load_pending_entries() do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp call_or_default(name, message, default) do
    case GenServer.whereis(name) do
      nil ->
        default

      pid ->
        try do
          GenServer.call(pid, message)
        catch
          :exit, _reason -> default
        end
    end
  end

  defp utc_now, do: DateTime.utc_now(:microsecond)
end
