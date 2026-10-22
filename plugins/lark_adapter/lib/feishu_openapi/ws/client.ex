defmodule FeishuOpenAPI.WS.Client do
  @moduledoc """
  Long-lived GenServer for Feishu's WebSocket event push.

  Every connect discovers a fresh endpoint, and reconnect timing comes from
  the server, so a client that reconnects to a fixed URI cannot be used.
  Long-connection frames are already authenticated: webhook signature checks
  do not apply, and the frames carry no webhook signature.
  `IMTransport.WebSocket` owns the Mint connection. This module owns Feishu
  frames, fragments, acknowledgements, and reconnect timing.
  """

  use GenServer

  require Logger

  alias Ankole.Logging
  alias FeishuOpenAPI.{Client, Event.Envelope, WS.Frame, WS.Protocol, Event.Dispatcher}
  alias IMTransport.WebSocket

  @default_ping_interval_s 120
  @default_reconnect_interval_s 120
  # First reconnect after a clean close waits a random 0..nonce seconds so a fleet
  # of clients dropped together doesn't reconnect in lockstep (thundering herd).
  @default_reconnect_nonce_s 30
  # Endpoint-discovery error codes that mean the app is misconfigured: retrying
  # can't fix them, so they stop the client instead of reconnecting.
  @fatal_codes [514, 403, 1_000_040_350]
  # Partial fragment sets are evicted 5s after the first fragment arrives. A
  # broken connection can leave fragments that never complete; this bounds the
  # `fragments` map instead of letting it grow unbounded.
  @fragment_ttl_ms :timer.seconds(5)

  #   service_id        — parsed from the WS URL, echoed back in every frame
  #   reconnect_attempt — count since the last successful connect; resets to 0 on
  #                       connect and drives the nonce-vs-interval delay choice
  #   reconnect_count   — max attempts before giving up; -1 means "unlimited"
  #   fragments         — message_id => partial fragment set, evicted after TTL
  #   dispatch_tasks    — Task ref => {frame, event_type, start_ms} for in-flight
  #                       user handlers awaiting an ack
  defstruct client: nil,
            dispatcher: nil,
            task_supervisor: nil,
            auto_reconnect: true,
            socket: nil,
            service_id: 0,
            reconnect_attempt: 0,
            reconnect_interval_s: @default_reconnect_interval_s,
            reconnect_nonce_s: @default_reconnect_nonce_s,
            reconnect_count: -1,
            reconnect_timer: nil,
            ping_interval_s: @default_ping_interval_s,
            ping_timer: nil,
            fragments: %{},
            dispatch_tasks: %{},
            status: :disconnected

  @doc """
  Start a WebSocket client.

  Options:

    * `:client` (required) — `%FeishuOpenAPI.Client{}`
    * `:dispatcher` (required) — `%FeishuOpenAPI.Event.Dispatcher{}`
    * `:auto_reconnect` — default `true`
    * `:name` — optional GenServer name
    * `:task_supervisor` — `Task.Supervisor` name for running user event
      handlers off the main GenServer loop. Defaults to
      `FeishuOpenAPI.EventTaskSupervisor` (started by this application). Pass
      your own for isolation or per-test task supervisors.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Supervisor child spec. The `id` is derived from `opts[:name]` when present
  so multiple WS clients can coexist in the same supervisor tree.
  """
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc "Force an immediate reconnect (drops the current connection)."
  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server), do: GenServer.cast(server, :reconnect)

  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  def stop(server), do: GenServer.stop(server)

  @impl true
  def init(opts) do
    opts = validate_start_opts!(opts)
    client = Keyword.fetch!(opts, :client)
    dispatcher = Keyword.fetch!(opts, :dispatcher)

    state = %__MODULE__{
      client: client,
      dispatcher: dispatcher,
      task_supervisor: Keyword.get(opts, :task_supervisor, FeishuOpenAPI.EventTaskSupervisor),
      auto_reconnect: Keyword.get(opts, :auto_reconnect, true)
    }

    # Connecting is deferred to a message so `start_link/1` returns quickly and
    # supervision startup is not blocked by network I/O.
    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    Logger.info("feishu_openapi ws reconnect requested app_id=#{state.client.app_id}")
    state = state |> clear_reconnect_timer() |> drop_conn()
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, %{socket: socket} = state) when not is_nil(socket),
    do: {:noreply, state}

  def handle_info(:connect, state) do
    state = clear_reconnect_timer(state)

    case do_connect(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, fatal?} ->
        Logger.error("feishu_openapi ws connect failed: #{inspect(reason)} fatal?=#{fatal?}")

        if fatal? do
          {:stop, {:shutdown, reason}, state}
        else
          maybe_schedule_reconnect(state, reason)
        end
    end
  end

  def handle_info(:ping, state) do
    state = handle_send_result(send_ping(state), state, "ping")

    {:noreply, schedule_ping(state)}
  end

  def handle_info(:reconnect, state) do
    Logger.info("feishu_openapi ws reconnecting app_id=#{state.client.app_id}")
    state = clear_reconnect_timer(state)
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info({:shutdown_ws, reason}, state), do: {:stop, {:shutdown, reason}, state}

  def handle_info({:cleanup_fragment, mid}, state) do
    {:noreply, %{state | fragments: Map.delete(state.fragments, mid)}}
  end

  # A late reply after reconnect has no task.
  def handle_info({ref, result}, %{dispatch_tasks: tasks} = state) when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{frame, event_type, start_ms}, rest} ->
        Process.demonitor(ref, [:flush])
        duration_ms = System.monotonic_time(:millisecond) - start_ms
        state = %{state | dispatch_tasks: rest}
        # The ack is written here. Mint connection state belongs to this process.
        log_dispatch_result(frame, event_type, result, duration_ms, state)
        {:noreply, send_dispatch_response(frame, result, duration_ms, state)}
    end
  end

  # A crash still acks, so the provider does not leave the event hanging.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{dispatch_tasks: tasks} = state)
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{frame, event_type, start_ms}, rest} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms

        stacktrace =
          case reason do
            {exception, frames} when is_exception(exception) and is_list(frames) -> frames
            _ -> []
          end

        Logging.error(
          "feishu_openapi.ws.dispatch_crashed",
          "Feishu WebSocket dispatch task exited",
          Map.put(Logging.failure_fields(:exit, reason, stacktrace), :event_type, event_type)
        )

        state = %{state | dispatch_tasks: rest}

        {:noreply,
         send_dispatch_response(
           frame,
           {:error, {:dispatch_crashed, reason}},
           duration_ms,
           state
         )}
    end
  end

  def handle_info(_message, %{socket: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case WebSocket.stream(state.socket, message) do
      {:ok, socket, frames} ->
        just_opened = is_nil(state.socket.websocket) and not is_nil(socket.websocket)
        state = %{state | socket: socket}
        state = if just_opened, do: on_open(state), else: state
        {:noreply, Enum.reduce(frames, state, &handle_ws_frame/2)}

      {:error, socket, {:websocket_decode, reason}} ->
        Logger.warning("feishu_openapi ws decode error: #{inspect(reason)}")
        {:noreply, %{state | socket: socket}}

      {:error, socket, {:upgrade, reason}} ->
        classify_upgrade(%{state | socket: socket}, reason)

      {:error, socket, reason} ->
        Logger.warning("feishu_openapi ws stream error: #{inspect(reason)}")
        state = %{state | socket: socket} |> drop_conn()
        maybe_schedule_reconnect(state, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    drop_conn(state)
    :ok
  end

  defp do_connect(state) do
    with {:ok, endpoint, client_config} <- fetch_endpoint(state.client),
         {:ok, scheme, host, port, path} <- parse_url(endpoint),
         {:ok, socket} <-
           WebSocket.open(scheme, host, port, path,
             headers: [{"user-agent", "feishu_openapi-elixir/0.1"}]
           ) do
      state = apply_client_config(state, Protocol.config_from_map(client_config))

      {:ok,
       %{
         state
         | socket: socket,
           service_id: Protocol.service_id_from_url(endpoint),
           reconnect_attempt: 0,
           reconnect_timer: nil,
           status: :upgrading
       }}
    else
      {:error, %FeishuOpenAPI.Error{code: code} = err} when code in @fatal_codes ->
        {:error, err, true}

      {:error, reason} ->
        {:error, reason, false}
    end
  end

  defp fetch_endpoint(%Client{} = client) do
    # Feishu's WS endpoint discovery is not under `/open-apis`, so the request
    # intentionally uses an absolute path and disables normal auth injection.
    case FeishuOpenAPI.post(client, "/callback/ws/endpoint",
           body: %{AppID: client.app_id, AppSecret: Client.app_secret(client)},
           access_token_type: nil
         ) do
      {:ok, %{"data" => data}} when is_map(data) ->
        with {:ok, url} <- endpoint_url(data) do
          Logger.info(
            "feishu_openapi ws endpoint discovered app_id=#{client.app_id} endpoint_host=#{endpoint_host(url)}"
          )

          {:ok, url, endpoint_client_config(data)}
        end

      {:ok, other} ->
        {:error, {:unexpected_endpoint_shape, other}}

      other ->
        other
    end
  end

  defp endpoint_url(%{"URL" => url}) when is_binary(url), do: {:ok, url}
  defp endpoint_url(%{"url" => url}) when is_binary(url), do: {:ok, url}
  defp endpoint_url(data), do: {:error, {:unexpected_endpoint_shape, %{"data" => data}}}

  defp endpoint_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> "unknown"
    end
  end

  defp endpoint_client_config(data) when is_map(data) do
    Map.get(data, "ClientConfig") || Map.get(data, "client_config") || %{}
  end

  defp parse_url(url) do
    uri = URI.parse(url)

    case uri.scheme do
      "ws" -> parsed_url(uri, :ws)
      "wss" -> parsed_url(uri, :wss)
      other -> {:error, {:bad_scheme, other}}
    end
  end

  defp parsed_url(uri, scheme) do
    port = uri.port || default_port(scheme)

    path =
      case uri.query do
        nil -> uri.path || "/"
        q -> "#{uri.path || "/"}?#{q}"
      end

    {:ok, scheme, uri.host, port, path}
  end

  defp default_port(:ws), do: 80
  defp default_port(:wss), do: 443

  defp on_open(state) do
    Logger.info(
      "feishu_openapi ws connected app_id=#{state.client.app_id} service_id=#{state.service_id} ping_interval_s=#{state.ping_interval_s}"
    )

    state = %{state | status: :connected}
    state = handle_send_result(send_ping(state), state, "ping")
    schedule_ping(state)
  end

  defp classify_upgrade(state, reason) do
    status = state.socket.upgrade_status
    headers = state.socket.upgrade_headers
    state = drop_conn(state)

    case Protocol.classify_handshake(status, headers, reason) do
      {:fatal, reason} ->
        Logger.error("feishu_openapi ws handshake failed: #{inspect(reason)} fatal?=true")
        {:stop, {:shutdown, reason}, state}

      {:retry, reason} ->
        maybe_schedule_reconnect(state, reason)
    end
  end

  defp handle_ws_frame({:binary, bin}, state) do
    case Frame.decode(bin) do
      {:ok, frame} ->
        route_frame(frame, state)

      {:error, reason} ->
        Logger.warning("feishu_openapi frame decode error: #{inspect(reason)}")
        state
    end
  end

  defp handle_ws_frame({:ping, payload}, state) when is_binary(payload) do
    handle_send_result(
      send_websocket_frame({:pong, payload}, state),
      state,
      "transport pong"
    )
  end

  defp handle_ws_frame({:pong, _payload}, state), do: state

  defp handle_ws_frame({:close, code, reason}, state) do
    Logger.warning(
      "feishu_openapi ws closed by peer app_id=#{state.client.app_id} close_code=#{inspect(code)} close_reason=#{inspect(reason)}"
    )

    state
    |> drop_conn()
    |> schedule_reconnect_async({:close, code, reason})
  end

  defp handle_ws_frame(_other, state), do: state

  defp route_frame(frame, state) do
    case reassemble(frame, state) do
      {:ok, full_frame, state} -> do_route(full_frame, state)
      {:pending, state} -> state
    end
  end

  defp do_route(frame, state) do
    case Frame.type(frame) do
      "event" ->
        dispatch_event(frame, state)

      "card" ->
        dispatch_event(frame, state)

      "pong" ->
        apply_pong_config(frame, state)

      "ping" ->
        handle_send_result(send_pong_for(frame, state), state, "pong")

      _ ->
        state
    end
  end

  defp dispatch_event(%Frame{payload: payload} = frame, state) do
    case Torque.decode(payload) do
      {:ok, decoded} ->
        event_type = event_type(decoded)
        log_frame_received(frame, event_type, state)
        start_task_for(frame, event_type, decoded, state)

      {:error, reason} ->
        # A 500 ack stops the provider from resending a frame that cannot be parsed.
        Logger.warning("feishu_openapi ws payload decode error: #{inspect(reason)}")
        send_dispatch_response(frame, {:error, {:payload_decode_error, reason}}, 0, state)
    end
  end

  defp log_frame_received(%Frame{} = frame, event_type, state) do
    Logger.info(
      "feishu_openapi ws frame received app_id=#{state.client.app_id} frame_type=#{frame_type(frame)} event_type=#{event_type}"
    )
  end

  defp log_dispatch_result(%Frame{} = frame, event_type, result, duration_ms, state) do
    Logging.info(
      "feishu_openapi.ws.dispatch_result",
      "Feishu WebSocket event dispatched",
      Map.merge(dispatch_result(result), %{
        app_id: state.client.app_id,
        frame_type: frame_type(frame),
        event_type: event_type,
        duration_ms: duration_ms
      })
    )
  end

  defp start_task_for(%Frame{} = frame, event_type, decoded, %{dispatcher: dispatcher} = state) do
    start_ms = System.monotonic_time(:millisecond)

    # `:trusted_decoded` skips webhook signature checks. The handshake already
    # authenticated the connection, and these frames carry no webhook signature.
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Dispatcher.dispatch(dispatcher, {:trusted_decoded, decoded})
      end)

    %{
      state
      | dispatch_tasks: Map.put(state.dispatch_tasks, task.ref, {frame, event_type, start_ms})
    }
  end

  # The provider redelivers an event that was not acked.
  defp send_dispatch_response(_frame, _dispatch_result, _duration_ms, %{socket: nil} = state),
    do: state

  defp send_dispatch_response(
         _frame,
         _dispatch_result,
         _duration_ms,
         %{socket: %{websocket: nil}} = state
       ),
       do: state

  defp send_dispatch_response(%Frame{} = frame, dispatch_result, duration_ms, state) do
    case Protocol.encode_ws_response(dispatch_result) do
      {:ok, response_payload} ->
        response_frame = %Frame{
          seq_id: frame.seq_id,
          log_id: frame.log_id,
          service: frame.service,
          method: frame.method,
          headers: Protocol.add_biz_rt(frame.headers, duration_ms),
          payload: response_payload
        }

        handle_send_result(send_ws_frame(response_frame, state), state, "response")

      {:error, reason} ->
        Logger.warning("feishu_openapi ws response encode error: #{inspect(reason)}")
        state
    end
  end

  defp frame_type(%Frame{} = frame), do: Frame.type(frame) || "unknown"

  defp event_type(decoded) when is_map(decoded) do
    Envelope.event_type(decoded) ||
      string_field(decoded, "type") ||
      string_field(decoded, "event_type") ||
      "unknown"
  end

  defp string_field(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp dispatch_result({:ok, :no_handler}), do: %{result: "no_handler"}
  defp dispatch_result({:ok, :unknown_event}), do: %{result: "unknown_event"}
  defp dispatch_result({:ok, _result}), do: %{result: "handled"}
  defp dispatch_result({:challenge, _challenge}), do: %{result: "challenge"}

  defp dispatch_result({:error, {:handler_crashed, {kind, reason}}})
       when kind in [:exit, :throw],
       do: Map.put(Logging.failure_fields(kind, reason, []), :result, "handler_crashed")

  defp dispatch_result({:error, {status, reason}})
       when status in [:handler_crashed, :handler_failed],
       do: Map.put(Logging.failure_fields(:error, reason, []), :result, Atom.to_string(status))

  defp dispatch_result({:error, reason}),
    do: Map.put(Logging.failure_fields(:error, reason, []), :result, "error")

  defp dispatch_result(other),
    do: Map.put(Logging.failure_fields(:error, other, []), :result, "invalid_result")

  defp reassemble(%Frame{} = frame, state) do
    case Frame.fragmentation(frame) do
      nil -> {:ok, frame, state}
      {sum, _seq} when sum <= 1 -> {:ok, frame, state}
      {sum, seq} -> fold_fragment(frame, sum, seq, state)
    end
  end

  defp fold_fragment(frame, sum, seq, state) when seq < 0 or seq >= sum do
    Logger.warning(
      "feishu_openapi ws invalid fragment indexes: #{inspect(%{message_id: Frame.message_id(frame), sum: sum, seq: seq})}"
    )

    {:pending, state}
  end

  defp fold_fragment(frame, sum, seq, state) do
    mid = Frame.message_id(frame) || "(anonymous)"

    entry =
      Map.get(state.fragments, mid, %{frames: %{}, created: System.monotonic_time(:millisecond)})

    entry = put_in(entry.frames[seq], frame)

    cond do
      complete_fragment?(sum, entry.frames) ->
        combined = combine_fragments(sum, entry.frames, frame)
        {:ok, combined, %{state | fragments: Map.delete(state.fragments, mid)}}

      true ->
        unless Map.has_key?(state.fragments, mid),
          do: Process.send_after(self(), {:cleanup_fragment, mid}, @fragment_ttl_ms)

        {:pending, %{state | fragments: Map.put(state.fragments, mid, entry)}}
    end
  end

  # Headers come from the fragment that completed the set, not from `seq` order.
  defp combine_fragments(sum, parts, template) do
    payload =
      0..(sum - 1)
      |> Enum.map(&Map.fetch!(parts, &1).payload)
      |> IO.iodata_to_binary()

    %{template | payload: payload}
  end

  defp complete_fragment?(sum, parts) do
    Enum.all?(0..(sum - 1), &Map.has_key?(parts, &1))
  end

  defp send_ping(%{socket: nil} = state), do: {:error, :not_connected, state}
  defp send_ping(%{socket: %{websocket: nil}} = state), do: {:error, :not_connected, state}

  # Application ping (`method: 0`), distinct from a transport ping. The server
  # can attach updated config to the pong.
  defp send_ping(state) do
    frame = %Frame{method: 0, service: state.service_id, headers: [{"type", "ping"}]}
    send_ws_frame(frame, state)
  end

  defp send_pong_for(%Frame{} = incoming, state) do
    frame = %Frame{
      method: 0,
      seq_id: incoming.seq_id,
      log_id: incoming.log_id,
      service: incoming.service,
      headers: [{"type", "pong"}]
    }

    send_ws_frame(frame, state)
  end

  defp send_ws_frame(%Frame{} = frame, state) do
    send_frame(Frame.encode(frame), state)
  end

  defp send_frame(bin, state) do
    send_websocket_frame({:binary, bin}, state)
  end

  defp send_websocket_frame(frame, state) do
    case WebSocket.send_frame(state.socket, frame) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, socket, reason} -> {:error, reason, %{state | socket: socket}}
    end
  end

  defp schedule_ping(%{socket: %{websocket: websocket}, ping_interval_s: ping_interval_s} = state)
       when not is_nil(websocket) and is_integer(ping_interval_s) and ping_interval_s > 0 do
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)
    ref = Process.send_after(self(), :ping, :timer.seconds(state.ping_interval_s))
    %{state | ping_timer: ref}
  end

  defp schedule_ping(state), do: state

  defp reconnect_action(state, reason) do
    cond do
      not state.auto_reconnect ->
        {:stop, reason, state}

      state.reconnect_timer ->
        {:schedule, state}

      state.reconnect_count >= 0 and state.reconnect_attempt >= state.reconnect_count ->
        {:stop, {:reconnect_exhausted, reason}, state}

      true ->
        delay =
          if state.reconnect_attempt == 0 do
            :timer.seconds(:rand.uniform(max(state.reconnect_nonce_s, 1)))
          else
            :timer.seconds(max(state.reconnect_interval_s, 0))
          end

        Logger.warning(
          "feishu_openapi ws reconnect scheduled app_id=#{state.client.app_id} reason=#{inspect(reason)} delay_ms=#{delay} reconnect_attempt=#{state.reconnect_attempt + 1}"
        )

        ref = Process.send_after(self(), :reconnect, delay)

        {:schedule,
         %{state | reconnect_attempt: state.reconnect_attempt + 1, reconnect_timer: ref}}
    end
  end

  defp maybe_schedule_reconnect(state, reason) do
    case reconnect_action(state, reason) do
      {:schedule, state} ->
        {:noreply, state}

      {:stop, reason, state} ->
        {:stop, {:shutdown, reason}, state}
    end
  end

  # A frame fold can only return state. `:shutdown_ws` stops on the next loop.
  defp schedule_reconnect_async(state, reason) do
    case reconnect_action(state, reason) do
      {:schedule, state} ->
        state

      {:stop, reason, state} ->
        send(self(), {:shutdown_ws, reason})
        state
    end
  end

  defp clear_reconnect_timer(state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)
    %{state | reconnect_timer: nil}
  end

  defp handle_send_result({:ok, state}, _old_state, kind)
       when kind in ["ping", "pong", "transport pong"] do
    Logger.debug(
      "feishu_openapi ws #{kind} sent app_id=#{state.client.app_id} service_id=#{state.service_id}"
    )

    state
  end

  defp handle_send_result({:ok, state}, _old_state, _kind), do: state

  defp handle_send_result({:error, reason, send_state}, _old_state, kind) do
    Logger.warning("feishu_openapi ws #{kind} send failed: #{inspect(reason)}")

    send_state
    |> drop_conn()
    |> schedule_reconnect_async(reason)
  end

  defp apply_client_config(state, config) when is_map(config) do
    Enum.reduce(config, state, fn
      {:ping_interval_s, value}, acc -> %{acc | ping_interval_s: value}
      {:reconnect_interval_s, value}, acc -> %{acc | reconnect_interval_s: value}
      {:reconnect_nonce_s, value}, acc -> %{acc | reconnect_nonce_s: value}
      {:reconnect_count, value}, acc -> %{acc | reconnect_count: value}
    end)
  end

  defp apply_pong_config(%Frame{payload: payload}, state) do
    case Protocol.config_from_payload(payload) do
      {:ok, config} ->
        state = apply_client_config(state, config)

        if Map.has_key?(config, :ping_interval_s) do
          schedule_ping(state)
        else
          state
        end

      {:error, reason} ->
        Logger.warning("feishu_openapi ws pong config decode error: #{inspect(reason)}")
        state
    end
  end

  defp drop_conn(state) do
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)
    WebSocket.close(state.socket)
    Enum.each(Map.keys(state.dispatch_tasks), &Process.demonitor(&1, [:flush]))

    %{
      state
      | socket: nil,
        service_id: 0,
        ping_timer: nil,
        status: :disconnected,
        fragments: %{},
        dispatch_tasks: %{}
    }
  end

  defp validate_start_opts!(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [:client, :dispatcher, :auto_reconnect, :name, :task_supervisor])

    unless match?(%Client{}, Keyword.fetch!(opts, :client)) do
      raise ArgumentError, "WS client option :client must be a FeishuOpenAPI.Client struct"
    end

    unless match?(%Dispatcher{}, Keyword.fetch!(opts, :dispatcher)) do
      raise ArgumentError,
            "WS client option :dispatcher must be a FeishuOpenAPI.Event.Dispatcher struct"
    end

    auto_reconnect = Keyword.get(opts, :auto_reconnect, true)

    unless is_boolean(auto_reconnect) do
      raise ArgumentError, "WS client option :auto_reconnect must be a boolean"
    end

    opts
  end

  defp validate_start_opts!(_opts) do
    raise ArgumentError, "WS client options must be a keyword list"
  end
end
