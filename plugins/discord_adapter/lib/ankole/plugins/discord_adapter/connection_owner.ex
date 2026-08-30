defmodule Ankole.Plugins.DiscordAdapter.ConnectionOwner do
  @moduledoc """
  Owns one Discord gateway session for one enabled binding.

  Discord has no per-event acknowledgement. The client stores the sequence
  number of the last event it handled and a RESUME replays everything after it,
  so the owner advances the sequence only after ingress durably accepted or
  explicitly ignored the event. Received events stay in a bounded local queue
  across reconnects, and SignalsGateway deduplicates gateway replays with its
  durable source keys.

  Durable handling runs in one supervised task at a time. The owner keeps
  reading frames and answering heartbeats while that task runs, because a slow
  ingress or a large attachment download would otherwise miss a heartbeat and
  make Discord close the connection.
  """

  use GenServer

  alias Ankole.Logging
  alias Ankole.Plugins.DiscordAdapter.{Client, Config, Dispatcher, Gateway, Socket}

  @registry Ankole.Plugins.DiscordAdapter.ConnectionRegistry
  @task_supervisor Ankole.Plugins.DiscordAdapter.EventTaskSupervisor

  @retry_ms 1_000
  @max_backoff_ms 60_000
  @configuration_timeout_ms 15_000
  @default_max_pending_events 1_000

  # Discord counts IDENTIFY against a daily budget, so a connection that needs
  # operator action retries slowly enough to stay far below it.
  @blocked_retry_ms 300_000

  # This adapter runs one shard. A bot large enough to need more shards needs a
  # different placement contract than one binding to one connection.
  @shard {0, 1}

  defstruct [
    :key,
    :secret_fingerprint,
    :consumer_fingerprint,
    :config,
    :client,
    :consumer,
    :bot,
    :gateway_url,
    :resume_url,
    :session_id,
    :sequence,
    :socket,
    :heartbeat_interval_ms,
    :heartbeat_timer,
    :task,
    :task_kind,
    :task_generation,
    :event_retry,
    :blocked_reason,
    :last_error,
    message_content?: false,
    heartbeat_acked?: true,
    connect_messages: [],
    pending: [],
    session_generation: 0,
    reconnect_attempt: 0
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    key = Keyword.fetch!(opts, :key)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, key}})
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec ensure_configuration(GenServer.server(), map(), map()) ::
          {:ok, pid()} | {:error, :configuration_changed}
  def ensure_configuration(server, config, consumer) do
    GenServer.call(server, {:ensure_configuration, config, consumer}, @configuration_timeout_ms)
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def format_status(%{state: %__MODULE__{} = state} = status),
    do: %{status | state: public_status(state)}

  def format_status(status), do: status

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    consumer = Keyword.fetch!(opts, :consumer)

    {:ok,
     %__MODULE__{
       key: Keyword.fetch!(opts, :key),
       secret_fingerprint: Config.secret_fingerprint(config),
       consumer_fingerprint: fingerprint(consumer),
       config: config,
       client: Config.client(config),
       consumer: consumer
     }, {:continue, :preflight}}
  end

  @impl true
  def handle_continue(:preflight, state), do: {:noreply, start_preflight(state)}

  @impl true
  def handle_call({:ensure_configuration, config, consumer}, _from, state) do
    unchanged? =
      Config.secret_fingerprint(config) == state.secret_fingerprint and
        fingerprint(consumer) == state.consumer_fingerprint

    reply = if unchanged?, do: {:ok, self()}, else: {:error, :configuration_changed}
    {:reply, reply, state}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def handle_info(:preflight, %{task: nil} = state), do: {:noreply, start_preflight(state)}
  def handle_info(:preflight, state), do: {:noreply, state}

  def handle_info(
        {:retry_event, token},
        %{event_retry: {_timer, token}, task: nil} = state
      ) do
    {:noreply, start_next_event(%{state | event_retry: nil})}
  end

  def handle_info({:retry_event, token}, %{event_retry: {_timer, token}} = state) do
    {:noreply, state |> Map.put(:event_retry, nil) |> schedule_event_retry()}
  end

  def handle_info({:retry_event, _stale_token}, state), do: {:noreply, state}

  def handle_info(:connect, %{blocked_reason: nil, socket: nil, task: nil} = state),
    do: {:noreply, start_connect(state)}

  def handle_info(:connect, %{blocked_reason: nil, socket: nil} = state) do
    Process.send_after(self(), :connect, @retry_ms)
    {:noreply, state}
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(:heartbeat, %{socket: nil} = state), do: {:noreply, state}

  # A missing acknowledgement means the connection is a zombie: the socket is
  # open but Discord stopped answering, so the only repair is a new connection
  # that resumes the same session.
  def handle_info(:heartbeat, %{heartbeat_acked?: false} = state) do
    {:noreply, reconnect(state, :heartbeat_timeout)}
  end

  def handle_info(:heartbeat, state) do
    state
    |> send_payload(Gateway.heartbeat(state.sequence))
    |> case do
      %{socket: nil} = dropped ->
        {:noreply, dropped}

      sent ->
        {:noreply,
         schedule_heartbeat(%{sent | heartbeat_acked?: false}, sent.heartbeat_interval_ms)}
    end
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     handle_task_result(result, %{state | task: nil, task_kind: nil, task_generation: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Logging.warning(
      "discord_adapter.connection_owner.task_failed",
      "Discord gateway task failed",
      %{connection_key: inspect(state.key), reason: sanitize_reason(reason)}
    )

    result =
      case {state.task_kind, state.task_generation} do
        {:event, generation} when is_integer(generation) ->
          {:event_error, generation, :event_task_failed}

        {:connect, nil} ->
          {:connect_error, :connect_task_failed}

        {:preflight, nil} ->
          {:preflight_error, :preflight_task_failed}

        _unknown ->
          {:preflight_error, :task_failed}
      end

    {:noreply,
     handle_task_result(result, %{state | task: nil, task_kind: nil, task_generation: nil})}
  end

  # Mint can forward transport messages as soon as the connect task transfers
  # socket ownership. Keep those few messages until the task result installs
  # the matching connection state.
  def handle_info(message, %{task_kind: :connect, socket: nil} = state) do
    {:noreply, %{state | connect_messages: [message | state.connect_messages]}}
  end

  def handle_info(message, %{socket: %Socket{}} = state) do
    {:noreply, handle_socket_message(message, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_socket_message(message, state) do
    case Socket.stream(state.socket, message) do
      {:ok, socket, frames} ->
        handle_frames(frames, %{state | socket: socket})

      {:error, socket, reason} ->
        reconnect(%{state | socket: socket}, sanitize_reason(reason))

      :unknown ->
        state
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    Socket.close(state.socket)
    :ok
  end

  defp start_preflight(state) do
    client = state.client

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        with {:ok, user} <- Client.current_user(client),
             {:ok, application} <- Client.current_application(client),
             {:ok, gateway} <- Client.gateway_bot(client) do
          {:preflight,
           %{
             bot: %{id: user["id"], username: user["username"]},
             message_content?: Gateway.message_content_flag?(application["flags"]),
             gateway_url: gateway["url"]
           }}
        else
          # Tagged so a failed preflight and a failed event handler cannot take
          # each other's branch of the state machine.
          {:error, error} -> {:preflight_error, error}
        end
      end)

    %{state | task: task, task_kind: :preflight, task_generation: nil}
  end

  defp handle_task_result({:preflight, preflight}, state) do
    send(self(), :connect)

    %{
      state
      | bot: preflight.bot,
        message_content?: preflight.message_content?,
        gateway_url: preflight.gateway_url,
        blocked_reason: nil,
        last_error: nil
    }
  end

  defp handle_task_result({:preflight_error, %Client.Error{status: status} = error}, state)
       when status in [401, 403] do
    Process.send_after(self(), :preflight, @blocked_retry_ms)
    %{state | blocked_reason: block_reason(status), last_error: safe_error(error)}
  end

  defp handle_task_result(
         {:preflight_error, %Client.Error{status: 429} = error},
         state
       ) do
    delay = max((error.retry_after || 1) * 1_000, @retry_ms)
    Process.send_after(self(), :preflight, delay)
    %{state | last_error: safe_error(error)}
  end

  defp handle_task_result({:preflight_error, error}, state) do
    Process.send_after(self(), :preflight, @retry_ms)
    %{state | last_error: sanitize_reason(error)}
  end

  defp handle_task_result({:connected, socket}, state) do
    messages = Enum.reverse(state.connect_messages)
    state = %{state | socket: socket, heartbeat_acked?: true, connect_messages: []}

    Enum.reduce_while(messages, state, fn
      message, %{socket: %Socket{}} = connected ->
        {:cont, handle_socket_message(message, connected)}

      _message, disconnected ->
        {:halt, disconnected}
    end)
  end

  defp handle_task_result({:connect_error, reason}, state) do
    schedule_reconnect(%{state | connect_messages: [], last_error: sanitize_reason(reason)})
  end

  # The event was accepted durably, so its queue entry can leave. Only the
  # session that received it can move the current session's resume point.
  # Durable progress also resets the reconnect backoff: a resume handshake
  # alone must not, because the reconnect cycle for a failing ingress resumes
  # successfully every time.
  defp handle_task_result({:handled, generation, sequence}, state) do
    state
    |> cancel_event_retry()
    |> drop_pending_head()
    |> advance_sequence(generation, sequence)
    |> Map.merge(%{last_error: nil, reconnect_attempt: 0})
    |> start_next_event()
  end

  defp handle_task_result(
         {:event_error, generation, reason},
         %{session_generation: generation} = state
       ) do
    reconnect(state, sanitize_reason(reason))
  end

  # A fresh IDENTIFY cannot replay the old session. Keep a failed old event and
  # retry it locally without moving the new session's sequence.
  defp handle_task_result({:event_error, _old_generation, reason}, state) do
    state
    |> Map.put(:last_error, sanitize_reason(reason))
    |> schedule_event_retry()
  end

  defp handle_task_result(_other, state), do: %{state | last_error: :invalid_task_result}

  defp start_connect(state) do
    owner = self()
    url = connect_url(state)

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        case Socket.connect(url, owner) do
          {:ok, socket} -> {:connected, socket}
          {:error, reason} -> {:connect_error, reason}
        end
      end)

    %{
      state
      | task: task,
        task_kind: :connect,
        task_generation: nil,
        connect_messages: []
    }
  end

  # A resume must go to the URL READY handed out; a fresh identify goes to the
  # URL the REST preflight read.
  defp connect_url(%{session_id: session_id, resume_url: resume_url})
       when is_binary(session_id) and is_binary(resume_url),
       do: resume_url

  defp connect_url(state), do: state.gateway_url

  defp handle_frames(frames, state), do: Enum.reduce(frames, state, &handle_frame/2)

  defp handle_frame(_frame, %{socket: nil} = state), do: state

  defp handle_frame({:text, data}, state) do
    case Ankole.JSON.decode(data) do
      {:ok, payload} -> handle_payload(Gateway.classify(payload), state)
      {:error, _reason} -> state
    end
  end

  defp handle_frame({:close, code, _reason}, state), do: handle_close(code, state)
  defp handle_frame(:close, state), do: handle_close(nil, state)
  defp handle_frame({:ping, data}, state), do: send_frame(state, {:pong, data})
  defp handle_frame(_frame, state), do: state

  defp handle_payload({:hello, interval_ms}, state) do
    %{state | heartbeat_interval_ms: interval_ms, heartbeat_acked?: true}
    |> schedule_heartbeat(Gateway.first_heartbeat_delay(interval_ms))
    |> then(&send_payload(&1, opening_payload(&1)))
  end

  defp handle_payload(:heartbeat_ack, state), do: %{state | heartbeat_acked?: true}

  defp handle_payload(:heartbeat_request, state),
    do: send_payload(state, Gateway.heartbeat(state.sequence))

  defp handle_payload(:reconnect, state), do: reconnect(state, :gateway_requested_reconnect)

  defp handle_payload({:invalid_session, true}, state),
    do: reconnect(state, :invalid_session_resumable)

  defp handle_payload({:invalid_session, false}, state) do
    %{state | session_id: nil, sequence: nil} |> reconnect(:invalid_session)
  end

  defp handle_payload({:dispatch, "READY", sequence, data}, state) do
    user = Map.get(data, "user") || %{}

    %{
      state
      | session_id: data["session_id"],
        resume_url: data["resume_gateway_url"],
        bot: %{id: user["id"] || state.bot.id, username: user["username"]},
        sequence: sequence,
        session_generation: state.session_generation + 1,
        reconnect_attempt: 0,
        last_error: nil
    }
    |> start_next_event()
  end

  # The marker goes through the queue so it advances the sequence only after
  # every event replayed before it, and it skips the bound: at the bound a
  # reconnect would otherwise turn every resume into another reconnect.
  defp handle_payload({:dispatch, "RESUMED", sequence, _data}, state) do
    append_pending(%{state | last_error: nil}, "RESUMED", %{}, sequence)
  end

  defp handle_payload({:dispatch, type, sequence, data}, state) do
    state
    |> acknowledge_dispatch(type, data)
    |> enqueue_dispatch(type, data, sequence)
  end

  defp handle_payload(_payload, state), do: state

  defp opening_payload(%{session_id: session_id, sequence: sequence} = state)
       when is_binary(session_id) and is_integer(sequence) do
    Gateway.resume(Config.bot_token(state.config), session_id, sequence)
  end

  defp opening_payload(state) do
    Gateway.identify(Config.bot_token(state.config), state.message_content?, @shard)
  end

  defp start_next_event(%{task: task} = state) when not is_nil(task), do: state
  defp start_next_event(%{event_retry: retry} = state) when not is_nil(retry), do: state
  defp start_next_event(%{pending: []} = state), do: state

  defp start_next_event(%{pending: [event | _rest]} = state) do
    if Dispatcher.handled?(event.type) do
      consumer = state.consumer
      bot = state.bot
      client = state.client

      task =
        Task.Supervisor.async_nolink(@task_supervisor, fn ->
          case Dispatcher.dispatch(event.type, event.data, consumer, bot,
                 client: client,
                 gateway_session_id: event.session_id,
                 gateway_sequence: event.sequence
               ) do
            {:ok, _result} -> {:handled, event.generation, event.sequence}
            {:error, reason} -> {:event_error, event.generation, reason}
          end
        end)

      %{state | task: task, task_kind: :event, task_generation: event.generation}
    else
      state
      |> drop_pending_head()
      |> advance_sequence(event.generation, event.sequence)
      |> start_next_event()
    end
  end

  # At the bound the owner cannot buffer more, so it sheds every event the
  # resume will replay and reconnects; replay brings them back one read at a
  # time. Retaining them would hold the queue at the bound and turn every
  # replayed event into another reconnect.
  defp enqueue_dispatch(state, type, data, sequence) do
    if length(state.pending) >= max_pending_events() do
      state |> shed_replayable_pending() |> reconnect(:pending_event_limit)
    else
      append_pending(state, type, data, sequence)
    end
  end

  defp append_pending(state, type, data, sequence) do
    event = %{
      type: type,
      data: data,
      sequence: sequence,
      generation: state.session_generation,
      session_id: state.session_id
    }

    %{state | pending: state.pending ++ [event]} |> start_next_event()
  end

  # The resume replays every current-session event after the confirmed
  # sequence. The running task's event stays because the task result expects
  # its queue head, and an older session's events stay because no resume can
  # replay them; their local retry is their only path.
  defp shed_replayable_pending(%{pending: pending} = state) do
    {in_flight, sheddable} =
      case {state.task_kind, pending} do
        {:event, [head | rest]} -> {[head], rest}
        _other -> {[], pending}
      end

    kept = Enum.reject(sheddable, &(&1.generation == state.session_generation))
    %{state | pending: in_flight ++ kept}
  end

  defp acknowledge_dispatch(state, "INTERACTION_CREATE", data) do
    client = state.client

    _result =
      Task.Supervisor.start_child(@task_supervisor, fn ->
        Dispatcher.acknowledge("INTERACTION_CREATE", data, client)
      end)

    state
  end

  defp acknowledge_dispatch(state, _type, _data), do: state

  defp drop_pending_head(%{pending: [_head | rest]} = state), do: %{state | pending: rest}
  defp drop_pending_head(state), do: state

  defp advance_sequence(
         %{session_generation: generation} = state,
         generation,
         sequence
       )
       when is_integer(sequence) do
    current = if is_integer(state.sequence), do: state.sequence, else: sequence
    %{state | sequence: max(current, sequence)}
  end

  defp advance_sequence(state, _generation, _sequence), do: state

  defp schedule_event_retry(state) do
    state = cancel_event_retry(state)
    token = make_ref()
    timer = Process.send_after(self(), {:retry_event, token}, @retry_ms)
    %{state | event_retry: {timer, token}}
  end

  defp cancel_event_retry(%{event_retry: nil} = state), do: state

  defp cancel_event_retry(%{event_retry: {timer, _token}} = state) do
    _remaining = Process.cancel_timer(timer)
    %{state | event_retry: nil}
  end

  defp handle_close(code, state) do
    case Gateway.close_action(code) do
      {:fatal, reason} ->
        Process.send_after(self(), :preflight, @blocked_retry_ms)

        %{drop_socket(state) | blocked_reason: reason, last_error: %{close_code: code}}

      :session_invalid ->
        %{state | session_id: nil, sequence: nil} |> reconnect({:close, code})

      :resumable ->
        reconnect(state, {:close, code})
    end
  end

  defp reconnect(state, reason) do
    state
    |> drop_socket()
    |> Map.put(:last_error, sanitize_reason(reason))
    |> schedule_reconnect()
  end

  defp schedule_reconnect(state) do
    attempt = state.reconnect_attempt
    delay = min(@retry_ms * Integer.pow(2, min(attempt, 6)), @max_backoff_ms)
    Process.send_after(self(), :connect, delay)
    %{state | reconnect_attempt: attempt + 1}
  end

  # Keep received events when the socket drops. RESUME can replay them, but a
  # later invalid session cannot, and durable source keys deduplicate repeats.
  defp drop_socket(state) do
    Socket.close(state.socket)
    %{cancel_heartbeat(state) | socket: nil}
  end

  defp schedule_heartbeat(state, delay_ms) when is_integer(delay_ms) do
    state = cancel_heartbeat(state)
    %{state | heartbeat_timer: Process.send_after(self(), :heartbeat, delay_ms)}
  end

  defp schedule_heartbeat(state, _delay_ms), do: state

  # A stale timer from the previous connection would run a second heartbeat
  # loop against the new one.
  defp cancel_heartbeat(%{heartbeat_timer: nil} = state), do: state

  defp cancel_heartbeat(state) do
    _remaining = Process.cancel_timer(state.heartbeat_timer)
    %{state | heartbeat_timer: nil}
  end

  defp send_payload(state, payload), do: send_frame(state, {:text, Torque.encode!(payload)})

  defp send_frame(%{socket: nil} = state, _frame), do: state

  defp send_frame(state, frame) do
    case Socket.send_frame(state.socket, frame) do
      {:ok, socket} -> %{state | socket: socket}
      {:error, socket, reason} -> reconnect(%{state | socket: socket}, sanitize_reason(reason))
    end
  end

  defp block_reason(401), do: :authentication_failed
  defp block_reason(403), do: :permission_denied

  defp max_pending_events do
    :ankole
    |> Application.get_env(Config, [])
    |> Keyword.get(:max_pending_events, @default_max_pending_events)
  end

  defp public_status(state) do
    %{
      key: state.key,
      bot_id: state.bot && state.bot.id,
      bot_username: state.bot && state.bot.username,
      sequence: state.sequence,
      session?: is_binary(state.session_id),
      state: connection_state(state),
      message_content_intent?: state.message_content?,
      pending_events: length(state.pending),
      blocked_reason: state.blocked_reason,
      last_error: state.last_error
    }
  end

  defp connection_state(%{blocked_reason: reason}) when not is_nil(reason), do: :blocked
  defp connection_state(%{session_id: session_id}) when is_binary(session_id), do: :running
  defp connection_state(_state), do: :starting

  defp fingerprint(value) do
    :sha256 |> :crypto.hash(:erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
  end

  defp safe_error(%Client.Error{} = error),
    do: %{kind: error.kind, status: error.status, retry_after: error.retry_after}

  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason({:close, code}), do: %{close_code: code}
  defp sanitize_reason(%Client.Error{} = error), do: safe_error(error)
  defp sanitize_reason(_reason), do: :discord_gateway_failed
end
