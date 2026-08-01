defmodule WeComOpenAPI.Bot.Client do
  @moduledoc """
  Supervised WeCom AI-bot long connection.

  Lifecycle per the long-connection protocol:

    1. Open the WebSocket to `wss://openws.work.weixin.qq.com` (no
       registration step or ticket) and send the auth frame
       `{cmd: "aibot_subscribe", headers: {req_id}, body: {bot_id, secret}}`.
       The ack (`{headers: {req_id}, errcode, errmsg}`) carries the result; a
       non-zero errcode is a fatal credential error.
    2. Heartbeat with `{cmd: "ping"}` every 30s; three heartbeats without an
       ack mark the connection dead and trigger a backoff reconnect.
    3. Push frames (`aibot_msg_callback` / `aibot_event_callback`) dispatch in
       a supervised task. The protocol has no client ack for pushes — ingress
       persistence plus `msgid` uniqueness absorb platform re-delivery.
    4. Outbound frames (`aibot_respond_msg`, `aibot_send_msg`, media upload)
       each await their ack frame, correlated by `req_id`. Replies reuse the
       inbound `req_id`, so acks for one `req_id` are indistinguishable from
       each other — replies to the same `req_id` are therefore queued and sent
       one in flight at a time (same discipline as the official Node SDK).

  The platform allows exactly one live connection per bot and kicks the older
  one when a new connection subscribes, announced by a `disconnected_event`
  event frame. Reconnecting would kick the newer holder back, so the client
  stops with `{:shutdown, :connection_contended}` instead of fighting — the
  official SDK does the same. Plain socket loss still reconnects with backoff.

  Design note: `Mint.WebSocket` is process-less by design — it covers the
  upgrade handshake and frame codec and leaves the process model, reconnects,
  and backoff to its caller, so the GenServer plumbing here is that contract.
  `DingTalkOpenAPI.Stream.Client` shares the Mint plumbing shape on purpose;
  everything above it (auth frame vs ticket registration, ack correlation vs
  ack emission) diverges, so no shared abstraction is extracted.
  """

  use GenServer

  require Logger

  alias WeComOpenAPI.Bot.{Dispatcher, Event}
  alias WeComOpenAPI.Error

  @default_ws_url "wss://openws.work.weixin.qq.com"
  @user_agent "wecom_openapi-elixir/0.1"
  @heartbeat_interval_ms :timer.seconds(30)
  @max_missed_pongs 3
  @auth_timeout_ms :timer.seconds(15)
  @ack_timeout_ms :timer.seconds(10)
  @reconnect_cap_s 30

  defstruct bot_id: nil,
            secret_fn: nil,
            ws_url: nil,
            dispatcher: nil,
            task_supervisor: nil,
            auto_reconnect: true,
            conn: nil,
            websocket: nil,
            request_ref: nil,
            upgrade_buffer: <<>>,
            status: :disconnected,
            reconnect_attempt: 0,
            reconnect_timer: nil,
            heartbeat_timer: nil,
            missed_pongs: 0,
            auth_req_id: nil,
            auth_timer: nil,
            pending: %{},
            pending_seq: 0,
            reply_queues: %{},
            dispatch_tasks: %{}

  @type t :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = validate_opts!(opts)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
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
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def request(server, cmd, body, timeout \\ :timer.seconds(15)) do
    GenServer.call(server, {:send_frame, cmd, generate_req_id(cmd), body}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, %Error{reason: :ack_timeout}}
  end

  @doc """
  Send a reply frame bound to an inbound `req_id` (`aibot_respond_msg` family)
  and await its ack. Replies to the same `req_id` are serialized. `opts`:

    * `:cmd` — reply command (default `"aibot_respond_msg"`).
    * `:timeout` — caller-side wait (default 15s, above the 10s ack timeout).
  """
  @spec reply(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def reply(server, req_id, body, opts \\ []) do
    cmd = Keyword.get(opts, :cmd, "aibot_respond_msg")
    timeout = Keyword.get(opts, :timeout, :timer.seconds(15))
    GenServer.call(server, {:send_frame, cmd, req_id, body}, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, %Error{reason: :ack_timeout}}
  end

  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @doc false
  @spec generate_req_id(String.t()) :: String.t()
  def generate_req_id(prefix) do
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    "#{prefix}_#{System.system_time(:millisecond)}_#{random}"
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      bot_id: Keyword.fetch!(opts, :bot_id),
      secret_fn: wrap_secret(Keyword.fetch!(opts, :secret)),
      ws_url: Keyword.get(opts, :ws_url, @default_ws_url),
      dispatcher: Keyword.fetch!(opts, :dispatcher),
      task_supervisor: Keyword.get(opts, :task_supervisor, WeComOpenAPI.EventTaskSupervisor),
      auto_reconnect: Keyword.get(opts, :auto_reconnect, true)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:send_frame, _cmd, _req_id, _body}, _from, %{status: status} = state)
      when status != :connected do
    {:reply, {:error, %Error{reason: :not_connected}}, state}
  end

  def handle_call({:send_frame, cmd, req_id, body}, from, state) do
    if Map.has_key?(state.pending, req_id) do
      # An ack for this req_id is already outstanding; queue behind it so acks
      # stay attributable (the ack frame carries only the req_id).
      queue = Map.get(state.reply_queues, req_id, [])
      {:noreply, put_in(state.reply_queues[req_id], queue ++ [{from, cmd, body}])}
    else
      {:noreply, send_tracked_frame(state, req_id, cmd, body, from)}
    end
  end

  @impl true
  def handle_info(:connect, %{conn: conn} = state) when not is_nil(conn), do: {:noreply, state}

  def handle_info(:connect, state) do
    state = clear_reconnect_timer(state)

    case connect(state) do
      {:ok, connected} -> {:noreply, connected}
      {:error, reason} -> maybe_schedule_reconnect(state, reason)
    end
  end

  def handle_info(:reconnect, state) do
    state = clear_reconnect_timer(state)
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info({:shutdown_socket, reason}, state), do: {:stop, {:shutdown, reason}, state}

  def handle_info(:heartbeat, %{status: :connected} = state) do
    if state.missed_pongs >= @max_missed_pongs do
      emit([:disconnect], %{duration_ms: 0}, %{reason: :heartbeat_timeout})
      state = state |> drop_conn(:heartbeat_timeout)
      maybe_schedule_reconnect(state, :heartbeat_timeout)
    else
      req_id = generate_req_id("ping")

      state =
        send_ws_frame(
          {:text, Torque.encode!(%{"cmd" => "ping", "headers" => %{"req_id" => req_id}})},
          state
        )

      state = schedule_heartbeat(%{state | missed_pongs: state.missed_pongs + 1})
      {:noreply, state}
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(:auth_timeout, %{status: :authenticating} = state) do
    emit([:disconnect], %{duration_ms: 0}, %{reason: :auth_timeout})
    state = drop_conn(state, :auth_timeout)
    maybe_schedule_reconnect(state, :auth_timeout)
  end

  def handle_info(:auth_timeout, state), do: {:noreply, state}

  def handle_info({:ack_timeout, req_id, seq}, state) do
    case Map.get(state.pending, req_id) do
      {^seq, from, _timer} ->
        state = %{state | pending: Map.delete(state.pending, req_id)}
        GenServer.reply(from, {:error, %Error{reason: :ack_timeout}})
        {:noreply, advance_reply_queue(state, req_id)}

      _other ->
        {:noreply, state}
    end
  end

  # A dispatch task finished (telemetry only; the protocol has no push ack).
  def handle_info({ref, result}, %{dispatch_tasks: tasks} = state) when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        {:noreply, state}

      {{kind, started_at}, rest} ->
        Process.demonitor(ref, [:flush])
        duration = System.monotonic_time(:millisecond) - started_at
        emit([:frame], %{duration_ms: duration}, %{kind: kind, result: outcome_kind(result)})
        {:noreply, %{state | dispatch_tasks: rest}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{dispatch_tasks: tasks} = state)
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        {:noreply, state}

      {{kind, started_at}, rest} ->
        duration = System.monotonic_time(:millisecond) - started_at
        Logger.error("wecom_openapi bot dispatch crashed: #{inspect(reason)}")
        emit([:frame], %{duration_ms: duration}, %{kind: kind, result: :crashed})
        {:noreply, %{state | dispatch_tasks: rest}}
    end
  end

  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, _responses} ->
        state = %{state | conn: conn} |> drop_conn(reason)
        maybe_schedule_reconnect(state, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    drop_conn(state, :terminate)
    :ok
  end

  # --- connection ----------------------------------------------------------

  defp connect(state) do
    with {:ok, scheme, host, port, path} <- parse_url(state.ws_url),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme(scheme), host, port,
             protocols: [:http1],
             case_sensitive_headers: true
           ),
         {:ok, conn, ref} <- wecom_websocket_upgrade(scheme, conn, path) do
      emit([:connect], %{duration_ms: 0}, %{host: host})

      {:ok,
       %{
         state
         | conn: conn,
           request_ref: ref,
           status: :upgrading,
           reconnect_timer: nil
       }}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  # WeCom's long-connection gateway currently treats the RFC 6455 upgrade
  # header names as case-sensitive and returns 404 for Mint.WebSocket's
  # lowercase defaults. Preserve the conventional HTTP/1 spelling used by the
  # official SDK while retaining Mint.WebSocket for framing after the upgrade.
  defp wecom_websocket_upgrade(scheme, conn, path) do
    nonce = :crypto.strong_rand_bytes(16) |> Base.encode64()

    conn =
      conn
      |> Mint.HTTP.put_private(:scheme, scheme)
      |> Mint.HTTP.put_private(:sec_websocket_key, nonce)
      |> Mint.HTTP.put_private(:extensions, [])

    headers = [
      {"Upgrade", "websocket"},
      {"Connection", "Upgrade"},
      {"Sec-WebSocket-Version", "13"},
      {"Sec-WebSocket-Key", nonce},
      {"User-Agent", @user_agent}
    ]

    Mint.HTTP.request(conn, "GET", path, headers, nil)
  end

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["ws", "wss"] and is_binary(host) ->
        ws_scheme = if scheme == "wss", do: :wss, else: :ws
        port = uri.port || if(ws_scheme == :wss, do: 443, else: 80)
        path = if uri.query, do: "#{uri.path || "/"}?#{uri.query}", else: uri.path || "/"
        {:ok, ws_scheme, host, port, path}

      _uri ->
        {:error, :invalid_websocket_url}
    end
  end

  defp http_scheme(:ws), do: :http
  defp http_scheme(:wss), do: :https

  # --- upgrade / decode ----------------------------------------------------

  defp handle_responses([], state), do: {:noreply, state}

  defp handle_responses([{:status, ref, status} | rest], %{request_ref: ref} = state) do
    handle_responses(rest, Map.put(state, :upgrade_status, status))
  end

  defp handle_responses([{:headers, ref, headers} | rest], %{request_ref: ref} = state) do
    handle_responses(rest, Map.put(state, :upgrade_headers, headers))
  end

  defp handle_responses([{:done, ref} | rest], %{request_ref: ref} = state) do
    case Mint.WebSocket.new(
           state.conn,
           ref,
           Map.get(state, :upgrade_status),
           Map.get(state, :upgrade_headers)
         ) do
      {:ok, conn, websocket} ->
        state = %{state | conn: conn, websocket: websocket}
        state = send_auth(state)

        case decode_buffered_upgrade_data(state) do
          {:stop, _reason, _state} = stop -> stop
          state -> handle_responses(rest, state)
        end

      {:error, conn, reason} ->
        state = %{state | conn: conn} |> drop_conn(reason)
        maybe_schedule_reconnect(state, reason)
    end
  end

  defp handle_responses([{:data, ref, data} | rest], %{request_ref: ref, websocket: nil} = state) do
    handle_responses(rest, %{state | upgrade_buffer: state.upgrade_buffer <> data})
  end

  defp handle_responses([{:data, ref, data} | rest], %{request_ref: ref} = state) do
    case decode_ws_data(data, state) do
      {:stop, _reason, _state} = stop -> stop
      state -> handle_responses(rest, state)
    end
  end

  defp handle_responses([_response | rest], state), do: handle_responses(rest, state)

  defp decode_buffered_upgrade_data(%{upgrade_buffer: <<>>} = state), do: state

  defp decode_buffered_upgrade_data(state) do
    case decode_ws_data(state.upgrade_buffer, %{state | upgrade_buffer: <<>>}) do
      {:stop, _reason, _state} = stop -> stop
      state -> state
    end
  end

  defp decode_ws_data(data, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce_while(frames, %{state | websocket: websocket}, fn frame, acc ->
          case handle_frame(frame, acc) do
            {:stop, _reason, _state} = stop -> {:halt, stop}
            next -> {:cont, next}
          end
        end)

      {:error, websocket, reason} ->
        Logger.warning("wecom_openapi bot decode failed: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp handle_frame({:text, json}, state) do
    # The official Node SDK strips stray control bytes before JSON parsing;
    # mirror that so a server quirk does not silently drop frames.
    sanitized = String.replace(json, ~r/[\x00-\x08\x0B-\x1F]/, "")

    case Torque.decode(sanitized) do
      {:ok, frame} when is_map(frame) -> route_frame(frame, state)
      _other -> state
    end
  end

  defp handle_frame({:ping, payload}, state), do: send_ws_frame({:pong, payload}, state)
  defp handle_frame({:pong, _payload}, state), do: state

  defp handle_frame({:close, _code, _reason}, state) do
    state |> drop_conn(:peer_close) |> schedule_reconnect_async(:peer_close)
  end

  defp handle_frame(_frame, state), do: state

  # --- frame routing -------------------------------------------------------

  defp route_frame(%{"cmd" => cmd} = frame, state)
       when cmd in ["aibot_msg_callback", "aibot_event_callback"] do
    event = Event.from_frame(frame)

    if event.event_type == "disconnected_event" do
      # A new connection subscribed with this bot's credentials and the server
      # is dropping this one. Reconnecting would kick the new holder back, so
      # stop instead (official SDK semantics) and let the owner surface it.
      emit([:kick], %{duration_ms: 0}, %{bot_id: state.bot_id})
      {:stop, {:shutdown, :connection_contended}, drop_conn(state, :connection_contended)}
    else
      kind = event.event_type || event.msgtype || event.cmd
      started_at = System.monotonic_time(:millisecond)

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          Dispatcher.dispatch(state.dispatcher, event)
        end)

      %{state | dispatch_tasks: Map.put(state.dispatch_tasks, task.ref, {kind, started_at})}
    end
  end

  defp route_frame(%{"headers" => %{"req_id" => req_id}} = frame, state)
       when is_binary(req_id) do
    cond do
      req_id == state.auth_req_id -> handle_auth_ack(frame, state)
      String.starts_with?(req_id, "ping_") -> handle_ping_ack(frame, state)
      Map.has_key?(state.pending, req_id) -> handle_call_ack(frame, req_id, state)
      true -> state
    end
  end

  defp route_frame(_frame, state), do: state

  # --- auth ----------------------------------------------------------------

  defp send_auth(state) do
    req_id = generate_req_id("aibot_subscribe")

    frame = %{
      "cmd" => "aibot_subscribe",
      "headers" => %{"req_id" => req_id},
      "body" => %{"bot_id" => state.bot_id, "secret" => state.secret_fn.()}
    }

    auth_timer = Process.send_after(self(), :auth_timeout, @auth_timeout_ms)
    state = %{state | status: :authenticating, auth_req_id: req_id, auth_timer: auth_timer}
    send_ws_frame({:text, Torque.encode!(frame)}, state)
  end

  defp handle_auth_ack(frame, state) do
    if state.auth_timer, do: Process.cancel_timer(state.auth_timer)
    state = %{state | auth_req_id: nil, auth_timer: nil}

    case Map.get(frame, "errcode") do
      0 ->
        emit([:authenticated], %{duration_ms: 0}, %{bot_id: state.bot_id})

        %{state | status: :connected, reconnect_attempt: 0, missed_pongs: 0}
        |> schedule_heartbeat()

      _errcode ->
        # Bad credentials will not heal by retrying; stop so the owner can
        # mark the runtime configuration unavailable.
        error = %Error{Error.from_ack(frame) | reason: :auth}
        {:stop, {:shutdown, error}, drop_conn(state, :auth_rejected)}
    end
  end

  defp handle_ping_ack(_frame, state), do: %{state | missed_pongs: 0}

  defp handle_call_ack(frame, req_id, state) do
    {{_seq, from, timer}, pending} = Map.pop(state.pending, req_id)
    if timer, do: Process.cancel_timer(timer)
    state = %{state | pending: pending}

    result =
      case Map.get(frame, "errcode") do
        0 -> {:ok, frame}
        _errcode -> {:error, Error.from_ack(frame)}
      end

    GenServer.reply(from, result)
    emit([:reply], %{duration_ms: 0}, %{result: elem(result, 0)})
    advance_reply_queue(state, req_id)
  end

  defp advance_reply_queue(state, req_id) do
    case Map.get(state.reply_queues, req_id, []) do
      [] ->
        %{state | reply_queues: Map.delete(state.reply_queues, req_id)}

      [{from, cmd, body} | rest] ->
        state =
          if rest == [] do
            %{state | reply_queues: Map.delete(state.reply_queues, req_id)}
          else
            put_in(state.reply_queues[req_id], rest)
          end

        send_tracked_frame(state, req_id, cmd, body, from)
    end
  end

  defp send_tracked_frame(state, req_id, cmd, body, from) do
    frame = %{"cmd" => cmd, "headers" => %{"req_id" => req_id}, "body" => body}
    seq = state.pending_seq + 1
    timer = Process.send_after(self(), {:ack_timeout, req_id, seq}, @ack_timeout_ms)

    state = %{
      state
      | pending_seq: seq,
        pending: Map.put(state.pending, req_id, {seq, from, timer})
    }

    send_ws_frame({:text, Torque.encode!(frame)}, state)
  end

  # --- heartbeat -----------------------------------------------------------

  defp schedule_heartbeat(state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    timer = Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)
    %{state | heartbeat_timer: timer}
  end

  # --- send / reconnect ----------------------------------------------------

  defp send_ws_frame(_frame, %{websocket: nil} = state), do: state

  defp send_ws_frame(frame, state) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, conn, reason} ->
            %{state | conn: conn, websocket: websocket}
            |> drop_conn(reason)
            |> schedule_reconnect_async(reason)
        end

      {:error, websocket, reason} ->
        %{state | websocket: websocket}
        |> drop_conn(reason)
        |> schedule_reconnect_async(reason)
    end
  end

  defp reconnect_action(state) do
    cond do
      not state.auto_reconnect ->
        {:stop, state}

      state.reconnect_timer ->
        {:schedule, state}

      true ->
        delay = :timer.seconds(backoff_seconds(state.reconnect_attempt))
        ref = Process.send_after(self(), :reconnect, delay)

        {:schedule,
         %{state | reconnect_attempt: state.reconnect_attempt + 1, reconnect_timer: ref}}
    end
  end

  # Exponential backoff from 1s, capped at 30s (official SDK values).
  defp backoff_seconds(attempt) do
    min(Bitwise.bsl(1, min(attempt, 5)), @reconnect_cap_s)
  end

  defp maybe_schedule_reconnect(state, reason) do
    case reconnect_action(state) do
      {:schedule, state} -> {:noreply, state}
      {:stop, state} -> {:stop, {:shutdown, reason}, state}
    end
  end

  defp schedule_reconnect_async(state, reason) do
    case reconnect_action(state) do
      {:schedule, state} ->
        state

      {:stop, state} ->
        send(self(), {:shutdown_socket, reason})
        state
    end
  end

  defp clear_reconnect_timer(state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)
    %{state | reconnect_timer: nil}
  end

  defp drop_conn(state, reason) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    if state.auth_timer, do: Process.cancel_timer(state.auth_timer)
    Enum.each(Map.keys(state.dispatch_tasks), &Process.demonitor(&1, [:flush]))
    fail_pending(state, reason)

    %{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        upgrade_buffer: <<>>,
        status: :disconnected,
        heartbeat_timer: nil,
        auth_timer: nil,
        auth_req_id: nil,
        missed_pongs: 0,
        pending: %{},
        reply_queues: %{},
        dispatch_tasks: %{}
    }
  end

  defp fail_pending(state, reason) do
    error = {:error, %Error{reason: :not_connected, raw: reason}}

    Enum.each(state.pending, fn {_req_id, {_seq, from, timer}} ->
      if timer, do: Process.cancel_timer(timer)
      GenServer.reply(from, error)
    end)

    Enum.each(state.reply_queues, fn {_req_id, queue} ->
      Enum.each(queue, fn {from, _cmd, _body} -> GenServer.reply(from, error) end)
    end)
  end

  # --- helpers -------------------------------------------------------------

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
        :task_supervisor
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
