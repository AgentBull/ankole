defmodule Ankole.AIGateway.ResponseStream do
  @moduledoc """
  Owns one normalized AIGateway response stream from native input to public events.

  The owner is the only receiver of Kernel stream messages. It enforces image
  persistence, durable/public projections, stateful terminal commits, tool-call
  limits, live events, telemetry, demand, and cancellation before a transport
  can observe an event. Phoenix only asks for the next batch and frames the maps.
  """

  use GenServer

  alias Ankole.AIGateway.HostedToolTelemetry
  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ResponseStream.Supervisor
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.Kernel.UniversalAIClient

  @heartbeat_ms 60_000
  @terminal_shutdown_ms 5_000
  @cancel_shutdown_ms 1_000
  @open_failure_shutdown_ms 5_000

  @enforce_keys [:pid, :ref]
  defstruct [:pid, :ref]

  @opaque t :: %__MODULE__{pid: pid(), ref: reference()}
  @type terminal_status :: {:terminal, State.outcome()}
  @type message ::
          {:ai_gateway_response_stream, reference(), :events, [map()],
           :continue | terminal_status()}

  @spec open(String.t(), map(), UniversalAIRequest.t() | map(), keyword()) ::
          {:ok, t(), map()} | {:error, term()}
  def open(subject_uid, request, prepared_request, opts \\ []) do
    receiver = Keyword.get(opts, :receiver, self())
    upstream_opts = Keyword.drop(opts, [:receiver, :stateful])

    open_fun = fn ->
      UniversalAIRequest.open_stream(prepared_request, :websocket_text, upstream_opts)
    end

    child_opts = [
      subject_uid: subject_uid,
      request: stream_policy(request),
      stateful: Keyword.get(opts, :stateful),
      receiver: receiver,
      telemetry_spec: telemetry_spec(prepared_request),
      open_fun: open_fun
    ]

    case start_stream(child_opts) do
      {:ok, pid} -> describe(pid)
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :response_stream_start_ignored}
    end
  end

  @spec read(t(), non_neg_integer()) :: :ok | {:error, term()}
  def read(stream, count \\ 1)

  def read(%__MODULE__{pid: pid}, count) when is_integer(count) and count >= 0 do
    safe_call(pid, {:read, count})
  end

  def read(%__MODULE__{}, _count), do: {:error, :invalid_response_stream_credit}

  @spec cancel(t(), String.t()) :: :ok | {:error, term()}
  def cancel(stream, reason \\ "consumer_cancelled")

  def cancel(%__MODULE__{pid: pid}, reason) when is_binary(reason) do
    case safe_call(pid, {:cancel, reason}) do
      {:error, :response_stream_closed} -> :ok
      result -> result
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok,
     %{
       phase: :opening,
       ref: make_ref(),
       receiver: Keyword.fetch!(opts, :receiver),
       subject_uid: Keyword.fetch!(opts, :subject_uid),
       request: Keyword.fetch!(opts, :request),
       stateful: Keyword.get(opts, :stateful),
       telemetry_spec: Keyword.fetch!(opts, :telemetry_spec),
       telemetry_emitted?: false,
       open_fun: Keyword.fetch!(opts, :open_fun)
     }, {:continue, :open_native_stream}}
  end

  @impl true
  def handle_continue(:open_native_stream, state) do
    case state.open_fun.() do
      {:ok, native_stream, meta} ->
        owner_monitor = Process.monitor(state.receiver)

        semantic =
          State.new(
            state.subject_uid,
            state.request,
            meta,
            stateful: state.stateful
          )

        ready_state =
          state
          |> Map.drop([:open_fun, :request, :stateful, :subject_uid])
          |> Map.merge(%{
            phase: :ready,
            owner_monitor: owner_monitor,
            native_stream: native_stream,
            meta: meta,
            semantic: semantic,
            closing?: false,
            heartbeat_timer: schedule_heartbeat(state.stateful)
          })

        {:noreply, ready_state}

      {:error, reason} ->
        maybe_emit_open_failure(state.telemetry_spec, reason)

        Process.send_after(
          self(),
          :response_stream_open_failure_shutdown,
          @open_failure_shutdown_ms
        )

        failed_state =
          state
          |> Map.drop([:open_fun, :request, :stateful, :subject_uid])
          |> Map.put(:phase, {:open_failed, reason})

        {:noreply, failed_state}
    end
  end

  @impl true
  def handle_call(:describe, _from, %{phase: :ready} = state) do
    {:reply, {:ok, %__MODULE__{pid: self(), ref: state.ref}, state.meta}, state}
  end

  def handle_call(:describe, _from, %{phase: {:open_failed, reason}} = state) do
    {:stop, :normal, {:error, reason}, state}
  end

  def handle_call({:read, _count}, _from, %{semantic: semantic} = state)
      when semantic.terminal? do
    {:reply, {:error, :response_stream_terminal}, state}
  end

  def handle_call({:read, count}, _from, state) do
    case UniversalAIClient.read(state.native_stream, count) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {state, events, outcome} =
          fail_stream(state, "stream_read_failed: #{inspect(reason)}",
            code: "provider_stream_error",
            retryable: true
          )

        send_events(state, events, {:terminal, outcome})
        {:stop, :normal, :ok, state}
    end
  end

  def handle_call({:cancel, reason}, _from, state) do
    _ = UniversalAIClient.cancel(state.native_stream)

    {state, _events, _outcome} =
      fail_stream(state, reason,
        code: "response_stream_cancelled",
        retryable: true
      )

    {:stop, :normal, :ok, %{state | closing?: true}}
  end

  @impl true
  def handle_info(
        {:universal_ai_client, ref, :chunk, _sequence, _kind, _chunk},
        %{native_stream: %{ref: ref}, semantic: %{terminal?: true}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:universal_ai_client, ref, :chunk, sequence, :websocket_text, chunk},
        %{native_stream: %{ref: ref}} = state
      ) do
    case decode_event(chunk) do
      {:ok, event} -> observe_event(state, event, sequence)
      {:error, reason} -> stop_with_failure(state, "invalid_response_stream_event: #{reason}")
    end
  end

  def handle_info(
        {:universal_ai_client, ref, :chunk, _sequence, kind, _chunk},
        %{native_stream: %{ref: ref}} = state
      ) do
    stop_with_failure(state, "unexpected_chunk_kind: #{inspect(kind)}",
      code: "unexpected_downstream_chunk_kind"
    )
  end

  def handle_info(
        {:universal_ai_client, ref, :done, summary},
        %{native_stream: %{ref: ref}} = state
      ) do
    state = emit_summary_once(state, summary)

    if State.terminal?(state.semantic) do
      {:stop, :normal, state}
    else
      {state, events, outcome} =
        fail_stream(state, "provider_stream_closed_without_terminal",
          code: "provider_stream_closed_without_terminal",
          retryable: true
        )

      send_events(state, events, {:terminal, outcome})
      {:stop, :normal, state}
    end
  end

  def handle_info(
        {:universal_ai_client, ref, :error, error},
        %{native_stream: %{ref: ref}} = state
      ) do
    state = emit_failure_once(state, error)

    if State.terminal?(state.semantic) do
      {:stop, :normal, state}
    else
      {state, events, outcome} =
        fail_stream(state, "provider_stream_error: #{inspect(error)}",
          code: "provider_stream_error",
          retryable: true
        )

      send_events(state, events, {:terminal, outcome})
      {:stop, :normal, state}
    end
  end

  def handle_info(
        {:universal_ai_client, ref, :aborted},
        %{native_stream: %{ref: ref}} = state
      ) do
    if state.closing? or State.terminal?(state.semantic) do
      {:stop, :normal, state}
    else
      {state, events, outcome} =
        fail_stream(state, "stream_aborted",
          code: "provider_stream_aborted",
          retryable: true
        )

      send_events(state, events, {:terminal, outcome})
      {:stop, :normal, state}
    end
  end

  def handle_info(:response_stream_shutdown, state) do
    _ = UniversalAIClient.cancel(state.native_stream)
    {:stop, :normal, state}
  end

  def handle_info(:response_stream_open_failure_shutdown, state), do: {:stop, :normal, state}

  def handle_info(:response_stream_heartbeat, state) do
    semantic = state.semantic

    heartbeat_timer =
      case {State.terminal?(semantic), State.stateful_context(semantic)} do
        {false, %{message_id: message_id}} ->
          case StatefulResponses.touch_generating_response(semantic.subject_uid, message_id) do
            {:ok, %{} = _message} -> schedule_heartbeat(%{message_id: message_id})
            {:ok, :already_terminal} -> nil
            # A transient touch failure must not silence a live stream for good;
            # the staleness reaper only wins if the row stays untouched.
            {:error, _reason} -> schedule_heartbeat(%{message_id: message_id})
          end

        _terminal_or_stateless ->
          nil
      end

    {:noreply, %{state | heartbeat_timer: heartbeat_timer}}
  end

  def handle_info(
        {:DOWN, monitor, :process, receiver, _reason},
        %{owner_monitor: monitor, receiver: receiver} = state
      ) do
    if State.terminal?(state.semantic) do
      # The public terminal event is already committed and delivered. Keep the
      # native owner alive briefly so its final hosted-tool summary can arrive.
      {:noreply, %{state | receiver: nil}}
    else
      _ = UniversalAIClient.cancel(state.native_stream)

      {state, _events, _outcome} =
        fail_stream(state, "stream_consumer_terminated",
          code: "stream_consumer_terminated",
          retryable: true
        )

      {:stop, :normal, %{state | closing?: true}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{native_stream: native_stream}) do
    _ = UniversalAIClient.cancel(native_stream)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp observe_event(state, event, sequence) do
    case State.observe(state.semantic, event, sequence) do
      {:ok, semantic, events, :continue} ->
        state = %{state | semantic: semantic}
        send_events(state, events, :continue)
        {:noreply, state}

      {:ok, semantic, events, {:terminal, outcome, upstream_action}} ->
        state = %{state | semantic: semantic}
        state = finish_public_stream(state, upstream_action)
        send_events(state, events, {:terminal, outcome})
        {:noreply, state}

      {:error, semantic, events, :continue, reason} ->
        state = %{state | semantic: semantic} |> emit_failure_once(reason)

        {state, failure_events, outcome} =
          fail_stream(state, "image_persistence_failed: #{inspect(reason)}",
            code: "artifact_persistence_failed"
          )

        state = finish_public_stream(state, :cancel_upstream)
        send_events(state, events ++ failure_events, {:terminal, outcome})
        {:noreply, state}

      {:error, semantic, events, {:terminal, outcome, _action}, reason} ->
        state = %{state | semantic: semantic} |> emit_failure_once(reason)
        state = finish_public_stream(state, :cancel_upstream)
        send_events(state, events, {:terminal, outcome})
        {:noreply, state}
    end
  end

  defp finish_public_stream(state, upstream_action) do
    state = %{state | heartbeat_timer: cancel_timer(state.heartbeat_timer)}

    case upstream_action do
      :keep_upstream ->
        schedule_shutdown(state, @terminal_shutdown_ms)

      :cancel_upstream ->
        _ = UniversalAIClient.cancel(state.native_stream)
        state |> Map.put(:closing?, true) |> schedule_shutdown(@cancel_shutdown_ms)
    end
  end

  defp stop_with_failure(state, reason, opts \\ []) do
    {state, events, outcome} =
      fail_stream(state, reason,
        code: Keyword.get(opts, :code, "provider_stream_error"),
        retryable: true
      )

    _ = UniversalAIClient.cancel(state.native_stream)
    send_events(state, events, {:terminal, outcome})
    {:stop, :normal, %{state | closing?: true}}
  end

  defp fail_stream(state, reason, opts) do
    state =
      emit_failure_once(state, %{
        code: Keyword.get(opts, :code, "provider_stream_error")
      })

    {semantic, events, outcome} = State.fail(state.semantic, reason, opts)
    {%{state | semantic: semantic}, events, outcome}
  end

  defp send_events(state, events, status) do
    send(
      state.receiver,
      {:ai_gateway_response_stream, state.ref, :events, events, status}
    )
  end

  defp emit_summary_once(%{telemetry_emitted?: true} = state, _summary), do: state

  defp emit_summary_once(state, summary) do
    HostedToolTelemetry.emit_summary(summary)
    %{state | telemetry_emitted?: hosted_summary?(summary)}
  end

  defp emit_failure_once(%{telemetry_emitted?: true} = state, _reason), do: state

  defp emit_failure_once(state, reason) do
    if hosted_request?(state.telemetry_spec) or hosted_error?(reason) do
      HostedToolTelemetry.emit_failure(state.telemetry_spec, reason)
      %{state | telemetry_emitted?: true}
    else
      state
    end
  end

  defp maybe_emit_open_failure(telemetry_spec, reason) do
    if hosted_request?(telemetry_spec) or hosted_error?(reason) do
      HostedToolTelemetry.emit_failure(telemetry_spec, reason)
    end
  end

  defp hosted_summary?(%{"hosted_tool_metadata" => %{}}), do: true
  defp hosted_summary?(%{hosted_tool_metadata: %{}}), do: true
  defp hosted_summary?(_summary), do: false

  defp hosted_error?(%{"stage" => "hosted_responses"}), do: true
  defp hosted_error?(_reason), do: false

  defp hosted_request?(%{hosted_tools: %{image_generation: %{}}}), do: true
  defp hosted_request?(_spec), do: false

  defp telemetry_spec(prepared_request) do
    hosted_tools =
      Map.get(prepared_request, :hosted_tools) || Map.get(prepared_request, "hosted_tools") || %{}

    image =
      Map.get(hosted_tools, :image_generation) || Map.get(hosted_tools, "image_generation")

    case image do
      %{} ->
        %{
          hosted_tools: %{
            image_generation: Map.take(image, ["selected_model", "provider_tag", "provider_slug"])
          }
        }

      _missing ->
        %{}
    end
  end

  defp stream_policy(request) do
    %{"max_tool_calls" => Map.get(request, "max_tool_calls") || Map.get(request, :max_tool_calls)}
  end

  defp decode_event(chunk) do
    case Ankole.JSON.decode(IO.iodata_to_binary(chunk)) do
      {:ok, %{} = event} -> {:ok, event}
      {:ok, _not_object} -> {:error, "event must be a JSON object"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp schedule_heartbeat(%{message_id: _message_id}),
    do: Process.send_after(self(), :response_stream_heartbeat, @heartbeat_ms)

  defp schedule_heartbeat(_stateful), do: nil

  defp schedule_shutdown(state, timeout) do
    Process.send_after(self(), :response_stream_shutdown, timeout)
    state
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer) do
    Process.cancel_timer(timer, async: true, info: false)
    nil
  end

  defp describe(pid) do
    case safe_call(pid, :describe) do
      {:ok, %__MODULE__{}, _meta} = result -> result
      {:error, _reason} = error -> error
    end
  end

  defp safe_call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, _reason -> {:error, :response_stream_closed}
  end

  defp start_stream(child_opts) do
    Supervisor.start_stream(child_opts)
  catch
    :exit, _reason -> {:error, :response_stream_unavailable}
  end
end
