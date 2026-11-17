defmodule WeComOpenAPI.Bot.Client do
  @moduledoc """
  Supervised WeCom AI-bot long connection implemented as an OTP `:gen_statem`.

  Explicit connection states:

    * `:disconnected` — no open socket; connects immediately on startup or waits
      on a `:state_timeout` backoff timer between reconnect attempts.
    * `:upgrading` — TCP/TLS connection opened via `IMTransport.WebSocket`,
      awaiting the HTTP/1 WebSocket upgrade response.
    * `:authenticating` — WebSocket upgrade completed and `aibot_subscribe` sent,
      guarded by an authentication `:state_timeout`.
    * `:connected` — authenticated (`errcode: 0`); runs periodic `{cmd: "ping"}`
      heartbeats, dispatches inbound callback pushes in supervised tasks, and
      tracks per-`req_id` outbound ACK timers and serialized reply queues.

  The platform allows one live connection per bot and kicks the older holder with
  `disconnected_event` when a newer connection subscribes. The client stops with
  `{:shutdown, :connection_contended}` instead of fighting the newer holder, while
  ordinary socket failures reconnect with exponential backoff.
  """

  @behaviour :gen_statem

  require Logger

  alias IMTransport.WebSocket
  alias WeComOpenAPI.Bot.{Dispatcher, Event}
  alias WeComOpenAPI.Error

  @default_ws_url "wss://openws.work.weixin.qq.com"
  @user_agent "wecom_openapi-elixir/0.1"
  @default_heartbeat_interval_ms :timer.seconds(30)
  @max_missed_pongs 3
  @default_auth_timeout_ms :timer.seconds(15)
  @default_ack_timeout_ms :timer.seconds(10)
  @reconnect_cap_s 30

  defstruct bot_id: nil,
            secret_fn: nil,
            ws_url: nil,
            dispatcher: nil,
            task_supervisor: nil,
            auto_reconnect: true,
            heartbeat_interval_ms: @default_heartbeat_interval_ms,
            auth_timeout_ms: @default_auth_timeout_ms,
            ack_timeout_ms: @default_ack_timeout_ms,
            reconnect_base_ms: 1_000,
            socket: nil,
            reconnect_attempt: 0,
            missed_pongs: 0,
            auth_req_id: nil,
            pending: %{},
            reply_queues: %{},
            dispatch_tasks: %{}

  @type state_name :: :disconnected | :upgrading | :authenticating | :connected
  @type t :: %__MODULE__{}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    opts = validate_opts!(opts)

    case Keyword.get(opts, :name) do
      nil -> :gen_statem.start_link(__MODULE__, opts, [])
      atom when is_atom(atom) -> :gen_statem.start_link({:local, atom}, __MODULE__, opts, [])
      registered -> :gen_statem.start_link(registered, __MODULE__, opts, [])
    end
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Send a fresh-`req_id` frame (`aibot_send_msg`, media upload) and await its
  ack. Returns the full ack frame on `errcode` 0.
  """
  @spec request(:gen_statem.server_ref(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(server, cmd, body, timeout \\ :timer.seconds(15)) do
    call_send_frame(server, {:send_frame, cmd, generate_req_id(cmd), body}, timeout)
  end

  @doc """
  Send a reply frame bound to an inbound `req_id` (`aibot_respond_msg` family)
  and await its ack. Replies to the same `req_id` are serialized. `opts`:

    * `:cmd` — reply command (default `"aibot_respond_msg"`).
    * `:timeout` — caller-side wait (default 15s, above the 10s ack timeout).
  """
  @spec reply(:gen_statem.server_ref(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply(server, req_id, body, opts \\ []) do
    cmd = Keyword.get(opts, :cmd, "aibot_respond_msg")
    timeout = Keyword.get(opts, :timeout, :timer.seconds(15))

    deadline_ms =
      if is_integer(timeout), do: System.monotonic_time(:millisecond) + timeout, else: nil

    call_send_frame(server, {:send_frame, cmd, req_id, body, deadline_ms}, timeout)
  end

  defp call_send_frame(server, message, timeout) do
    :gen_statem.call(server, message, {:clean_timeout, timeout})
  catch
    :exit, {:timeout, _call} -> {:error, %Error{reason: :ack_timeout}}
    :exit, {{:nodedown, _node}, _call} -> {:error, %Error{reason: :transport, raw: :nodedown}}
    :exit, {:noproc, _call} -> {:error, %Error{reason: :not_connected}}
    :exit, {:normal, _call} -> {:error, %Error{reason: :not_connected}}
    :exit, {:shutdown, _call} -> {:error, %Error{reason: :not_connected}}
    :exit, {{:shutdown, reason}, _call} -> {:error, %Error{reason: :not_connected, raw: reason}}
  end

  @spec status(:gen_statem.server_ref()) :: state_name()
  def status(server), do: :gen_statem.call(server, :status)

  @spec stop(:gen_statem.server_ref()) :: :ok
  def stop(server), do: :gen_statem.stop(server)

  @doc false
  @spec generate_req_id(String.t()) :: String.t()
  def generate_req_id(prefix) do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    "#{prefix}_#{System.system_time(:millisecond)}_#{random}"
  end

  @impl :gen_statem
  def init(opts) do
    Process.flag(:trap_exit, true)

    data = %__MODULE__{
      bot_id: Keyword.fetch!(opts, :bot_id),
      secret_fn: wrap_secret(Keyword.fetch!(opts, :secret)),
      ws_url: Keyword.get(opts, :ws_url, @default_ws_url),
      dispatcher: Keyword.fetch!(opts, :dispatcher),
      task_supervisor: Keyword.get(opts, :task_supervisor, WeComOpenAPI.EventTaskSupervisor),
      auto_reconnect: Keyword.get(opts, :auto_reconnect, true),
      heartbeat_interval_ms:
        Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms),
      auth_timeout_ms: Keyword.get(opts, :auth_timeout_ms, @default_auth_timeout_ms),
      ack_timeout_ms: Keyword.get(opts, :ack_timeout_ms, @default_ack_timeout_ms),
      reconnect_base_ms: Keyword.get(opts, :reconnect_base_ms, 1_000)
    }

    {:ok, :disconnected, data, [{:next_event, :internal, :connect}]}
  end

  @impl :gen_statem
  def handle_event({:call, from}, :status, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, {:send_frame, cmd, req_id, body}, state, data) do
    handle_send_frame(from, cmd, req_id, body, nil, state, data)
  end

  def handle_event({:call, from}, {:send_frame, cmd, req_id, body, deadline_ms}, state, data) do
    handle_send_frame(from, cmd, req_id, body, deadline_ms, state, data)
  end

  def handle_event(:internal, :connect, :disconnected, data), do: attempt_connect(data)
  def handle_event(:state_timeout, :reconnect, :disconnected, data), do: attempt_connect(data)

  def handle_event(:state_timeout, :upgrade_timeout, :upgrading, data) do
    emit([:disconnect], %{duration_ms: 0}, %{reason: :upgrade_timeout})
    disconnect_transition(data, :upgrade_timeout, [])
  end

  def handle_event(:state_timeout, :auth_timeout, :authenticating, data) do
    emit([:disconnect], %{duration_ms: 0}, %{reason: :auth_timeout})
    disconnect_transition(data, :auth_timeout, [])
  end

  def handle_event({:timeout, :heartbeat}, :ping, :connected, data) do
    if data.missed_pongs >= @max_missed_pongs do
      emit([:disconnect], %{duration_ms: 0}, %{reason: :heartbeat_timeout})
      disconnect_transition(data, :heartbeat_timeout, [])
    else
      req_id = generate_req_id("ping")
      frame = {:text, Torque.encode!(%{"cmd" => "ping", "headers" => %{"req_id" => req_id}})}

      case WebSocket.send_frame(data.socket, frame) do
        {:ok, socket} ->
          next_data = %{data | socket: socket, missed_pongs: data.missed_pongs + 1}
          {:keep_state, next_data, [heartbeat_action(next_data)]}

        {:error, socket, reason} ->
          disconnect_transition(%{data | socket: socket}, reason, [])
      end
    end
  end

  def handle_event({:timeout, :heartbeat}, :ping, _state, _data), do: :keep_state_and_data

  def handle_event({:timeout, {:ack, req_id}}, :ack_timeout, :connected, data) do
    case Map.pop(data.pending, req_id) do
      {nil, _pending} ->
        :keep_state_and_data

      {from, rest} ->
        next_data = %{data | pending: rest}
        reply = {:reply, from, {:error, %Error{reason: :ack_timeout}}}
        # Close the socket on ACK timeout before this req_id can be reused.
        disconnect_transition(next_data, :ack_timeout, [reply])
    end
  end

  def handle_event({:timeout, {:ack, _req_id}}, :ack_timeout, _state, _data),
    do: :keep_state_and_data

  # A dispatch task finished (telemetry only; the protocol has no push ack).
  def handle_event(:info, {ref, result}, _state, %{dispatch_tasks: tasks} = data)
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        :keep_state_and_data

      {{kind, started_at}, rest} ->
        Process.demonitor(ref, [:flush])
        duration = System.monotonic_time(:millisecond) - started_at
        emit([:frame], %{duration_ms: duration}, %{kind: kind, result: outcome_kind(result)})
        {:keep_state, %{data | dispatch_tasks: rest}}
    end
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        _state,
        %{dispatch_tasks: tasks} = data
      )
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        :keep_state_and_data

      {{kind, started_at}, rest} ->
        duration = System.monotonic_time(:millisecond) - started_at
        Logger.error("wecom_openapi bot dispatch crashed: #{inspect(reason)}")
        emit([:frame], %{duration_ms: duration}, %{kind: kind, result: :crashed})
        {:keep_state, %{data | dispatch_tasks: rest}}
    end
  end

  def handle_event(:info, _message, :disconnected, _data), do: :keep_state_and_data
  def handle_event(:info, _message, _state, %{socket: nil}), do: :keep_state_and_data

  def handle_event(:info, message, state, data) do
    stream_socket_message(message, state, data)
  end

  @impl :gen_statem
  def terminate(_reason, _state, data) do
    Enum.each(Map.keys(data.dispatch_tasks), &Process.demonitor(&1, [:flush]))
    {_clean_data, _cancel_actions, reply_actions} = drop_conn(data, :terminate)
    Enum.each(reply_actions, fn {:reply, from, reply} -> :gen_statem.reply(from, reply) end)
    :ok
  end

  defp handle_send_frame(from, _cmd, _req_id, _body, _deadline_ms, state, _data)
       when state != :connected do
    {:keep_state_and_data, [{:reply, from, {:error, %Error{reason: :not_connected}}}]}
  end

  defp handle_send_frame(from, cmd, req_id, body, deadline_ms, :connected, data) do
    if Map.has_key?(data.pending, req_id) do
      queue = Map.get(data.reply_queues, req_id, :queue.new())

      {:keep_state,
       put_in(data.reply_queues[req_id], :queue.in({from, cmd, body, deadline_ms}, queue))}
    else
      case send_tracked_frame(data, req_id, cmd, body, from) do
        {:ok, next_data, actions} ->
          {:keep_state, next_data, actions}

        {:disconnect, reason, next_data, actions} ->
          disconnect_transition(next_data, reason, actions)
      end
    end
  end

  defp attempt_connect(data) do
    case WebSocket.connect(data.ws_url,
           headers: [{"User-Agent", @user_agent}],
           upgrade: :canonical,
           mint_options: [case_sensitive_headers: true]
         ) do
      {:ok, socket} ->
        emit([:connect], %{duration_ms: 0}, %{host: URI.parse(data.ws_url).host})

        {:next_state, :upgrading, %{data | socket: socket},
         [{:state_timeout, data.auth_timeout_ms, :upgrade_timeout}]}

      {:error, reason} ->
        disconnect_transition(data, reason, [])
    end
  end

  defp stream_socket_message(message, state, data) do
    case WebSocket.stream(data.socket, message) do
      {:ok, socket, frames} ->
        just_opened =
          state == :upgrading and is_nil(data.socket.websocket) and not is_nil(socket.websocket)

        next_data = %{data | socket: socket}

        with {:ok, cur_state, cur_data, actions} <-
               maybe_begin_auth(just_opened, state, next_data) do
          apply_frames(frames, state, cur_state, cur_data, actions)
        end

      {:error, socket, {:websocket_decode, reason}} when state == :upgrading ->
        disconnect_transition(%{data | socket: socket}, {:websocket_decode, reason}, [])

      {:error, socket, {:websocket_decode, reason}} ->
        Logger.warning("wecom_openapi bot decode failed: #{inspect(reason)}")
        {:keep_state, %{data | socket: socket}}

      {:error, socket, reason} ->
        disconnect_transition(%{data | socket: socket}, unwrap_upgrade(reason), [])

      :unknown ->
        :keep_state_and_data
    end
  end

  defp maybe_begin_auth(false, state, data), do: {:ok, state, data, []}

  defp maybe_begin_auth(true, _state, data) do
    req_id = generate_req_id("aibot_subscribe")

    frame = %{
      "cmd" => "aibot_subscribe",
      "headers" => %{"req_id" => req_id},
      "body" => %{"bot_id" => data.bot_id, "secret" => data.secret_fn.()}
    }

    case WebSocket.send_frame(data.socket, {:text, Torque.encode!(frame)}) do
      {:ok, socket} ->
        next_data = %{data | socket: socket, auth_req_id: req_id}
        {:ok, :authenticating, next_data, [{:state_timeout, data.auth_timeout_ms, :auth_timeout}]}

      {:error, socket, reason} ->
        disconnect_transition(%{data | socket: socket}, reason, [])
    end
  end

  defp apply_frames(frames, initial_state, cur_state, cur_data, actions) do
    outcome =
      Enum.reduce_while(frames, {:ok, cur_state, cur_data, actions}, fn frame,
                                                                        {:ok, st, dt, acts} ->
        case handle_frame(frame, st, dt, acts) do
          {:ok, next_st, next_dt, next_acts} -> {:cont, {:ok, next_st, next_dt, next_acts}}
          terminal -> {:halt, terminal}
        end
      end)

    case outcome do
      {:ok, ^initial_state, final_data, final_actions} ->
        {:keep_state, final_data, final_actions}

      {:ok, next_state, final_data, final_actions} ->
        {:next_state, next_state, final_data, final_actions}

      {:disconnect, reason, final_data, final_actions} ->
        disconnect_transition(final_data, reason, final_actions)

      {:stop_terminal, stop_reason, final_data, final_actions} ->
        stop_with_actions(stop_reason, final_data, final_actions)
    end
  end

  defp unwrap_upgrade({:upgrade, reason}), do: reason
  defp unwrap_upgrade(reason), do: reason

  defp handle_frame({:text, json}, state, data, actions) do
    sanitized = String.replace(json, ~r/[\x00-\x08\x0B-\x1F]/, "")

    case Torque.decode(sanitized) do
      {:ok, frame} when is_map(frame) -> route_frame(frame, state, data, actions)
      _other -> {:ok, state, data, actions}
    end
  end

  defp handle_frame({:ping, payload}, state, data, actions) do
    case send_ws_frame({:pong, payload}, data) do
      {:ok, next_data} -> {:ok, state, next_data, actions}
      {:disconnect, reason, next_data} -> {:disconnect, reason, next_data, actions}
    end
  end

  defp handle_frame({:pong, _payload}, state, data, actions), do: {:ok, state, data, actions}

  defp handle_frame({:close, _code, _reason}, _state, data, actions) do
    {:disconnect, :peer_close, data, actions}
  end

  defp handle_frame(_frame, state, data, actions), do: {:ok, state, data, actions}

  defp route_frame(%{"cmd" => cmd} = frame, state, data, actions)
       when cmd in ["aibot_msg_callback", "aibot_event_callback"] do
    event = Event.from_frame(frame)

    if event.event_type == "disconnected_event" do
      emit([:kick], %{duration_ms: 0}, %{bot_id: data.bot_id})
      {clean_data, _cancel_actions, reply_actions} = drop_conn(data, :connection_contended)
      {:stop_terminal, {:shutdown, :connection_contended}, clean_data, actions ++ reply_actions}
    else
      kind = event.event_type || event.msgtype || event.cmd
      started_at = System.monotonic_time(:millisecond)

      task =
        Task.Supervisor.async_nolink(data.task_supervisor, fn ->
          Dispatcher.dispatch(data.dispatcher, event)
        end)

      next_data = %{
        data
        | dispatch_tasks: Map.put(data.dispatch_tasks, task.ref, {kind, started_at})
      }

      {:ok, state, next_data, actions}
    end
  end

  defp route_frame(%{"headers" => %{"req_id" => req_id}} = frame, state, data, actions)
       when is_binary(req_id) do
    cond do
      state == :authenticating and req_id == data.auth_req_id ->
        handle_auth_ack(frame, data, actions)

      state == :connected and Map.has_key?(data.pending, req_id) ->
        handle_call_ack(frame, req_id, data, actions)

      String.starts_with?(req_id, "ping_") ->
        {:ok, state, %{data | missed_pongs: 0}, actions}

      true ->
        {:ok, state, data, actions}
    end
  end

  defp route_frame(_frame, state, data, actions), do: {:ok, state, data, actions}

  defp handle_auth_ack(frame, data, actions) do
    next_data = %{data | auth_req_id: nil}

    case Map.get(frame, "errcode") do
      0 ->
        emit([:authenticated], %{duration_ms: 0}, %{bot_id: next_data.bot_id})
        connected_data = %{next_data | reconnect_attempt: 0, missed_pongs: 0}
        {:ok, :connected, connected_data, actions ++ [heartbeat_action(connected_data)]}

      _errcode ->
        error = %Error{Error.from_ack(frame) | reason: :auth}
        {clean_data, _cancel_actions, reply_actions} = drop_conn(next_data, :auth_rejected)
        {:stop_terminal, {:shutdown, error}, clean_data, actions ++ reply_actions}
    end
  end

  defp handle_call_ack(frame, req_id, data, actions) do
    {from, pending} = Map.pop!(data.pending, req_id)
    next_data = %{data | pending: pending}

    result =
      case Map.get(frame, "errcode") do
        0 -> {:ok, frame}
        _errcode -> {:error, Error.from_ack(frame)}
      end

    emit([:reply], %{duration_ms: 0}, %{result: elem(result, 0)})
    ack_actions = actions ++ [{{:timeout, {:ack, req_id}}, :cancel}, {:reply, from, result}]
    advance_reply_queue(next_data, req_id, ack_actions)
  end

  defp advance_reply_queue(data, req_id, actions) do
    queue = Map.get(data.reply_queues, req_id, :queue.new())
    now_ms = System.monotonic_time(:millisecond)
    advance_reply_queue_loop(data, req_id, queue, actions, now_ms)
  end

  defp advance_reply_queue_loop(data, req_id, queue, actions, now_ms) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {:ok, :connected, %{data | reply_queues: Map.delete(data.reply_queues, req_id)}, actions}

      {{:value, {from, _cmd, _body, deadline_ms}}, rest}
      when is_integer(deadline_ms) and now_ms >= deadline_ms ->
        # The caller already timed out before this queued frame was written to the socket.
        reply = {:reply, from, {:error, %Error{reason: :not_connected}}}
        advance_reply_queue_loop(data, req_id, rest, actions ++ [reply], now_ms)

      {{:value, {from, cmd, body, _deadline_ms}}, rest} ->
        next_data =
          if :queue.is_empty(rest) do
            %{data | reply_queues: Map.delete(data.reply_queues, req_id)}
          else
            put_in(data.reply_queues[req_id], rest)
          end

        case send_tracked_frame(next_data, req_id, cmd, body, from) do
          {:ok, sent_data, send_actions} ->
            {:ok, :connected, sent_data, actions ++ send_actions}

          {:disconnect, reason, failed_data, fail_actions} ->
            {:disconnect, reason, failed_data, actions ++ fail_actions}
        end
    end
  end

  defp send_tracked_frame(%{socket: %{websocket: websocket}} = data, req_id, cmd, body, from)
       when not is_nil(websocket) do
    frame = %{"cmd" => cmd, "headers" => %{"req_id" => req_id}, "body" => body}

    case WebSocket.send_frame(data.socket, {:text, Torque.encode!(frame)}) do
      {:ok, socket} ->
        next_data = %{data | socket: socket, pending: Map.put(data.pending, req_id, from)}
        {:ok, next_data, [{{:timeout, {:ack, req_id}}, data.ack_timeout_ms, :ack_timeout}]}

      {:error, socket, reason} ->
        reply = {:reply, from, {:error, %Error{reason: :transport, raw: reason}}}
        {:disconnect, reason, %{data | socket: socket}, [reply]}
    end
  end

  defp send_tracked_frame(data, _req_id, _cmd, _body, from) do
    {:ok, data, [{:reply, from, {:error, %Error{reason: :not_connected}}}]}
  end

  defp send_ws_frame(_frame, %{socket: nil} = data), do: {:ok, data}
  defp send_ws_frame(_frame, %{socket: %{websocket: nil}} = data), do: {:ok, data}

  defp send_ws_frame(frame, data) do
    case WebSocket.send_frame(data.socket, frame) do
      {:ok, socket} -> {:ok, %{data | socket: socket}}
      {:error, socket, reason} -> {:disconnect, reason, %{data | socket: socket}}
    end
  end

  defp heartbeat_action(data) do
    {{:timeout, :heartbeat}, data.heartbeat_interval_ms, :ping}
  end

  # Same bounds as the official SDK.
  defp backoff_seconds(attempt) do
    min(Bitwise.bsl(1, min(attempt, 5)), @reconnect_cap_s)
  end

  defp disconnect_transition(data, reason, prior_actions) do
    {clean_data, cancel_actions, reply_actions} = drop_conn(data, reason)

    if clean_data.auto_reconnect do
      delay_ms = clean_data.reconnect_base_ms * backoff_seconds(clean_data.reconnect_attempt)
      scheduled_data = %{clean_data | reconnect_attempt: clean_data.reconnect_attempt + 1}

      {:next_state, :disconnected, scheduled_data,
       prior_actions ++
         cancel_actions ++ reply_actions ++ [{:state_timeout, delay_ms, :reconnect}]}
    else
      replies = Enum.filter(prior_actions, &match?({:reply, _, _}, &1)) ++ reply_actions
      stop_with_replies({:shutdown, reason}, clean_data, replies)
    end
  end

  defp stop_with_actions(stop_reason, data, actions) do
    stop_with_replies(stop_reason, data, Enum.filter(actions, &match?({:reply, _, _}, &1)))
  end

  defp stop_with_replies(stop_reason, data, []), do: {:stop, stop_reason, data}

  defp stop_with_replies(stop_reason, data, replies),
    do: {:stop_and_reply, stop_reason, replies, data}

  defp drop_conn(data, reason) do
    WebSocket.close(data.socket)

    cancel_actions =
      [
        {{:timeout, :heartbeat}, :cancel}
        | Enum.map(data.pending, fn {req_id, _from} -> {{:timeout, {:ack, req_id}}, :cancel} end)
      ]

    pending_replies =
      Enum.map(data.pending, fn {_req_id, from} ->
        {:reply, from, {:error, %Error{reason: :transport, raw: reason}}}
      end)

    queued_replies =
      Enum.flat_map(data.reply_queues, fn {_req_id, queue} ->
        queue
        |> :queue.to_list()
        |> Enum.map(fn {from, _cmd, _body, _deadline_ms} ->
          {:reply, from, {:error, %Error{reason: :not_connected, raw: reason}}}
        end)
      end)

    clean_data = %{
      data
      | socket: nil,
        auth_req_id: nil,
        missed_pongs: 0,
        pending: %{},
        reply_queues: %{}
    }

    {clean_data, cancel_actions, pending_replies ++ queued_replies}
  end

  defp outcome_kind(:ok), do: :ok
  defp outcome_kind(:ignored), do: :ignored
  defp outcome_kind({:error, _reason}), do: :error
  defp outcome_kind(_other), do: :unknown

  defp emit(suffix, measurements, metadata) do
    :telemetry.execute([:wecom_openapi, :bot | suffix], measurements, metadata)
  end

  defp wrap_secret(secret) when is_binary(secret), do: fn -> secret end
  defp wrap_secret(fun) when is_function(fun, 0), do: fun

  defp validate_opts!(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :bot_id,
        :secret,
        :dispatcher,
        :ws_url,
        :auto_reconnect,
        :name,
        :task_supervisor,
        :heartbeat_interval_ms,
        :auth_timeout_ms,
        :ack_timeout_ms,
        :reconnect_base_ms
      ])

    unless is_binary(Keyword.fetch!(opts, :bot_id)),
      do: raise(ArgumentError, ":bot_id must be a string")

    secret = Keyword.fetch!(opts, :secret)

    unless is_binary(secret) or is_function(secret, 0),
      do: raise(ArgumentError, ":secret must be a string or a zero-arity function")

    unless match?(%Dispatcher{}, Keyword.fetch!(opts, :dispatcher)),
      do: raise(ArgumentError, ":dispatcher must be a WeComOpenAPI.Bot.Dispatcher")

    opts
  end
end
