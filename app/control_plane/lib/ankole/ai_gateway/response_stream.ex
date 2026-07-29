defmodule Ankole.AIGateway.ResponseStream do
  @moduledoc """
  Owns one normalized AIGateway response stream from native input to public events.

  The owner is the only receiver of Kernel stream messages. It enforces image
  persistence, durable/public projections, stateful terminal commits, tool-call
  limits, live events, telemetry, demand, and cancellation before a transport
  can observe an event. Phoenix only asks for the next batch and frames the maps.
  """

  use GenServer

  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.HostedToolTelemetry
  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ResponseStream.Supervisor
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.ToolSearch.StreamLoop, as: ToolSearchStreamLoop
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
    {tool_loop, prepared_request} = pop_tool_loop(prepared_request)

    {hosted_credential_attempt, prepared_request} =
      ImageGeneration.pop_credential_attempt(prepared_request)

    upstream_opts = Keyword.drop(opts, [:receiver, :stateful])

    child_opts = [
      subject_uid: subject_uid,
      request: stream_policy(request),
      stateful: Keyword.get(opts, :stateful),
      tool_loop: tool_loop,
      hosted_credential_attempt: hosted_credential_attempt,
      upstream_opts: upstream_opts,
      receiver: receiver,
      telemetry_spec: telemetry_spec(prepared_request),
      diagnostics: stream_diagnostics(request, prepared_request),
      prepared_request: prepared_request
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
       tool_loop: Keyword.get(opts, :tool_loop),
       hosted_credential_attempt: Keyword.get(opts, :hosted_credential_attempt),
       hosted_retrying?: false,
       upstream_opts: Keyword.get(opts, :upstream_opts, []),
       open_fun: Keyword.get(opts, :open_fun),
       telemetry_spec: Keyword.fetch!(opts, :telemetry_spec),
       telemetry_emitted?: false,
       diagnostics: Keyword.get(opts, :diagnostics, %{}),
       failure_logged?: false,
       prepared_request: Keyword.get(opts, :prepared_request, %{})
     }, {:continue, :open_native_stream}}
  end

  @impl true
  def handle_continue(:open_native_stream, state) do
    loop = ToolSearchStreamLoop.new(state.tool_loop)

    if ToolSearchStreamLoop.pre_round?(loop) do
      handle_pre_round(state, loop)
    else
      open_initial_stream(state, loop)
    end
  end

  defp open_initial_stream(state, loop) do
    case open_native_stream(state) do
      {:ok, native_stream, meta, attempt_context, attempt_spec} ->
        {:noreply,
         ready_state(
           state,
           loop,
           native_stream,
           meta,
           nil,
           attempt_context,
           attempt_spec
         )}

      {:error, reason} ->
        open_failed(state, reason)
    end
  end

  defp open_native_stream(%{open_fun: open_fun}) when is_function(open_fun, 0) do
    case open_fun.() do
      {:ok, native_stream, meta} -> {:ok, native_stream, meta, nil, %{}}
      {:error, _reason} = error -> error
    end
  end

  defp open_native_stream(state) do
    CredentialAttempts.open(
      state.prepared_request,
      :websocket_text,
      state.upstream_opts
    )
  end

  # A request that resumes a paused program answers its program before any
  # provider round; a program that pauses again answers the client without a
  # provider call at all. Events buffer until the consumer's first read so
  # they cannot race the open handshake.
  defp handle_pre_round(state, loop) do
    case ToolSearchStreamLoop.pre_round(loop) do
      {:respond, items, loop} ->
        semantic = new_semantic(state, %{}, loop)
        {semantic, events, status} = State.respond_without_provider(semantic, items)

        {:terminal, outcome, _upstream_action} = status

        ready =
          ready_state(
            state,
            loop,
            nil,
            %{},
            {events, {:terminal, outcome}},
            nil,
            %{}
          )

        ready = %{ready | semantic: semantic}
        {:noreply, finish_public_stream(ready, :keep_upstream)}

      {:provider_round, items, continuation_request, loop} ->
        with {:ok, native_stream, meta, attempt_context, attempt_spec} <-
               open_pre_round(state, continuation_request) do
          semantic = new_semantic(state, meta, loop)
          {semantic, events} = State.append_pre_round_items(semantic, items)

          ready =
            ready_state(
              state,
              nil,
              native_stream,
              meta,
              {events, :continue},
              attempt_context,
              attempt_spec
            )

          {:noreply, %{ready | semantic: semantic}}
        else
          {:error, reason} -> open_failed(state, reason)
        end
    end
  end

  defp new_semantic(state, meta, loop) do
    State.new(
      state.subject_uid,
      state.request,
      meta,
      stateful: state.stateful,
      tool_loop: loop
    )
  end

  defp ready_state(
         state,
         loop,
         native_stream,
         meta,
         pending_flush,
         attempt_context,
         attempt_spec
       ) do
    semantic = new_semantic(state, meta, loop)

    state
    |> Map.drop([:prepared_request, :request, :stateful, :subject_uid, :open_fun])
    |> Map.merge(%{
      phase: :ready,
      owner_monitor: Process.monitor(state.receiver),
      native_stream: native_stream,
      meta: meta,
      semantic: semantic,
      round_open: round_open_fun(state.tool_loop),
      attempt_context: attempt_context,
      attempt_spec: attempt_spec,
      credential_success_recorded?: false,
      provider_output?: false,
      outstanding_credit: 0,
      pending_flush: pending_flush,
      closing?: false,
      heartbeat_timer: schedule_heartbeat(state.stateful)
    })
  end

  defp open_failed(state, reason) do
    state = log_failure_once(state, reason)
    maybe_emit_open_failure(state.telemetry_spec, reason)

    Process.send_after(
      self(),
      :response_stream_open_failure_shutdown,
      @open_failure_shutdown_ms
    )

    failed_state =
      state
      |> Map.drop([:prepared_request, :request, :stateful, :subject_uid, :open_fun])
      |> Map.put(:phase, {:open_failed, reason})

    {:noreply, failed_state}
  end

  defp safe_round_open(round_open, continuation_request, upstream_opts) do
    round_open.(continuation_request, upstream_opts)
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp open_pre_round(state, continuation_request) do
    case CredentialAttempts.pop(state.prepared_request) do
      {%{} = context, _clean_spec} ->
        CredentialAttempts.open_round(
          context,
          continuation_request,
          :websocket_text,
          state.upstream_opts
        )

      {nil, _clean_spec} ->
        with round_open when is_function(round_open, 2) <- round_open_fun(state.tool_loop),
             {:ok, native_stream, meta} <-
               safe_round_open(round_open, continuation_request, state.upstream_opts) do
          {:ok, native_stream, meta, nil, %{}}
        else
          nil -> {:error, :tool_search_round_open_unavailable}
          {:error, _reason} = error -> error
        end
    end
  end

  @impl true
  def handle_call(:describe, _from, %{phase: :ready} = state) do
    {:reply, {:ok, %__MODULE__{pid: self(), ref: state.ref}, state.meta}, state}
  end

  def handle_call(:describe, _from, %{phase: {:open_failed, reason}} = state) do
    {:stop, :normal, {:error, reason}, state}
  end

  # Pre-round events buffered during open flush on the consumer's first read,
  # so they cannot race the open handshake.
  def handle_call({:read, count}, from, %{pending_flush: {events, status}} = state) do
    state = %{state | pending_flush: nil}
    send_events(state, events, status)

    case status do
      {:terminal, _outcome} -> {:reply, :ok, state}
      :continue -> handle_call({:read, count}, from, state)
    end
  end

  def handle_call({:read, _count}, _from, %{semantic: semantic} = state)
      when semantic.terminal? do
    {:reply, {:error, :response_stream_terminal}, state}
  end

  def handle_call({:read, count}, _from, state) do
    case UniversalAIClient.read(state.native_stream, count) do
      :ok ->
        {:reply, :ok, Map.update!(state, :outstanding_credit, &(&1 + count))}

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
    _ = cancel_native(state.native_stream)

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
    state = consume_credit(state)

    case decode_event(chunk) do
      {:ok, event} ->
        if suppress_retried_hosted_lifecycle?(state, event) do
          replenish_suppressed_credit(state)
        else
          case retryable_failure_event(event, state) do
            {:retry, reason} ->
              reopen_stream(state, reason)

            :observe ->
              state =
                state
                |> record_credential_success(event)
                |> Map.put(:hosted_retrying?, false)

              provider_output? = state.provider_output? or provider_output_event?(event)
              observe_event(%{state | provider_output?: provider_output?}, event, sequence)
          end
        end

      {:error, reason} ->
        stop_with_failure(state, "invalid_response_stream_event: #{reason}")
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
    if State.terminal?(state.semantic) do
      {:stop, :normal, emit_summary_once(state, summary)}
    else
      if not state.provider_output? do
        reopen_stream(state, %{
          "code" => "provider_stream_closed_without_terminal",
          "stage" => "read",
          "message" => "provider stream closed without a terminal event"
        })
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
  end

  def handle_info(
        {:universal_ai_client, ref, :error, error},
        %{native_stream: %{ref: ref}} = state
      ) do
    if State.terminal?(state.semantic) do
      {:stop, :normal, state}
    else
      if retry_hosted_failure?(state, error) do
        retry_hosted_stream(state, error)
      else
        if not state.provider_output? do
          reopen_stream(state, error)
        else
          state = state |> log_failure_once(error) |> emit_failure_once(error)

          {state, events, outcome} =
            fail_stream(state, "provider_stream_error: #{inspect(error)}",
              code: "provider_stream_error",
              retryable: true
            )

          send_events(state, events, {:terminal, outcome})
          {:stop, :normal, state}
        end
      end
    end
  end

  def handle_info(
        {:universal_ai_client, ref, :aborted},
        %{native_stream: %{ref: ref}} = state
      ) do
    if state.closing? or State.terminal?(state.semantic) do
      {:stop, :normal, state}
    else
      if not state.provider_output? do
        reopen_stream(state, %{
          "code" => "stream_aborted",
          "stage" => "read",
          "message" => "provider stream aborted"
        })
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
  end

  def handle_info(:response_stream_shutdown, state) do
    _ = cancel_native(state.native_stream)
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
      _ = cancel_native(state.native_stream)

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
    _ = cancel_native(native_stream)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp observe_event(state, event, sequence) do
    case State.observe(state.semantic, event, sequence) do
      {:ok, semantic, events, :continue} ->
        state = %{state | semantic: semantic}
        send_events(state, events, :continue)
        {:noreply, state}

      {:ok, semantic, events, {:round, continuation_request}} ->
        state = %{state | semantic: semantic}
        send_events(state, events, :continue)
        continue_round(state, continuation_request)

      {:ok, semantic, events, {:terminal, outcome, upstream_action}} ->
        state =
          state
          |> Map.put(:semantic, semantic)
          |> log_terminal_failure_once(outcome)

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

  defp reopen_stream(state, reason) do
    _ = cancel_native(state.native_stream)

    case CredentialAttempts.reopen(
           state.attempt_context,
           state.attempt_spec,
           reason,
           :websocket_text,
           state.upstream_opts
         ) do
      {:ok, native_stream, meta, attempt_context, attempt_spec} ->
        credit = max(state.outstanding_credit, 1)

        case UniversalAIClient.read(native_stream, credit) do
          :ok ->
            {:noreply,
             %{
               state
               | native_stream: native_stream,
                 meta: meta,
                 attempt_context: attempt_context,
                 attempt_spec: attempt_spec,
                 hosted_retrying?: is_map(state.hosted_credential_attempt),
                 credential_success_recorded?: false,
                 provider_output?: false,
                 outstanding_credit: credit
             }}

          {:error, read_reason} ->
            stop_after_retry_failure(
              state,
              {:credential_retry_read_failed, read_reason}
            )
        end

      {:error, final_reason} ->
        stop_after_retry_failure(state, final_reason)
    end
  end

  defp retry_hosted_stream(state, reason) do
    _ = cancel_native(state.native_stream)

    case ImageGeneration.retry_credential_attempt(
           state.attempt_spec,
           state.hosted_credential_attempt,
           reason,
           state.upstream_opts
         ) do
      {:ok, next_spec, next_hosted_attempt} ->
        {^next_hosted_attempt, next_spec} =
          ImageGeneration.pop_credential_attempt(next_spec)

        case UniversalAIRequest.open_stream(
               next_spec,
               :websocket_text,
               state.upstream_opts
             ) do
          {:ok, native_stream, meta} ->
            credit = max(state.outstanding_credit, 1)

            case UniversalAIClient.read(native_stream, credit) do
              :ok ->
                {:noreply,
                 %{
                   state
                   | native_stream: native_stream,
                     meta: meta,
                     attempt_context:
                       ImageGeneration.pin_main_attempt_context(
                         state.attempt_context,
                         next_hosted_attempt
                       ),
                     attempt_spec: next_spec,
                     hosted_credential_attempt: next_hosted_attempt,
                     hosted_retrying?: true,
                     credential_success_recorded?: false,
                     provider_output?: false,
                     outstanding_credit: credit
                 }}

              {:error, read_reason} ->
                stop_after_retry_failure(
                  state,
                  {:credential_retry_read_failed, read_reason}
                )
            end

          {:error, open_reason} ->
            stop_after_retry_failure(state, open_reason)
        end

      {:error, final_reason} ->
        stop_after_retry_failure(state, final_reason)
    end
  end

  defp stop_after_retry_failure(state, reason) do
    failure_opts =
      case reason do
        {:credential_pool_exhausted, details} ->
          retry_at = Map.get(details, "retry_at")

          [
            code: "credential_pool_exhausted",
            retryable: true,
            message: credential_pool_exhausted_message(retry_at),
            details: if(is_binary(retry_at), do: %{"retry_at" => retry_at}, else: nil)
          ]

        _reason ->
          classification = FailureDiagnostics.classify(reason)

          [
            code: Map.get(classification, :error_code, "provider_stream_error"),
            retryable: Map.get(classification, :retryable, true),
            message: FailureDiagnostics.public_message(classification),
            provider_status: Map.get(classification, :provider_status),
            details: retry_failure_details(classification)
          ]
      end

    state = state |> log_failure_once(reason) |> emit_failure_once(reason)

    {state, events, outcome} =
      fail_stream(
        state,
        "provider_stream_error: #{inspect(reason)}",
        failure_opts
      )

    send_events(state, events, {:terminal, outcome})
    {:stop, :normal, state}
  end

  defp retry_failure_details(classification) do
    classification
    |> Map.take([:error_stage, :failure_kind])
    |> Enum.reduce(%{}, fn
      {:failure_kind, value}, details when is_atom(value) ->
        Map.put(details, "failure_kind", Atom.to_string(value))

      {key, value}, details ->
        Map.put(details, Atom.to_string(key), value)
    end)
  end

  defp credential_pool_exhausted_message(retry_at) when is_binary(retry_at),
    do: "AIGateway credential pool exhausted. retry_at=#{retry_at}"

  defp credential_pool_exhausted_message(_retry_at),
    do: "AIGateway credential pool exhausted. Try again later."

  defp retryable_failure_event(_event, %{provider_output?: true}), do: :observe

  defp retryable_failure_event(
         %{"type" => "response.failed", "response" => %{"error" => %{} = error}},
         _state
       ) do
    details = Map.get(error, "details_json", %{})
    status = Map.get(error, "status") || Map.get(details, "provider_status")
    code = Map.get(error, "code")
    stage = Map.get(details, "stage", "read")

    failure = %{
      "code" => code || "provider_status_rejected",
      "stage" => stage,
      "message" => Map.get(error, "message", "provider request failed"),
      "provider_status" => status,
      "provider_headers" => Map.get(details, "provider_headers", %{})
    }

    if CredentialAttempts.recoverable_failure?(failure) do
      {:retry, failure}
    else
      :observe
    end
  end

  defp retryable_failure_event(_event, _state), do: :observe

  defp retry_hosted_failure?(
         %{hosted_credential_attempt: %{}, provider_output?: false},
         reason
       ),
       do: ImageGeneration.credential_failure?(reason)

  defp retry_hosted_failure?(_state, _reason), do: false

  defp suppress_retried_hosted_lifecycle?(
         %{hosted_retrying?: true},
         %{"type" => type}
       )
       when type in ["response.created", "response.in_progress"],
       do: true

  defp suppress_retried_hosted_lifecycle?(_state, _event), do: false

  defp replenish_suppressed_credit(state) do
    case UniversalAIClient.read(state.native_stream, 1) do
      :ok ->
        {:noreply, Map.update!(state, :outstanding_credit, &(&1 + 1))}

      {:error, reason} ->
        stop_after_retry_failure(state, {:credential_retry_read_failed, reason})
    end
  end

  defp provider_output_event?(%{"type" => type})
       when type in ["response.created", "response.in_progress"],
       do: false

  defp provider_output_event?(_event), do: true

  defp consume_credit(%{outstanding_credit: credit} = state) when credit > 0,
    do: %{state | outstanding_credit: credit - 1}

  defp consume_credit(state), do: state

  defp finish_public_stream(state, upstream_action) do
    state = %{state | heartbeat_timer: cancel_timer(state.heartbeat_timer)}

    case upstream_action do
      :keep_upstream ->
        schedule_shutdown(state, @terminal_shutdown_ms)

      :cancel_upstream ->
        _ = cancel_native(state.native_stream)
        state |> Map.put(:closing?, true) |> schedule_shutdown(@cancel_shutdown_ms)
    end
  end

  # Replaces the finished provider round with a continuation stream inside the
  # same public response. The old native stream already reached its terminal;
  # cancel is a no-op safety release.
  defp continue_round(state, continuation_request) do
    _ = cancel_native(state.native_stream)

    case open_round_stream(state, continuation_request) do
      {:ok, native_stream, meta, attempt_context, attempt_spec} ->
        credit = max(state.outstanding_credit, 1)

        case UniversalAIClient.read(native_stream, credit) do
          :ok ->
            {:noreply,
             %{
               state
               | native_stream: native_stream,
                 meta: meta,
                 attempt_context: attempt_context,
                 attempt_spec: attempt_spec,
                 credential_success_recorded?: false,
                 provider_output?: false,
                 outstanding_credit: credit
             }}

          {:error, reason} ->
            fail_round(state, "tool_search_round_read_failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        fail_round(state, "tool_search_round_open_failed: #{inspect(reason)}")
    end
  end

  defp open_round_stream(%{attempt_context: %{} = context} = state, continuation_request) do
    CredentialAttempts.open_round(
      context,
      continuation_request,
      :websocket_text,
      Map.get(state, :upstream_opts, [])
    )
  end

  defp open_round_stream(%{round_open: round_open} = state, continuation_request)
       when is_function(round_open, 2) do
    case round_open.(continuation_request, Map.get(state, :upstream_opts, [])) do
      {:ok, native_stream, meta} -> {:ok, native_stream, meta, nil, %{}}
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp open_round_stream(_state, _continuation_request),
    do: {:error, :tool_search_round_open_unavailable}

  defp fail_round(state, reason) do
    {state, events, outcome} =
      fail_stream(state, reason,
        code: "tool_search_round_failed",
        retryable: true
      )

    send_events(state, events, {:terminal, outcome})
    {:stop, :normal, state}
  end

  defp round_open_fun(%{round_open: round_open}) when is_function(round_open, 2), do: round_open
  defp round_open_fun(_tool_loop), do: nil

  # A pre-round respond path never opened a native stream.
  defp cancel_native(nil), do: :ok
  defp cancel_native(native_stream), do: UniversalAIClient.cancel(native_stream)

  defp record_credential_success(state, event) do
    state =
      if state.credential_success_recorded? do
        state
      else
        :ok = CredentialAttempts.mark_ok(state.attempt_context, state.meta)
        %{state | credential_success_recorded?: true}
      end

    if event["type"] in ["response.completed", "response.failed", "response.incomplete"] do
      hosted? = hosted_request?(state.telemetry_spec)

      :ok =
        CredentialAttempts.record_usage(state.attempt_context, event,
          aggregate_includes_tool_usage?: hosted?
        )

      :ok = ImageGeneration.record_credential_usage(state.hosted_credential_attempt, event)
    end

    state
  end

  defp pop_tool_loop(%UniversalAIRequest{} = prepared_request), do: {nil, prepared_request}
  defp pop_tool_loop(%{} = prepared_request), do: Map.pop(prepared_request, :tool_loop)
  defp pop_tool_loop(prepared_request), do: {nil, prepared_request}

  defp stop_with_failure(state, reason, opts \\ []) do
    {state, events, outcome} =
      fail_stream(state, reason,
        code: Keyword.get(opts, :code, "provider_stream_error"),
        retryable: true
      )

    _ = cancel_native(state.native_stream)
    send_events(state, events, {:terminal, outcome})
    {:stop, :normal, %{state | closing?: true}}
  end

  defp fail_stream(state, reason, opts) do
    failure = %{
      "code" => Keyword.get(opts, :code, "provider_stream_error"),
      "stage" => "response_stream",
      "retryable" => Keyword.get(opts, :retryable, false)
    }

    state =
      state
      |> log_failure_once(failure)
      |> emit_failure_once(failure)

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

  defp hosted_error?(%{"stage" => stage})
       when stage in ["hosted_responses", "image_generation"],
       do: true

  defp hosted_error?(_reason), do: false

  defp hosted_request?(%{hosted_tools: %{image_generation: %{}}}), do: true
  defp hosted_request?(%{"hosted_tools" => %{"image_generation" => %{}}}), do: true
  defp hosted_request?(_spec), do: false

  defp log_terminal_failure_once(state, %{terminal_error: %{} = error}),
    do: state |> log_failure_once(error) |> emit_failure_once(error)

  defp log_terminal_failure_once(state, _outcome), do: state

  defp log_failure_once(%{failure_logged?: true} = state, _reason), do: state

  defp log_failure_once(state, reason) do
    FailureDiagnostics.log(
      "ai_gateway.response_failed",
      "AIGateway provider response failed",
      state.diagnostics,
      reason
    )

    %{state | failure_logged?: true}
  end

  defp stream_diagnostics(request, prepared_request) do
    response_context =
      Map.get(prepared_request, :response_context) ||
        Map.get(prepared_request, "response_context") || %{}

    upstream =
      Map.get(prepared_request, :upstream) || Map.get(prepared_request, "upstream") || %{}

    {input_image_count, inline_image_chars} = request_image_stats(request)

    %{
      actor_event_id: get_in(request, ["metadata", "actor_event_id"]),
      model: map_value(response_context, "model") || Map.get(request, "model"),
      api_resolver:
        prepared_request
        |> map_value("api_resolver")
        |> string(),
      upstream_host:
        upstream
        |> map_value("url")
        |> upstream_host(),
      request_bytes: encoded_size(request),
      input_item_count: item_count(Map.get(request, "input")),
      tool_count: item_count(Map.get(request, "tools")),
      function_call_output_count: function_call_output_count(Map.get(request, "input")),
      input_image_count: input_image_count,
      inline_image_chars: inline_image_chars
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp request_image_stats(value) when is_list(value) do
    Enum.reduce(value, {0, 0}, fn item, {count, chars} ->
      {item_count, item_chars} = request_image_stats(item)
      {count + item_count, chars + item_chars}
    end)
  end

  defp request_image_stats(%{} = value) do
    if map_value(value, "type") in ["input_image", "image_url"] do
      {1, inline_image_chars(map_value(value, "image_url"))}
    else
      value
      |> Map.values()
      |> request_image_stats()
    end
  end

  defp request_image_stats(_value), do: {0, 0}

  defp inline_image_chars(url) when is_binary(url) do
    if String.starts_with?(url, "data:image/"), do: byte_size(url), else: 0
  end

  defp inline_image_chars(%{} = url), do: inline_image_chars(map_value(url, "url"))
  defp inline_image_chars(_url), do: 0

  defp function_call_output_count(input) when is_list(input) do
    Enum.count(input, fn
      %{} = item -> map_value(item, "type") == "function_call_output"
      _item -> false
    end)
  end

  defp function_call_output_count(_input), do: 0

  defp encoded_size(value) do
    case Ankole.JSON.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _reason} -> nil
    end
  end

  defp item_count(items) when is_list(items), do: length(items)
  defp item_count(nil), do: 0
  defp item_count(_item), do: 1

  defp upstream_host(url) when is_binary(url), do: URI.parse(url).host
  defp upstream_host(_url), do: nil

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        _entry ->
          nil
      end)
  end

  defp map_value(_map, _key), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(_value), do: nil

  defp telemetry_spec(prepared_request) do
    hosted_tools =
      Map.get(prepared_request, :hosted_tools) || Map.get(prepared_request, "hosted_tools") || %{}

    image =
      Map.get(hosted_tools, :image_generation) || Map.get(hosted_tools, "image_generation")

    case image do
      %{} ->
        %{
          hosted_tools: %{
            image_generation:
              Map.take(image, [
                "actor_event_id",
                "selected_model",
                "provider_tag",
                "provider_tags",
                "provider_slug",
                "provider_slugs"
              ])
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
