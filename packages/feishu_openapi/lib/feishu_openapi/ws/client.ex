defmodule FeishuOpenAPI.WS.Client do
  @moduledoc """
  Long-lived GenServer that keeps a Feishu/Lark WebSocket event-push connection
  open and forwards decoded events to a `FeishuOpenAPI.Event.Dispatcher`.

      {:ok, _pid} =
        FeishuOpenAPI.WS.Client.start_link(
          client: FeishuOpenAPI.Client.new(app_id, app_secret),
          dispatcher: my_dispatcher,
          auto_reconnect: true
        )

  Behavior:
    * Calls `POST {base_url}/callback/ws/endpoint` to discover the WS URL and
      runtime config (ping interval, reconnect parameters).
    * Uses `mint_web_socket` for the connection.
    * Sends a `ping` control frame every `ping_interval` seconds (default
      120s, overridable by the server via a `pong` payload).
    * Re-assembles fragmented messages (headers `sum > 1`, `seq`, `message_id`)
      with a 5-second window.
    * Dispatches `event` and `card` messages to the dispatcher as trusted
      decoded payloads. Webhook token/signature verification does not apply to
      long-connection frames.
    * Server error codes `514`, `403`, `1000040350` are treated as fatal
      (client misconfiguration); everything else triggers a backoff-based
      reconnect when `:auto_reconnect` is `true`.
  """

  use GenServer

  require Logger

  alias FeishuOpenAPI.{Client, Event.Envelope, WS.Frame, WS.Protocol, Event.Dispatcher}

  @default_ping_interval_s 120
  @default_reconnect_interval_s 120
  @default_reconnect_nonce_s 30
  @fatal_codes [514, 403, 1_000_040_350]
  @fragment_ttl_ms :timer.seconds(5)

  defstruct client: nil,
            dispatcher: nil,
            task_supervisor: nil,
            auto_reconnect: true,
            conn: nil,
            websocket: nil,
            request_ref: nil,
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
            upgrade_buffer: <<>>,
            status: :disconnected

  # Public API ---------------------------------------------------------

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

  @doc "Return the current WebSocket lifecycle status."
  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @doc "Stop the server gracefully."
  def stop(server), do: GenServer.stop(server)

  # GenServer callbacks ------------------------------------------------

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
  def handle_info(:connect, %{conn: conn} = state) when not is_nil(conn), do: {:noreply, state}

  def handle_info(:connect, state) do
    state = clear_reconnect_timer(state)

    case do_connect(state) do
      {:ok, state} ->
        {:noreply, schedule_ping(state)}

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
    state =
      case send_ping(state) do
        {:ok, s} -> s
        {:error, _reason, s} -> s
      end

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

  def handle_info({ref, result}, %{dispatch_tasks: tasks} = state) when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{frame, event_type, start_ms}, rest} ->
        Process.demonitor(ref, [:flush])
        duration_ms = System.monotonic_time(:millisecond) - start_ms
        state = %{state | dispatch_tasks: rest}
        log_dispatch_result(frame, event_type, result, duration_ms, state)
        {:noreply, send_dispatch_response(frame, result, duration_ms, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{dispatch_tasks: tasks} = state)
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{frame, _event_type, start_ms}, rest} ->
        duration_ms = System.monotonic_time(:millisecond) - start_ms
        Logger.error("feishu_openapi ws dispatch task crashed: #{inspect(reason)}")
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

  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, _responses} ->
        Logger.warning("feishu_openapi ws stream error: #{inspect(reason)}")
        state = %{state | conn: conn} |> drop_conn()
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

  # Connection lifecycle -----------------------------------------------

  defp do_connect(state) do
    with {:ok, endpoint, client_config} <- fetch_endpoint(state.client),
         {:ok, scheme, host, port, path} <- parse_url(endpoint),
         {:ok, conn} <-
           Mint.HTTP.connect(http_scheme(scheme), host, port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(scheme, conn, path, headers()) do
      state =
        state
        |> apply_client_config(Protocol.config_from_map(client_config || %{}))

      {:ok,
       %{
         state
         | conn: conn,
           request_ref: ref,
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

      {:error, _conn, reason} ->
        {:error, reason, false}
    end
  end

  defp fetch_endpoint(%Client{} = client) do
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

    scheme =
      case uri.scheme do
        "ws" -> :ws
        "wss" -> :wss
        other -> throw({:bad_scheme, other})
      end

    port = uri.port || default_port(scheme)

    path =
      case uri.query do
        nil -> uri.path || "/"
        q -> "#{uri.path || "/"}?#{q}"
      end

    {:ok, scheme, uri.host, port, path}
  catch
    {:bad_scheme, s} -> {:error, {:bad_scheme, s}}
  end

  defp default_port(:ws), do: 80
  defp default_port(:wss), do: 443

  defp http_scheme(:ws), do: :http
  defp http_scheme(:wss), do: :https

  defp headers, do: [{"user-agent", "feishu_openapi-elixir/0.1"}]

  # Response handling --------------------------------------------------

  defp handle_responses([], state), do: {:noreply, state}

  defp handle_responses([{:status, ref, status} | rest], %{request_ref: ref} = state) do
    handle_responses(rest, Map.put(state, :_upgrade_status, status))
  end

  defp handle_responses([{:headers, ref, resp_headers} | rest], %{request_ref: ref} = state) do
    handle_responses(rest, Map.put(state, :_upgrade_headers, resp_headers))
  end

  defp handle_responses([{:done, ref} | rest], %{request_ref: ref} = state) do
    upgrade_status = Map.get(state, :_upgrade_status)
    upgrade_headers = Map.get(state, :_upgrade_headers)

    case Mint.WebSocket.new(
           state.conn,
           ref,
           upgrade_status,
           upgrade_headers
         ) do
      {:ok, conn, websocket} ->
        Logger.info("feishu_openapi ws connected app_id=#{state.client.app_id}")
        state = %{state | conn: conn, websocket: websocket, status: :connected}
        handle_responses(rest, state)

      {:error, conn, reason} ->
        state = %{state | conn: conn} |> drop_conn()

        case Protocol.classify_handshake(upgrade_status, upgrade_headers, reason) do
          {:fatal, reason} ->
            Logger.error("feishu_openapi ws handshake failed: #{inspect(reason)} fatal?=true")

            {:stop, {:shutdown, reason}, state}

          {:retry, reason} ->
            maybe_schedule_reconnect(state, reason)
        end
    end
  end

  defp handle_responses([{:data, ref, data} | rest], %{request_ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = Enum.reduce(frames, %{state | websocket: websocket}, &handle_ws_frame/2)
        handle_responses(rest, state)

      {:error, websocket, reason} ->
        Logger.warning("feishu_openapi ws decode error: #{inspect(reason)}")
        handle_responses(rest, %{state | websocket: websocket})
    end
  end

  defp handle_responses([_other | rest], state) do
    handle_responses(rest, state)
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
    case Jason.decode(payload) do
      {:ok, decoded} ->
        event_type = event_type(decoded)
        log_frame_received(frame, event_type, state)
        start_task_for(frame, event_type, decoded, state)

      {:error, reason} ->
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
    Logger.info(
      "feishu_openapi ws dispatch result app_id=#{state.client.app_id} frame_type=#{frame_type(frame)} event_type=#{event_type} result=#{dispatch_result(result)} duration_ms=#{duration_ms}"
    )
  end

  defp start_task_for(%Frame{} = frame, event_type, decoded, %{dispatcher: dispatcher} = state) do
    start_ms = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Dispatcher.dispatch(dispatcher, {:trusted_decoded, decoded})
      end)

    %{
      state
      | dispatch_tasks: Map.put(state.dispatch_tasks, task.ref, {frame, event_type, start_ms})
    }
  end

  defp send_dispatch_response(_frame, _dispatch_result, _duration_ms, %{conn: nil} = state),
    do: state

  defp send_dispatch_response(_frame, _dispatch_result, _duration_ms, %{websocket: nil} = state),
    do: state

  defp send_dispatch_response(
         _frame,
         _dispatch_result,
         _duration_ms,
         %{request_ref: nil} = state
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

  defp dispatch_result({:ok, :no_handler}), do: "no_handler"
  defp dispatch_result({:ok, :unknown_event}), do: "unknown_event"
  defp dispatch_result({:ok, _result}), do: "handled"
  defp dispatch_result({:challenge, _challenge}), do: "challenge"
  defp dispatch_result({:error, reason}), do: "error:#{inspect(reason)}"
  defp dispatch_result(other), do: inspect(other)

  # Fragmentation ------------------------------------------------------

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

  # Pings / outbound ---------------------------------------------------

  defp send_ping(%{websocket: nil} = state), do: {:error, :not_connected, state}

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
    case Mint.WebSocket.encode(state.websocket, {:binary, bin}) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} -> {:ok, %{state | conn: conn, websocket: websocket}}
          {:error, conn, reason} -> {:error, reason, %{state | conn: conn, websocket: websocket}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  # Timers / lifecycle helpers ----------------------------------------

  defp schedule_ping(%{ping_interval_s: ping_interval_s} = state)
       when is_integer(ping_interval_s) and ping_interval_s > 0 do
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

    if state.conn, do: _ = Mint.HTTP.close(state.conn)

    Enum.each(Map.keys(state.dispatch_tasks), &Process.demonitor(&1, [:flush]))

    %{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
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
