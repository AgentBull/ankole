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
  alias Ankole.AIGateway.Observability
  alias Ankole.AIGateway.ProgramExecution
  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ResponseStream.Supervisor
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.ToolSearch.StreamLoop, as: ToolSearchStreamLoop
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.Kernel.UniversalAIClient

  require Ankole.Kernel.UniversalAIClient

  @heartbeat_ms 60_000
  @terminal_shutdown_ms 5_000
  @cancel_shutdown_ms 1_000
  @open_failure_shutdown_ms 5_000
  @collect_timeout_ms 30 * 60 * 1_000
  @recovery_task_supervisor Ankole.AIGateway.ResponseRecoveryTaskSupervisor

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

    upstream_opts =
      Keyword.drop(opts, [
        :receiver,
        :stateful,
        :program_runner,
        :program_task_supervisor,
        :collect_timeout,
        :describe_timeout
      ])

    child_opts = [
      subject_uid: subject_uid,
      request: stream_policy(request),
      observation_request: request,
      stateful: Keyword.get(opts, :stateful),
      tool_loop: tool_loop,
      hosted_credential_attempt: hosted_credential_attempt,
      program_runner: Keyword.get(opts, :program_runner),
      program_task_supervisor: Keyword.get(opts, :program_task_supervisor),
      upstream_opts: upstream_opts,
      receiver: receiver,
      telemetry_spec: telemetry_spec(prepared_request),
      diagnostics: stream_diagnostics(request, prepared_request),
      prepared_request: prepared_request
    ]

    case start_stream(child_opts) do
      {:ok, pid} -> describe(pid, Keyword.get(opts, :describe_timeout, :infinity))
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :response_stream_start_ignored}
    end
  end

  @doc """
  Runs this same state machine behind a synchronous transport adapter.
  """
  @spec collect(String.t(), map(), UniversalAIRequest.t() | map(), keyword()) ::
          {:ok, State.outcome(), map()} | {:error, term()}
  def collect(subject_uid, request, prepared_request, opts \\ []) do
    timeout = Keyword.get(opts, :collect_timeout, @collect_timeout_ms)

    if is_integer(timeout) and timeout > 0 do
      deadline = System.monotonic_time(:millisecond) + timeout

      open_opts =
        opts
        |> Keyword.delete(:collect_timeout)
        |> Keyword.put(:describe_timeout, timeout)
        |> Keyword.put(:receiver, self())

      with {:ok, %__MODULE__{} = stream, meta} <-
             open(subject_uid, request, prepared_request, open_opts) do
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        if remaining > 0 do
          await_terminal(stream, meta, remaining)
        else
          _ = cancel(stream, "synchronous_collector_timeout")
          {:error, :response_stream_collect_timeout}
        end
      end
    else
      {:error, :invalid_response_stream_collect_timeout}
    end
  end

  @doc false
  @spec await_terminal(t(), map(), pos_integer()) ::
          {:ok, State.outcome(), map()} | {:error, term()}
  def await_terminal(%__MODULE__{} = stream, meta, timeout)
      when is_map(meta) and is_integer(timeout) and timeout > 0 do
    monitor = Process.monitor(stream.pid)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      collect_next(stream, monitor, deadline, meta)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def await_terminal(%__MODULE__{}, _meta, _timeout),
    do: {:error, :invalid_response_stream_collect_timeout}

  @doc false
  @spec project_non_streaming_response(map(), map()) :: map()
  def project_non_streaming_response(
        prepared_request,
        %{body: %{"output" => output} = body} = upstream_response
      )
      when is_map(prepared_request) and is_list(output) do
    {tool_loop, _prepared_request} = pop_tool_loop(prepared_request)
    loop = ToolSearchStreamLoop.new(tool_loop)

    %{
      upstream_response
      | body: Map.put(body, "output", ToolSearchStreamLoop.rewrite_public_items(loop, output))
    }
  end

  def project_non_streaming_response(_prepared_request, upstream_response),
    do: upstream_response

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
    receiver = Keyword.fetch!(opts, :receiver)
    owner_monitor = Process.monitor(receiver)
    prepared_request = Keyword.get(opts, :prepared_request, %{})
    {attempt_context, attempt_spec} = CredentialAttempts.prepare_stream(prepared_request)
    raw_tool_loop = Keyword.get(opts, :tool_loop)
    loop = ToolSearchStreamLoop.new(raw_tool_loop)
    meta = resolver_meta(prepared_request)
    stateful = Keyword.get(opts, :stateful)
    request = Keyword.fetch!(opts, :request)

    state = %{
      phase: if(ToolSearchStreamLoop.initial_local_effect?(loop), do: :ready, else: :opening),
      public_open?: ToolSearchStreamLoop.initial_local_effect?(loop),
      ref: make_ref(),
      receiver: receiver,
      owner_monitor: owner_monitor,
      subject_uid: Keyword.fetch!(opts, :subject_uid),
      request: request,
      stateful: stateful,
      observability:
        Observability.start_response(
          Keyword.fetch!(opts, :subject_uid),
          Keyword.get(opts, :observation_request, request),
          Keyword.take(opts, [:stateful, :request_context, :subject_type, :caller])
        ),
      semantic: nil,
      round_open: round_open_fun(raw_tool_loop),
      program_runner: Keyword.get(opts, :program_runner),
      program_task_supervisor: Keyword.get(opts, :program_task_supervisor),
      hosted_credential_attempt: Keyword.get(opts, :hosted_credential_attempt),
      upstream_opts: Keyword.get(opts, :upstream_opts, []),
      open_fun: Keyword.get(opts, :open_fun),
      telemetry_spec: Keyword.fetch!(opts, :telemetry_spec),
      telemetry_emitted?: false,
      diagnostics: Keyword.get(opts, :diagnostics, %{}),
      failure_logged?: false,
      prepared_request: prepared_request,
      describe_waiters: [],
      opening: nil,
      native_stream: nil,
      meta: meta,
      attempt_context: attempt_context,
      attempt_spec: attempt_spec,
      credential_success_recorded?: false,
      provider_output?: false,
      stateful_replay_recovery_attempted?: false,
      outstanding_credit: 0,
      pending_flush: nil,
      program_task: nil,
      native_done?: false,
      closing?: false,
      heartbeat_timer: schedule_heartbeat(stateful)
    }

    state = %{state | semantic: new_semantic(state, meta, loop)}
    {:ok, state, {:continue, :open_native_stream}}
  end

  @impl true
  def handle_continue(:open_native_stream, state) do
    loop = ToolSearchStreamLoop.new(state.semantic.tool_loop)

    if ToolSearchStreamLoop.initial_local_effect?(loop) do
      start_initial_local_effect(state)
    else
      open_initial_stream(state, loop)
    end
  end

  defp open_initial_stream(state, loop) do
    state = %{state | semantic: %{state.semantic | tool_loop: loop}}

    if is_function(state.open_fun, 0) do
      begin_custom_open(state, :initial, state.open_fun)
    else
      begin_open_episode(state, :initial, state.attempt_context, state.attempt_spec)
    end
  end

  # An initial local effect can emit and even finish the public response before
  # any provider stream opens. Buffer its lifecycle until the first read.
  defp start_initial_local_effect(state) do
    case State.take_initial_local_effect(state.semantic) do
      {:ok, semantic, lifecycle_events, jobs, context} ->
        ready =
          state
          |> Map.put(:semantic, semantic)
          |> deliver_or_buffer(lifecycle_events, :continue)

        case start_program_execution(ready, jobs, context) do
          {:ok, ready} ->
            {:noreply, ready}

          {:complete, outcomes, ready} ->
            complete_program_execution(ready, context, outcomes)

          {:error, reason, ready} ->
            {:noreply, fail_program_execution(ready, reason)}
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

  defp begin_open_episode(state, kind, context, spec) when is_map(spec) do
    state = start_observed_round(state, context, spec)
    token = make_ref()
    timeout_ms = UniversalAIRequest.ready_timeout_ms(spec)
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    deadline_timer =
      Process.send_after(self(), {:response_stream_open_deadline, token}, timeout_ms)

    opening = %{
      token: token,
      kind: kind,
      context: context,
      spec: spec,
      native_stream: nil,
      deadline_ms: deadline_ms,
      deadline_timer: deadline_timer,
      retry_timer: nil,
      worker: nil
    }

    state
    |> Map.merge(%{phase: :opening, opening: opening, native_stream: nil})
    |> start_open_candidate()
  end

  defp begin_custom_open(state, kind, fun) when is_function(fun, 0) do
    state = start_observed_round(state, state.attempt_context, state.attempt_spec)
    token = make_ref()
    timeout_ms = UniversalAIRequest.ready_timeout_ms(state.attempt_spec)
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    deadline_timer =
      Process.send_after(self(), {:response_stream_open_deadline, token}, timeout_ms)

    owner = self()

    case start_recovery_task(fn ->
           result = safe_custom_open(fun)
           send(owner, {:response_stream_custom_open, token, result})
         end) do
      {:ok, pid} ->
        opening = %{
          token: token,
          kind: kind,
          context: state.attempt_context,
          spec: state.attempt_spec,
          native_stream: nil,
          deadline_ms: deadline_ms,
          deadline_timer: deadline_timer,
          retry_timer: nil,
          worker: %{pid: pid, monitor: Process.monitor(pid), kind: :custom_open}
        }

        {:noreply, Map.merge(state, %{phase: :opening, opening: opening, native_stream: nil})}

      {:error, reason} ->
        _ = cancel_timer(deadline_timer)
        finish_open_failure(state, {:stream_open_task_unavailable, reason})
    end
  end

  defp start_open_candidate(%{opening: %{spec: spec} = opening} = state) do
    case UniversalAIRequest.start_stream(spec, :websocket_text, receiver: self()) do
      {:ok, native_stream} ->
        opening = %{opening | native_stream: native_stream}
        {:noreply, %{state | opening: opening}}

      {:error, reason} ->
        begin_open_recovery(state, reason)
    end
  end

  defp begin_open_recovery(state, reason) do
    state = cancel_open_candidate(state)
    opening = state.opening

    case opening.context do
      %{} = context ->
        token = opening.token
        spec = opening.spec
        opts = state.upstream_opts
        owner = self()

        case start_recovery_task(fn ->
               result = CredentialAttempts.plan_retry(context, spec, reason, opts)
               send(owner, {:response_stream_retry_planned, token, reason, result})
             end) do
          {:ok, pid} ->
            worker = %{pid: pid, monitor: Process.monitor(pid), kind: :retry_plan}
            {:noreply, %{state | opening: %{opening | worker: worker}}}

          {:error, task_reason} ->
            finish_open_failure(state, {:credential_retry_task_unavailable, task_reason})
        end

      _no_context ->
        finish_open_failure(state, reason)
    end
  end

  defp begin_round_open(state, kind, continuation_request) do
    cond do
      is_map(state.attempt_context) ->
        case CredentialAttempts.build_round(state.attempt_context, continuation_request) do
          {:ok, spec, context} -> begin_open_episode(state, kind, context, spec)
          {:error, reason} -> finish_open_failure(state, reason)
        end

      is_function(state.round_open, 2) ->
        fun = fn -> state.round_open.(continuation_request, state.upstream_opts) end
        begin_custom_open(state, kind, fun)

      true ->
        finish_open_failure(state, :tool_search_round_open_unavailable)
    end
  rescue
    error -> finish_open_failure(state, {:exception, error.__struct__, Exception.message(error)})
  catch
    :exit, reason -> finish_open_failure(state, {:exit, reason})
  end

  defp promote_open(
         %{opening: %{deadline_ms: deadline_ms} = opening} = state,
         native_stream,
         meta,
         context,
         spec
       ) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      # A ready message can outrun an already-due timer in a busy mailbox. The
      # monotonic deadline, not message arrival order, owns admission.
      state = %{state | opening: %{opening | native_stream: native_stream}}
      finish_open_failure(state, ready_timeout_error())
    else
      complete_open(state, native_stream, meta, context, spec)
    end
  end

  defp complete_open(state, native_stream, meta, context, spec) do
    state = clear_opening(state)

    state = %{
      state
      | phase: :ready,
        public_open?: true,
        native_stream: native_stream,
        meta: meta,
        attempt_context: context,
        attempt_spec: spec,
        credential_success_recorded?: false,
        provider_output?: false,
        native_done?: false
    }

    Enum.each(state.describe_waiters, fn from ->
      GenServer.reply(from, {:ok, %__MODULE__{pid: self(), ref: state.ref}, meta})
    end)

    state = %{state | describe_waiters: []}

    case issue_native_credit(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> stop_after_retry_failure(state, reason)
    end
  end

  defp finish_open_failure(state, reason) do
    if recoverable_stateful_replay_failure?(state, reason) do
      begin_stateful_replay_recovery(state, reason)
    else
      do_finish_open_failure(state, reason)
    end
  end

  defp do_finish_open_failure(state, reason) do
    state = state |> cancel_open_candidate_if_present() |> clear_opening()

    if state.public_open? do
      stop_after_retry_failure(state, reason)
    else
      state = log_failure_once(state, reason)
      state = fail_observation(state, reason)
      maybe_emit_open_failure(state.telemetry_spec, reason)

      had_waiters? = state.describe_waiters != []
      Enum.each(state.describe_waiters, &GenServer.reply(&1, {:error, reason}))

      state = %{state | phase: {:open_failed, reason}, describe_waiters: []}

      if had_waiters? do
        {:stop, :normal, state}
      else
        Process.send_after(
          self(),
          :response_stream_open_failure_shutdown,
          @open_failure_shutdown_ms
        )

        {:noreply, state}
      end
    end
  end

  defp recoverable_stateful_replay_failure?(state, reason) do
    classification = FailureDiagnostics.classify(reason)

    not state.stateful_replay_recovery_attempted? and
      not state.public_open? and
      not state.provider_output? and
      is_nil(state.program_task) and
      match?(%{replay_recovery: %{}}, state.stateful) and
      Map.get(classification, :error_code) == "stateful_replay_input_rejected" and
      Map.get(classification, :error_stage) == "socket_open" and
      Map.get(classification, :provider_status) == 400
  end

  defp begin_stateful_replay_recovery(state, original_reason) do
    state =
      state
      |> cancel_open_candidate_if_present()
      |> clear_opening()
      |> fail_observed_round(original_reason)
      |> Map.put(:stateful_replay_recovery_attempted?, true)

    token = make_ref()
    owner = self()
    stateful = state.stateful

    case start_recovery_task(fn ->
           result = safe_stateful_replay_recovery(stateful)
           send(owner, {:response_stream_stateful_replay_recovered, token, result})
         end) do
      {:ok, pid} ->
        opening = %{
          token: token,
          kind: :stateful_replay_recovery,
          context: nil,
          spec: nil,
          native_stream: nil,
          deadline_ms: nil,
          deadline_timer: nil,
          retry_timer: nil,
          recovery_reason: original_reason,
          worker: %{
            pid: pid,
            monitor: Process.monitor(pid),
            kind: :stateful_replay_recovery
          }
        }

        {:noreply, %{state | phase: :opening, opening: opening, native_stream: nil}}

      {:error, reason} ->
        do_finish_open_failure(state, {:stateful_replay_recovery_task_unavailable, reason})
    end
  end

  defp safe_stateful_replay_recovery(stateful) do
    StatefulLifecycle.recover_provider_replay(stateful)
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp resume_stateful_replay_recovery(
         state,
         prepared_request,
         stateful,
         original_reason
       ) do
    state = clear_opening(state)
    {tool_loop, prepared_request} = pop_tool_loop(prepared_request)

    {hosted_credential_attempt, prepared_request} =
      ImageGeneration.pop_credential_attempt(prepared_request)

    {attempt_context, attempt_spec} = CredentialAttempts.prepare_stream(prepared_request)
    loop = ToolSearchStreamLoop.new(tool_loop)
    meta = resolver_meta(prepared_request)

    state =
      Map.merge(state, %{
        stateful: stateful,
        prepared_request: prepared_request,
        round_open: round_open_fun(tool_loop),
        hosted_credential_attempt: hosted_credential_attempt,
        telemetry_spec: telemetry_spec(prepared_request),
        meta: meta,
        attempt_context: attempt_context,
        attempt_spec: attempt_spec,
        credential_success_recorded?: false,
        provider_output?: false,
        native_done?: false,
        native_stream: nil
      })

    state = %{state | semantic: new_semantic(state, meta, loop)}
    begin_open_episode(state, :initial, attempt_context, attempt_spec)
  rescue
    _error -> do_finish_open_failure(state, original_reason)
  catch
    :exit, _reason -> do_finish_open_failure(state, original_reason)
  end

  defp clear_opening(%{opening: nil} = state), do: state

  defp clear_opening(%{opening: opening} = state) do
    _ = cancel_timer(opening.deadline_timer)
    _ = cancel_timer(opening.retry_timer)
    :ok = cancel_open_worker(opening.worker)

    %{state | opening: nil}
  end

  defp cancel_open_candidate_if_present(%{opening: nil} = state), do: state
  defp cancel_open_candidate_if_present(state), do: cancel_open_candidate(state)

  defp cancel_open_candidate(%{opening: %{native_stream: native_stream} = opening} = state) do
    _ = cancel_native(native_stream)
    :ok = cancel_open_worker(opening.worker)
    %{state | opening: %{opening | native_stream: nil, worker: nil}}
  end

  defp cancel_open_worker(nil), do: :ok

  defp cancel_open_worker(%{kind: kind, pid: pid, monitor: monitor})
       when kind in [:custom_open, :stateful_replay_recovery] do
    # This worker is owned entirely by its opening episode. Once that episode
    # loses its owner, it has no independent work to finish.
    _ = terminate_recovery_task(pid)
    Process.demonitor(monitor, [:flush])
    :ok
  end

  # Retry planning can include an OAuth refresh whose remote token rotation has
  # already happened while the local credential transaction still needs to
  # commit. The opening episode relinquishes its monitor, but must not kill that
  # bounded settlement task and leave remote/local credential state split.
  defp cancel_open_worker(%{monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp terminate_recovery_task(pid) do
    Task.Supervisor.terminate_child(@recovery_task_supervisor, pid)
  catch
    :exit, _reason -> :ok
  end

  defp start_recovery_task(fun) do
    Task.Supervisor.start_child(@recovery_task_supervisor, fun, restart: :temporary)
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_custom_open(fun) do
    fun.()
  rescue
    error -> {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def handle_call(:describe, _from, %{public_open?: true} = state) do
    {:reply, {:ok, %__MODULE__{pid: self(), ref: state.ref}, state.meta}, state}
  end

  def handle_call(:describe, from, %{phase: :opening} = state) do
    {:noreply, %{state | describe_waiters: [from | state.describe_waiters]}}
  end

  def handle_call(:describe, _from, %{phase: {:open_failed, reason}} = state) do
    {:stop, :normal, {:error, reason}, state}
  end

  # Pre-round events buffered during open flush on the consumer's first read,
  # so they cannot race the open handshake.
  def handle_call({:read, 0}, _from, state), do: {:reply, :ok, state}

  def handle_call({:read, count}, from, %{pending_flush: {events, status}} = state) do
    state = %{state | pending_flush: nil}
    send_events(state, events, status)

    case status do
      {:terminal, _outcome} -> {:reply, :ok, state}
      :continue when count > 1 -> handle_call({:read, count - 1}, from, state)
      :continue -> {:reply, :ok, state}
    end
  end

  def handle_call({:read, _count}, _from, %{semantic: semantic} = state)
      when semantic.terminal? do
    {:reply, {:error, :response_stream_terminal}, state}
  end

  def handle_call({:read, count}, _from, %{program_task: %{} = _task} = state) do
    {:reply, :ok, Map.update!(state, :outstanding_credit, &(&1 + count))}
  end

  def handle_call({:read, count}, _from, %{native_stream: nil} = state) do
    {:reply, :ok, Map.update!(state, :outstanding_credit, &(&1 + count))}
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
    {:stop, :normal, :ok, cancel_state(state, reason)}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    {:stop, :normal, cancel_state(state, reason)}
  end

  # All native stream messages enter through one clause. The kernel facade
  # translates the wire tuples into typed events exactly once, and the state
  # machine below dispatches on the events; a shape the facade does not know
  # raises there instead of dead-lettering into the final catch-all.
  @impl true
  def handle_info(message, state) when UniversalAIClient.is_stream_message(message) do
    native_stream_event(UniversalAIClient.stream_event(message), state)
  end

  def handle_info(
        {:response_stream_custom_open, token, {:ok, native_stream, meta}},
        %{opening: %{token: token} = opening} = state
      ) do
    promote_open(state, native_stream, meta, opening.context, opening.spec)
  end

  def handle_info(
        {:response_stream_custom_open, _stale_token, {:ok, native_stream, _meta}},
        state
      ) do
    # The producing worker no longer belongs to the current opening episode,
    # but the native candidate it returned still needs an explicit owner.
    _ = cancel_native(native_stream)
    {:noreply, state}
  end

  def handle_info(
        {:response_stream_custom_open, token, {:error, reason}},
        %{opening: %{token: token}} = state
      ) do
    begin_open_recovery(state, reason)
  end

  def handle_info(
        {:response_stream_custom_open, token, invalid},
        %{opening: %{token: token}} = state
      ) do
    finish_open_failure(state, {:invalid_stream_open_result, invalid})
  end

  def handle_info(
        {:response_stream_stateful_replay_recovered, token, {:ok, prepared_request, stateful}},
        %{
          opening: %{
            token: token,
            kind: :stateful_replay_recovery,
            recovery_reason: original_reason
          }
        } = state
      ) do
    resume_stateful_replay_recovery(
      state,
      prepared_request,
      stateful,
      original_reason
    )
  end

  def handle_info(
        {:response_stream_stateful_replay_recovered, token, _failure},
        %{
          opening: %{
            token: token,
            kind: :stateful_replay_recovery,
            recovery_reason: original_reason
          }
        } = state
      ) do
    finish_open_failure(state, original_reason)
  end

  def handle_info(
        {:response_stream_retry_planned, token, original_reason,
         {:retry, context, spec, delay_ms}},
        %{opening: %{token: token} = opening} = state
      ) do
    now_ms = System.monotonic_time(:millisecond)
    remaining_ms = max(opening.deadline_ms - now_ms, 0)

    if remaining_ms == 0 or delay_ms >= remaining_ms do
      finish_open_failure(state, ready_timeout_error())
    else
      :ok = Observability.record_credential_retry(state.observability, original_reason, delay_ms)
      :ok = cancel_open_worker(opening.worker)

      retry_timer =
        Process.send_after(self(), {:response_stream_retry_due, token}, max(delay_ms, 0))

      opening = %{
        opening
        | context: context,
          spec: spec,
          retry_timer: retry_timer,
          worker: nil
      }

      {:noreply, %{state | opening: opening}}
    end
  end

  def handle_info(
        {:response_stream_retry_planned, token, _original_reason,
         {:stop, final_reason, _context}},
        %{opening: %{token: token}} = state
      ) do
    finish_open_failure(state, final_reason)
  end

  def handle_info(
        {:response_stream_retry_planned, token, _original_reason, invalid},
        %{opening: %{token: token}} = state
      ) do
    finish_open_failure(state, {:invalid_credential_retry_plan, invalid})
  end

  def handle_info(
        {:response_stream_retry_due, token},
        %{opening: %{token: token} = opening} = state
      ) do
    opening = %{opening | retry_timer: nil}
    start_open_candidate(%{state | opening: opening})
  end

  def handle_info(
        {:response_stream_open_deadline, token},
        %{opening: %{token: token}} = state
      ) do
    finish_open_failure(state, ready_timeout_error())
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{opening: %{worker: %{monitor: monitor}} = opening} = state
      ) do
    # The worker sends its result before exiting; an ordinary DOWN can therefore
    # be ignored until that earlier message is processed. Abnormal termination
    # has no result to consume and is a stable opening failure.
    if reason == :normal do
      {:noreply, %{state | opening: %{opening | worker: nil}}}
    else
      finish_open_failure(state, {:stream_open_worker_terminated, reason})
    end
  end

  def handle_info(
        {:program_execution, ref, outcomes},
        %{program_task: %{ref: ref} = task} = state
      ) do
    Process.demonitor(task.monitor, [:flush])
    complete_program_execution(%{state | program_task: nil}, task.context, outcomes)
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{program_task: %{monitor: monitor}} = state
      ) do
    state = %{state | program_task: nil}

    {:noreply, fail_program_execution(state, {:program_task_terminated, reason})}
  end

  def handle_info(:response_stream_shutdown, state) do
    _ = cancel_native(state.native_stream)
    state = cancel_open_candidate_if_present(state)
    :ok = cancel_program(state.program_task)
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
      state = cancel_open_candidate_if_present(state)
      :ok = cancel_program(state.program_task)

      {state, _events, _outcome} =
        fail_stream(state, "stream_consumer_terminated",
          code: "stream_consumer_terminated",
          retryable: true
        )

      {:stop, :normal, %{state | closing?: true}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Typed native stream events, in the order the raw tuple clauses held before
  # the facade translation. A known event whose ref matches no live stream
  # falls to the final clause: stale messages from a replaced stream drop.
  defp native_stream_event(
         %UniversalAIClient.Ready{ref: ref, meta: meta},
         %{opening: %{native_stream: %{ref: ref}} = opening} = state
       ) do
    promote_open(state, opening.native_stream, meta, opening.context, opening.spec)
  end

  defp native_stream_event(
         %UniversalAIClient.StreamError{ref: ref, reason: reason},
         %{opening: %{native_stream: %{ref: ref}}} = state
       ) do
    begin_open_recovery(state, UniversalAIRequest.normalize_stream_error(reason))
  end

  defp native_stream_event(
         %UniversalAIClient.Aborted{ref: ref},
         %{opening: %{native_stream: %{ref: ref}}} = state
       ) do
    begin_open_recovery(state, :stream_aborted)
  end

  defp native_stream_event(
         %UniversalAIClient.Done{ref: ref},
         %{opening: %{native_stream: %{ref: ref}}} = state
       ) do
    begin_open_recovery(state, %{
      "code" => "provider_stream_closed_without_terminal",
      "stage" => "open",
      "message" => "provider stream closed before ready"
    })
  end

  defp native_stream_event(
         %UniversalAIClient.Chunk{ref: ref},
         %{native_stream: %{ref: ref}, semantic: %{terminal?: true}} = state
       ) do
    {:noreply, state}
  end

  # A local task can coexist with a native stream only after that provider
  # round has produced its terminal fact. Drain any trailing native messages;
  # the frozen local-effect context is the only fact the task may settle.
  defp native_stream_event(
         %UniversalAIClient.Chunk{ref: ref},
         %{native_stream: %{ref: ref}, program_task: %{}} = state
       ) do
    {:noreply, consume_credit(state)}
  end

  defp native_stream_event(
         %UniversalAIClient.Done{ref: ref, summary: summary},
         %{native_stream: %{ref: ref}, program_task: %{}} = state
       ) do
    {:noreply, state |> emit_summary_once(summary) |> Map.put(:native_done?, true)}
  end

  defp native_stream_event(
         %UniversalAIClient.StreamError{ref: ref},
         %{native_stream: %{ref: ref}, program_task: %{}} = state
       ) do
    {:noreply, %{state | native_done?: true}}
  end

  defp native_stream_event(
         %UniversalAIClient.Aborted{ref: ref},
         %{native_stream: %{ref: ref}, program_task: %{}} = state
       ) do
    {:noreply, %{state | native_done?: true}}
  end

  defp native_stream_event(
         %UniversalAIClient.Chunk{
           ref: ref,
           sequence: sequence,
           kind: :websocket_text,
           payload: chunk
         },
         %{native_stream: %{ref: ref}} = state
       ) do
    state = consume_credit(state)

    case decode_event(chunk) do
      {:ok, event} ->
        state = %{
          state
          | provider_output?: true,
            observability: Observability.observe_output(state.observability, event)
        }

        state =
          state
          |> record_credential_success(event)
          |> record_event_credential_failure(event)

        observe_event(state, event, sequence)

      {:error, reason} ->
        stop_with_failure(state, "invalid_response_stream_event: #{reason}")
    end
  end

  defp native_stream_event(
         %UniversalAIClient.Chunk{ref: ref, kind: kind},
         %{native_stream: %{ref: ref}} = state
       ) do
    stop_with_failure(state, "unexpected_chunk_kind: #{inspect(kind)}",
      code: "unexpected_downstream_chunk_kind"
    )
  end

  defp native_stream_event(
         %UniversalAIClient.Done{ref: ref, summary: summary},
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

  defp native_stream_event(
         %UniversalAIClient.StreamError{ref: ref, reason: error},
         %{native_stream: %{ref: ref}} = state
       ) do
    if State.terminal?(state.semantic) do
      {:stop, :normal, state}
    else
      cond do
        hosted_credential_failure?(state, error) ->
          stop_after_hosted_failure(state, error)

        not state.provider_output? ->
          reopen_stream(state, error)

        true ->
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

  defp native_stream_event(
         %UniversalAIClient.Aborted{ref: ref},
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

  defp native_stream_event(_event, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_native(Map.get(state, :native_stream))
    _ = cancel_open_candidate_if_present(state)
    :ok = cancel_program(Map.get(state, :program_task))
    _observation = Observability.fail(Map.get(state, :observability), :response_stream_terminated)
    :ok
  end

  defp observe_event(state, event, sequence) do
    state = finish_observed_round(state, event)

    case State.observe(state.semantic, event, sequence) do
      {:ok, semantic, events, :continue} ->
        state = %{state | semantic: semantic}
        send_events(state, events, :continue)
        {:noreply, state}

      {:ok, semantic, events, {:round, continuation_request}} ->
        state = %{state | semantic: semantic}
        send_events(state, events, :continue)
        continue_round(state, continuation_request)

      {:ok, semantic, events, {:local, jobs, context}} ->
        state = %{state | semantic: semantic}
        maybe_send_events(state, events, :continue)

        case start_program_execution(state, jobs, context) do
          {:ok, state} ->
            {:noreply, state}

          {:complete, outcomes, state} ->
            complete_program_execution(state, context, outcomes)

          {:error, reason, state} ->
            state = fail_program_execution(state, reason)
            {:noreply, state}
        end

      {:ok, semantic, events, {:terminal, outcome, upstream_action}} ->
        state =
          state
          |> Map.put(:semantic, semantic)
          |> log_terminal_failure_once(outcome)
          |> finish_observation(outcome)

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
        state = finish_observation(state, outcome)
        state = finish_public_stream(state, :cancel_upstream)
        send_events(state, events, {:terminal, outcome})
        {:noreply, state}
    end
  end

  defp start_program_execution(state, jobs, context) do
    opts =
      []
      |> maybe_put_program_option(:runner, Map.get(state, :program_runner))
      |> maybe_put_program_option(
        :supervisor,
        Map.get(state, :program_task_supervisor)
      )

    case ProgramExecution.start(self(), jobs, opts) do
      {:ok, task} -> {:ok, %{state | program_task: Map.put(task, :context, context)}}
      {:complete, outcomes} -> {:complete, outcomes, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp complete_program_execution(state, context, outcomes) do
    case State.complete_local_effect(state.semantic, context, outcomes) do
      {:ok, semantic, events, {:round, continuation_request}} ->
        state = %{state | semantic: semantic}
        state = deliver_local_effect_events(state, events, :continue)
        continue_round(state, continuation_request)

      {:ok, semantic, events, {:terminal, outcome, upstream_action}} ->
        state =
          state
          |> Map.put(:semantic, semantic)
          |> log_terminal_failure_once(outcome)
          |> finish_observation(outcome)
          |> finish_public_stream(upstream_action)

        {:noreply, deliver_local_effect_events(state, events, {:terminal, outcome})}

      {:error, semantic, reason} ->
        {:noreply, fail_program_execution(%{state | semantic: semantic}, reason)}
    end
  end

  defp deliver_local_effect_events(%{native_stream: nil} = state, events, status),
    do: deliver_or_buffer(state, events, status)

  defp deliver_local_effect_events(state, events, status) do
    send_events(state, events, status)
    state
  end

  defp deliver_or_buffer(state, events, status) do
    {state, events} = prepend_pending_events(state, events)

    if state.outstanding_credit > 0 do
      send_events(state, events, status)
      consume_credit(state)
    else
      %{state | pending_flush: {events, status}}
    end
  end

  defp fail_program_execution(state, reason) do
    code =
      if reason == :program_runtime_busy,
        do: "program_runtime_busy",
        else: "program_runtime_failed"

    {state, events, outcome} =
      fail_stream(state, format_program_failure(reason),
        code: code,
        retryable: reason == :program_runtime_busy
      )

    {state, events} = prepend_pending_events(state, events)
    state = finish_public_stream(state, :cancel_upstream)

    if state.provider_output? or state.outstanding_credit > 0 do
      send_events(state, events, {:terminal, outcome})
      state
    else
      %{state | pending_flush: {events, {:terminal, outcome}}}
    end
  end

  defp format_program_failure(reason) when is_binary(reason), do: reason
  defp format_program_failure(reason), do: inspect(reason)

  defp maybe_put_program_option(opts, _key, nil), do: opts
  defp maybe_put_program_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp reopen_stream(state, reason) do
    _ = cancel_native(state.native_stream)
    token = make_ref()
    timeout_ms = UniversalAIRequest.ready_timeout_ms(state.attempt_spec)
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    deadline_timer =
      Process.send_after(self(), {:response_stream_open_deadline, token}, timeout_ms)

    opening = %{
      token: token,
      kind: :reopen,
      context: state.attempt_context,
      spec: state.attempt_spec,
      native_stream: nil,
      deadline_ms: deadline_ms,
      deadline_timer: deadline_timer,
      retry_timer: nil,
      worker: nil
    }

    state = %{
      state
      | phase: :opening,
        opening: opening,
        native_stream: nil,
        outstanding_credit: max(state.outstanding_credit, 1)
    }

    begin_open_recovery(state, UniversalAIRequest.normalize_stream_error(reason))
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

    stop_after_provider_failure(state, reason, failure_opts)
  end

  defp stop_after_hosted_failure(state, reason) do
    :ok =
      ImageGeneration.record_credential_failure(
        state.hosted_credential_attempt,
        reason
      )

    classification = FailureDiagnostics.classify(reason)
    error = ImageGeneration.normalize_execution_error(reason)

    failure_opts = [
      code: error.code,
      retryable: Map.get(classification, :retryable, true),
      message: Map.get(classification, :provider_message, error.message),
      provider_status: Map.get(classification, :provider_status),
      details: retry_failure_details(classification)
    ]

    stop_after_provider_failure(state, reason, failure_opts)
  end

  defp stop_after_provider_failure(state, reason, failure_opts) do
    state = state |> log_failure_once(reason) |> emit_failure_once(reason)

    {state, events, outcome} =
      fail_stream(
        state,
        "provider_stream_error: #{inspect(reason)}",
        failure_opts
      )

    {state, events} = prepend_pending_events(state, events)
    send_events(state, events, {:terminal, outcome})
    {:stop, :normal, state}
  end

  defp prepend_pending_events(%{pending_flush: {pending_events, _status}} = state, events) do
    {%{state | pending_flush: nil}, pending_events ++ events}
  end

  defp prepend_pending_events(state, events), do: {state, events}

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

  defp hosted_credential_failure?(
         %{hosted_credential_attempt: %{}},
         reason
       ),
       do: ImageGeneration.credential_failure?(reason)

  defp hosted_credential_failure?(_state, _reason), do: false

  defp record_event_credential_failure(
         state,
         %{"type" => "response.failed", "response" => %{"error" => %{} = error}}
       ) do
    details =
      case Map.get(error, "details_json") do
        %{} = details -> details
        _missing -> %{}
      end

    stage = Map.get(details, "stage", "provider_response")

    failure = %{
      "code" => Map.get(error, "code", "provider_status_rejected"),
      "stage" => stage,
      "message" => Map.get(error, "message", "provider request failed"),
      "provider_status" => Map.get(error, "status") || Map.get(details, "provider_status"),
      "provider_headers" => Map.get(details, "provider_headers", %{})
    }

    attempt_context =
      if stage == "image_generation" and
           is_map(state.hosted_credential_attempt) do
        state.hosted_credential_attempt.context
      else
        state.attempt_context
      end

    :ok = CredentialAttempts.record_failure(attempt_context, failure)
    state
  end

  defp record_event_credential_failure(state, _event), do: state

  defp consume_credit(%{outstanding_credit: credit} = state) when credit > 0,
    do: %{state | outstanding_credit: credit - 1}

  defp consume_credit(state), do: state

  defp issue_native_credit(%{native_stream: native_stream, outstanding_credit: credit} = state)
       when not is_nil(native_stream) and credit > 0 do
    case UniversalAIClient.read(native_stream, credit) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:provider_round_read_failed, reason}, state}
    end
  end

  defp issue_native_credit(state), do: {:ok, state}

  defp ready_timeout_error do
    {:universal_ai_request_failed,
     %{
       "code" => "universal_ai_stream_ready_timeout",
       "stage" => "open",
       "message" => "provider stream did not become ready before the open deadline",
       "retryable" => true
     }}
  end

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

  defp start_observed_round(state, context, spec) do
    %{state | observability: Observability.start_round(state.observability, context, spec)}
  end

  defp finish_observed_round(state, %{"type" => type} = event)
       when type in ["response.completed", "response.failed", "response.incomplete"] do
    %{state | observability: Observability.finish_round(state.observability, event)}
  end

  defp finish_observed_round(state, _event), do: state

  defp fail_observed_round(state, reason) do
    %{state | observability: Observability.fail_round(state.observability, reason)}
  end

  defp finish_observation(state, outcome) do
    %{state | observability: Observability.finish_response(state.observability, outcome)}
  end

  defp fail_observation(state, reason) do
    %{state | observability: Observability.fail(state.observability, reason)}
  end

  # Replaces the finished provider round with a continuation stream inside the
  # same public response. The old native stream already reached its terminal;
  # cancel is a no-op safety release.
  defp continue_round(state, continuation_request) do
    _ = cancel_native(state.native_stream)
    begin_round_open(%{state | native_stream: nil}, :continuation, continuation_request)
  end

  defp round_open_fun(%{round_open: round_open}) when is_function(round_open, 2), do: round_open
  defp round_open_fun(_tool_loop), do: nil

  # A providerless history resume never opened a native stream.
  defp cancel_native(nil), do: :ok
  defp cancel_native(native_stream), do: UniversalAIClient.cancel(native_stream)

  defp cancel_program(program_task), do: ProgramExecution.cancel(program_task)

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

    state =
      %{state | semantic: semantic}
      |> fail_observed_round(failure)
      |> finish_observation(outcome)

    {state, events, outcome}
  end

  defp send_events(state, events, status) do
    send(
      state.receiver,
      {:ai_gateway_response_stream, state.ref, :events, events, status}
    )
  end

  defp maybe_send_events(_state, [], :continue), do: :ok
  defp maybe_send_events(state, events, status), do: send_events(state, events, status)

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
      custom_tool_call_output_count: custom_tool_call_output_count(Map.get(request, "input")),
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

  defp custom_tool_call_output_count(input) when is_list(input) do
    Enum.count(input, fn
      %{} = item -> map_value(item, "type") == "custom_tool_call_output"
      _item -> false
    end)
  end

  defp custom_tool_call_output_count(_input), do: 0

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

  defp resolver_meta(spec) when is_map(spec) do
    case Map.get(spec, :api_resolver) || Map.get(spec, "api_resolver") do
      nil -> %{}
      resolver -> %{"api_resolver" => resolver}
    end
  end

  defp decode_event(chunk) do
    case Ankole.JSON.decode(IO.iodata_to_binary(chunk)) do
      {:ok, %{} = event} -> {:ok, event}
      {:ok, _not_object} -> {:error, "event must be a JSON object"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp collect_next(stream, monitor, deadline, meta) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    ref = stream.ref

    case collect_read(stream, remaining) do
      :ok ->
        wait_remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:ai_gateway_response_stream, ^ref, :events, _events, :continue} ->
            collect_next(stream, monitor, deadline, meta)

          {:ai_gateway_response_stream, ^ref, :events, _events, {:terminal, %{} = outcome}} ->
            {:ok, outcome, meta}

          {:DOWN, ^monitor, :process, _pid, reason} ->
            {:error, {:response_stream_closed, reason}}
        after
          wait_remaining -> collect_timeout(stream)
        end

      {:error, :response_stream_collect_timeout} ->
        collect_timeout(stream)

      {:error, _reason} = error ->
        error
    end
  end

  defp collect_read(_stream, 0), do: {:error, :response_stream_collect_timeout}

  defp collect_read(%__MODULE__{pid: pid}, timeout) do
    GenServer.call(pid, {:read, 1}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :response_stream_collect_timeout}
    :exit, _reason -> {:error, :response_stream_closed}
  end

  defp collect_timeout(%__MODULE__{pid: pid}) do
    GenServer.cast(pid, {:cancel, "synchronous_collector_timeout"})
    {:error, :response_stream_collect_timeout}
  end

  defp cancel_state(state, reason) do
    _ = cancel_native(state.native_stream)
    state = cancel_open_candidate_if_present(state)
    :ok = cancel_program(state.program_task)

    {state, _events, _outcome} =
      fail_stream(state, reason,
        code: "response_stream_cancelled",
        retryable: true
      )

    %{state | closing?: true}
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

  defp describe(pid, timeout) do
    result =
      try do
        GenServer.call(pid, :describe, timeout)
      catch
        :exit, {:timeout, _call} ->
          GenServer.cast(pid, {:cancel, "synchronous_collector_timeout"})
          {:error, :response_stream_collect_timeout}

        :exit, _reason ->
          {:error, :response_stream_closed}
      end

    case result do
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
