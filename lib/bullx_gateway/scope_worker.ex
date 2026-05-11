defmodule BullXGateway.ScopeWorker do
  @moduledoc """
  One process per `{{adapter, channel_id}, scope_id}`. Serializes outbound
  dispatches against the adapter.

  State is entirely in-memory: the queue, the current running delivery, the
  stream task ref, and retry counters all live in the GenServer's state. On a
  BEAM crash the queue is lost; Runtime + Oban is responsible for re-issuing
  any outstanding deliveries. No in-flight persistence, no crash recovery from
  the DB.

  The only durable write ScopeWorker performs is a `gateway_dead_letters` row
  on a terminal adapter failure that happens while ScopeWorker is alive. All
  other transitions are pure process state.
  """

  use GenServer, restart: :transient

  require Logger

  alias BullXGateway.AdapterRegistry
  alias BullXGateway.ControlPlane
  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Outcome
  alias BullXGateway.Dispatcher
  alias BullX.Retry
  alias BullXGateway.OutboundDeduper
  alias BullXGateway.ScopeRegistry
  alias BullXGateway.Telemetry
  alias Jido.Signal
  alias Jido.Signal.Bus

  @default_hibernate_ms 60_000
  @default_terminate_ms 5 * 60_000

  @type channel :: BullXGateway.Delivery.channel()

  def child_spec({channel, scope_id, opts}) do
    %{
      id: {__MODULE__, channel, scope_id},
      start: {__MODULE__, :start_link, [{channel, scope_id, opts}]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link({channel, scope_id, opts}) do
    GenServer.start_link(__MODULE__, {channel, scope_id, opts},
      name: ScopeRegistry.via(channel, scope_id)
    )
  end

  @doc """
  Enqueue a delivery on this scope's worker.
  """
  @spec enqueue(channel(), String.t(), Delivery.t()) :: :ok | {:error, term()}
  def enqueue(channel, scope_id, %Delivery{} = delivery) do
    case Dispatcher.ensure_started(channel, scope_id) do
      {:ok, pid} ->
        GenServer.cast(pid, {:enqueue, delivery})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cancel an in-flight `:stream`. Returns `:ok` when the intent is accepted
  (even if the adapter has already finished), `{:error, :not_found}` when no
  stream with `delivery_id` is in flight on this node.
  """
  @spec cancel_stream(String.t()) :: :ok | {:error, :not_found}
  def cancel_stream(delivery_id) when is_binary(delivery_id) do
    case find_worker_for_delivery(delivery_id) do
      {:ok, pid} -> GenServer.call(pid, {:cancel_stream, delivery_id})
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def init({channel, scope_id, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      channel: channel,
      scope_id: scope_id,
      adapter_module: nil,
      adapter_config: %{},
      adapter_anchor_pid: nil,
      adapter_monitor_ref: nil,
      retry_policy: Retry.default(),
      status: :idle,
      queue: [],
      retry_timers: %{},
      stream_attempts: %{},
      stream_intent: nil,
      attempts: %{},
      deliveries: %{},
      hibernate_ms: Keyword.get(opts, :hibernate_ms, @default_hibernate_ms),
      terminate_ms: Keyword.get(opts, :terminate_ms, @default_terminate_ms),
      hibernate_timer: nil,
      terminate_timer: nil
    }

    state = load_adapter_entry(state)

    {:ok, reset_idle_timers(state)}
  end

  @impl true
  def handle_cast({:enqueue, %Delivery{} = delivery}, state) do
    state = cancel_idle_timers(state)
    state = put_delivery(state, delivery)

    if state.status == :idle do
      {:noreply, start_next(%{state | queue: [delivery.id]})}
    else
      {:noreply, %{state | queue: state.queue ++ [delivery.id]}}
    end
  end

  @impl true
  def handle_call({:cancel_stream, delivery_id}, _from, state) do
    case state.status do
      {:running, ^delivery_id, {:stream, task}} ->
        cancelled_state = shutdown_stream_task(state, task, :user_cancel)
        {:reply, :ok, cancelled_state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:run, delivery_id}, state) do
    state = cancel_idle_timers(state)
    state = %{state | retry_timers: Map.delete(state.retry_timers, delivery_id)}

    case state.status do
      :idle ->
        {:noreply, attempt_delivery(state, delivery_id)}

      {:running, _other_id, _} ->
        {:noreply, %{state | queue: state.queue ++ [delivery_id]}}
    end
  end

  def handle_info({ref, result}, %{status: {:running, id, {:stream, %Task{ref: ref}}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finalize_stream(state, id, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{status: {:running, id, {:stream, %Task{ref: ref}}}} = state
      ) do
    error_map = synthesize_stream_error(state.stream_intent, reason)
    {:noreply, finalize_stream(state, id, {:error, error_map})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{adapter_monitor_ref: ref} = state) do
    new_state = %{state | adapter_monitor_ref: nil, adapter_anchor_pid: nil}

    case new_state.status do
      {:running, _id, {:stream, task}} ->
        {:noreply, shutdown_stream_task(new_state, task, :adapter_down)}

      _ ->
        {:noreply, new_state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:hibernate_idle, state) do
    if state.status == :idle and state.queue == [] do
      {:noreply, state, :hibernate}
    else
      {:noreply, state}
    end
  end

  def handle_info(:terminate_idle, state) do
    if state.status == :idle and state.queue == [] and map_size(state.retry_timers) == 0 do
      {:stop, :normal, state}
    else
      {:noreply, reset_idle_timers(state)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_idle_timers(state)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Core pipeline
  # ---------------------------------------------------------------------------

  defp attempt_delivery(state, delivery_id) do
    case Map.fetch(state.deliveries, delivery_id) do
      {:ok, delivery} ->
        attempt_num = Map.get(state.attempts, delivery_id, 0) + 1
        state = %{state | attempts: Map.put(state.attempts, delivery_id, attempt_num)}
        run_adapter(state, delivery, attempt_num)

      :error ->
        advance_next(%{state | status: :idle})
    end
  end

  defp run_adapter(state, delivery, attempt_num) do
    ctx = build_context(state)

    case delivery.op do
      op when op in [:send, :edit] ->
        run_sync(state, delivery, attempt_num, ctx)

      :stream ->
        run_stream(state, delivery, attempt_num, ctx)
    end
  end

  defp run_sync(state, delivery, attempt_num, ctx) do
    state = %{state | status: {:running, delivery.id, :send_edit}, stream_intent: nil}

    result =
      safe_adapter_call(fn ->
        state.adapter_module.deliver(delivery, ctx)
      end)

    handle_attempt_result(state, delivery, attempt_num, result)
  end

  defp run_stream(state, delivery, attempt_num, ctx) do
    enumerable = delivery.content
    adapter_module = state.adapter_module

    task =
      Task.Supervisor.async_nolink(Dispatcher.task_supervisor_name(), fn ->
        safe_adapter_call(fn -> adapter_module.stream(delivery, enumerable, ctx) end)
      end)

    %{
      state
      | status: {:running, delivery.id, {:stream, task}},
        stream_intent: nil,
        stream_attempts: Map.put(state.stream_attempts, delivery.id, attempt_num)
    }
  end

  defp finalize_stream(state, delivery_id, result) do
    {attempt_num, state} =
      case Map.pop(state.stream_attempts, delivery_id) do
        {nil, _} -> {Map.get(state.attempts, delivery_id, 1), state}
        {num, map} -> {num, %{state | stream_attempts: map}}
      end

    state = %{state | stream_intent: nil}

    case Map.fetch(state.deliveries, delivery_id) do
      {:ok, delivery} ->
        handle_attempt_result(state, delivery, attempt_num, result)

      :error ->
        advance_next(%{state | status: :idle})
    end
  end

  defp handle_attempt_result(state, delivery, attempt_num, result) do
    case normalize_result(delivery, result) do
      {:ok, %Outcome{} = outcome} ->
        record_success(state, delivery, attempt_num, outcome)

      {:error, error_map} ->
        record_failure(state, delivery, attempt_num, error_map)
    end
  end

  defp normalize_result(delivery, {:ok, %Outcome{status: status} = outcome})
       when status in [:sent, :degraded] do
    {:ok, %{outcome | delivery_id: delivery.id}}
  end

  defp normalize_result(delivery, {:ok, %Outcome{status: :failed}}) do
    {:error,
     %{
       "kind" => "contract",
       "message" =>
         "Adapter returned Outcome{status: :failed}; only ScopeWorker may produce :failed",
       "details" => %{"delivery_id" => delivery.id}
     }}
  end

  defp normalize_result(_delivery, {:ok, other}) do
    {:error,
     %{
       "kind" => "contract",
       "message" => "Adapter returned invalid success shape",
       "details" => %{"got" => inspect(other)}
     }}
  end

  defp normalize_result(_delivery, {:error, error_map}) when is_map(error_map) do
    {:error, error_map}
  end

  defp normalize_result(_delivery, other) do
    {:error,
     %{
       "kind" => "contract",
       "message" => "Adapter returned a value that is neither {:ok, _} nor {:error, _}",
       "details" => %{"got" => inspect(other)}
     }}
  end

  defp record_success(state, delivery, attempt_num, %Outcome{} = outcome) do
    case publish_outcome_signal(state, delivery, outcome) do
      :ok ->
        OutboundDeduper.mark_success(delivery.id, outcome)

        emit_telemetry(:finished, state, delivery, %{attempts: attempt_num}, %{
          outcome: outcome.status,
          error_kind: nil
        })

        advance_next(forget_delivery(%{state | status: :idle}, delivery.id))

      {:error, reason} ->
        Logger.error(
          "delivery success outcome publish failed for #{delivery.id}: #{inspect(reason)}"
        )

        advance_next(forget_delivery(%{state | status: :idle}, delivery.id))
    end
  end

  defp record_failure(state, delivery, attempt_num, error_map) do
    case Retry.classify(state.retry_policy, error_map, attempt_num) do
      :retry ->
        schedule_retry(state, delivery, attempt_num, error_map)

      :terminal ->
        dead_letter(state, delivery, attempt_num, error_map)
    end
  end

  defp schedule_retry(state, delivery, attempt_num, error_map) do
    backoff_ms = Retry.backoff_ms(state.retry_policy, error_map, attempt_num)
    timer_ref = Process.send_after(self(), {:run, delivery.id}, backoff_ms)

    new_timers = Map.put(state.retry_timers, delivery.id, timer_ref)
    advance_next(%{state | status: :idle, retry_timers: new_timers})
  end

  defp dead_letter(state, delivery, attempt_num, error_map) do
    outcome = Outcome.new_failure(delivery.id, error_map)
    now = DateTime.utc_now()

    case ControlPlane.put_dead_letter(%{
           dispatch_id: delivery.id,
           op: Atom.to_string(delivery.op),
           channel_adapter: Atom.to_string(elem(delivery.channel, 0)),
           channel_id: elem(delivery.channel, 1),
           scope_id: delivery.scope_id,
           thread_id: delivery.thread_id,
           caused_by_signal_id: delivery.caused_by_signal_id,
           payload: encode_delivery_payload(delivery),
           final_error: error_map,
           attempts_total: attempt_num,
           dead_lettered_at: now
         }) do
      :ok ->
        publish_failure_outcome(state, delivery, attempt_num, outcome, error_map)

      {:error, reason} ->
        Logger.error("delivery DLQ write failed for #{delivery.id}: #{inspect(reason)}")
        advance_next(forget_delivery(%{state | status: :idle}, delivery.id))
    end
  end

  defp publish_failure_outcome(state, delivery, attempt_num, outcome, error_map) do
    case publish_outcome_signal(state, delivery, outcome) do
      :ok ->
        emit_telemetry(:finished, state, delivery, %{attempts: attempt_num}, %{
          outcome: :failed,
          error_kind: error_map["kind"]
        })

      {:error, reason} ->
        Logger.error(
          "delivery failure outcome publish failed for #{delivery.id}: #{inspect(reason)}"
        )
    end

    advance_next(forget_delivery(%{state | status: :idle}, delivery.id))
  end

  # ---------------------------------------------------------------------------
  # Queue / idle lifecycle
  # ---------------------------------------------------------------------------

  defp put_delivery(state, %Delivery{} = delivery) do
    %{state | deliveries: Map.put(state.deliveries, delivery.id, delivery)}
  end

  defp forget_delivery(state, delivery_id) do
    %{
      state
      | deliveries: Map.delete(state.deliveries, delivery_id),
        attempts: Map.delete(state.attempts, delivery_id)
    }
  end

  defp advance_next(%{queue: []} = state), do: reset_idle_timers(state)

  defp advance_next(%{queue: [head | rest]} = state) do
    send(self(), {:run, head})
    %{state | queue: rest}
  end

  defp start_next(state) do
    advance_next(state)
  end

  defp reset_idle_timers(state) do
    state = cancel_idle_timers(state)

    %{
      state
      | hibernate_timer: Process.send_after(self(), :hibernate_idle, state.hibernate_ms),
        terminate_timer: Process.send_after(self(), :terminate_idle, state.terminate_ms)
    }
  end

  defp cancel_idle_timers(state) do
    if state.hibernate_timer, do: Process.cancel_timer(state.hibernate_timer)
    if state.terminate_timer, do: Process.cancel_timer(state.terminate_timer)
    %{state | hibernate_timer: nil, terminate_timer: nil}
  end

  # ---------------------------------------------------------------------------
  # Stream cancellation
  # ---------------------------------------------------------------------------

  defp shutdown_stream_task(state, task, reason) do
    marked_state = %{state | stream_intent: reason}

    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        {:running, id, _} = marked_state.status
        finalize_stream(marked_state, id, result)

      {:exit, exit_reason} ->
        {:running, id, _} = marked_state.status
        error_map = synthesize_stream_error(reason, exit_reason)
        finalize_stream(marked_state, id, {:error, error_map})

      nil ->
        {:running, id, _} = marked_state.status
        error_map = synthesize_stream_error(reason, :killed)
        finalize_stream(marked_state, id, {:error, error_map})
    end
  end

  defp synthesize_stream_error(:user_cancel, _reason) do
    %{"kind" => "stream_cancelled", "message" => "Stream cancelled by operator"}
  end

  defp synthesize_stream_error(:adapter_down, _reason) do
    %{"kind" => "adapter_restarted", "message" => "Adapter subtree DOWN during stream"}
  end

  defp synthesize_stream_error(_, reason) do
    %{"kind" => "exception", "message" => "Stream task exited: #{inspect(reason)}"}
  end

  # ---------------------------------------------------------------------------
  # Adapter / bus / telemetry
  # ---------------------------------------------------------------------------

  defp load_adapter_entry(state) do
    case AdapterRegistry.lookup(state.channel) do
      {:ok, entry} ->
        module = entry.module
        config = entry.config

        policy = Retry.build(Map.get(config, :retry_policy, %{}))
        {anchor_pid, monitor_ref} = maybe_monitor_adapter(Map.get(config, :anchor_pid))

        %{
          state
          | adapter_module: module,
            adapter_config: config,
            adapter_anchor_pid: anchor_pid,
            adapter_monitor_ref: monitor_ref,
            retry_policy: policy
        }

      :error ->
        state
    end
  end

  defp maybe_monitor_adapter(pid) when is_pid(pid) do
    {pid, Process.monitor(pid)}
  end

  defp maybe_monitor_adapter(_), do: {nil, nil}

  defp build_context(state) do
    telemetry = %{
      channel: state.channel,
      scope_id: state.scope_id
    }

    ctx = %{
      channel: state.channel,
      config: state.adapter_config,
      telemetry: telemetry
    }

    if state.adapter_anchor_pid,
      do: Map.put(ctx, :anchor_pid, state.adapter_anchor_pid),
      else: ctx
  end

  defp safe_adapter_call(fun) do
    try do
      fun.()
    rescue
      e ->
        {:error,
         %{
           "kind" => "exception",
           "message" => Exception.message(e),
           "details" => %{"module" => exception_module(e)}
         }}
    catch
      kind, reason ->
        {:error,
         %{
           "kind" => "exception",
           "message" => "#{kind}: #{inspect(reason)}"
         }}
    end
  end

  defp exception_module(%mod{}), do: Atom.to_string(mod)

  defp publish_outcome_signal(state, delivery, %Outcome{} = outcome) do
    {adapter, channel_id} = state.channel

    type =
      case outcome.status do
        :failed -> "com.agentbull.x.delivery.failed"
        _ -> "com.agentbull.x.delivery.succeeded"
      end

    extensions =
      %{
        "bullx_channel_adapter" => Atom.to_string(adapter),
        "bullx_channel_id" => channel_id
      }

    extensions =
      case Map.get(delivery, :caused_by_signal_id) do
        nil -> extensions
        id -> Map.put(extensions, "bullx_caused_by", id)
      end

    subject = render_subject(adapter, state.scope_id, Map.get(delivery, :thread_id))

    attrs = %{
      id: Signal.ID.generate!(),
      source: "bullx://gateway/#{adapter}/#{channel_id}",
      type: type,
      subject: subject,
      time: DateTime.to_iso8601(DateTime.utc_now()),
      datacontenttype: "application/json",
      data: Outcome.to_signal_data(outcome),
      extensions: extensions
    }

    with {:ok, signal} <- Signal.new(attrs),
         {:ok, _} <- Bus.publish(BullXGateway.SignalBus, [signal]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_subject(adapter, scope_id, nil), do: "#{adapter}:#{scope_id}"
  defp render_subject(adapter, scope_id, thread_id), do: "#{adapter}:#{scope_id}:#{thread_id}"

  defp emit_telemetry(event, state, delivery, measurements, metadata) do
    Telemetry.emit(
      [:bullx, :gateway, :delivery, event],
      measurements,
      Map.merge(metadata, %{
        channel: state.channel,
        scope_id: state.scope_id,
        op: Map.get(delivery, :op),
        delivery_id: Map.get(delivery, :id)
      })
    )
  end

  # ---------------------------------------------------------------------------
  # Delivery encoding (for dead-letter payload + DLQ replay)
  # ---------------------------------------------------------------------------

  @doc false
  def encode_delivery_payload(%Delivery{} = delivery) do
    content =
      case delivery.op do
        :stream -> nil
        _ -> encode_content(delivery.content)
      end

    %{
      "reply_to_external_id" => delivery.reply_to_external_id,
      "target_external_id" => delivery.target_external_id,
      "content" => content,
      "extensions" => delivery.extensions
    }
  end

  defp encode_content(nil), do: nil

  defp encode_content(%BullXGateway.Delivery.Content{kind: kind, body: body}) do
    %{"kind" => Atom.to_string(kind), "body" => body}
  end

  # ---------------------------------------------------------------------------
  # Delivery decoding (for DLQ replay)
  # ---------------------------------------------------------------------------

  @doc false
  def decode_delivery_from_dead_letter(dead_letter) do
    payload = dead_letter.payload || %{}
    adapter_atom = String.to_existing_atom(dead_letter.channel_adapter)

    %Delivery{
      id: dead_letter.dispatch_id,
      op: string_to_op(dead_letter.op),
      channel: {adapter_atom, dead_letter.channel_id},
      scope_id: dead_letter.scope_id,
      thread_id: dead_letter.thread_id,
      reply_to_external_id: payload["reply_to_external_id"],
      target_external_id: payload["target_external_id"],
      content: decode_content(payload["content"], dead_letter.op),
      caused_by_signal_id: dead_letter.caused_by_signal_id,
      extensions: payload["extensions"] || %{}
    }
  end

  defp string_to_op("send"), do: :send
  defp string_to_op("edit"), do: :edit
  defp string_to_op("stream"), do: :stream

  defp decode_content(_content, "stream"), do: nil

  defp decode_content(nil, _op), do: nil

  defp decode_content(%{"kind" => kind, "body" => body}, _op) do
    %BullXGateway.Delivery.Content{kind: String.to_existing_atom(kind), body: body}
  end

  defp decode_content(_, _), do: nil

  defp find_worker_for_delivery(delivery_id) when is_binary(delivery_id) do
    result =
      Enum.find_value(ScopeRegistry.keys(), fn {channel, scope_id} ->
        case ScopeRegistry.whereis(channel, scope_id) do
          pid when is_pid(pid) ->
            case :sys.get_state(pid, 200) do
              %{status: {:running, ^delivery_id, _}} -> pid
              _ -> nil
            end

          _ ->
            nil
        end
      end)

    case result do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end
end
