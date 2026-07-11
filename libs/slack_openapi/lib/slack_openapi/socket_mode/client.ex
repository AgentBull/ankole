defmodule SlackOpenAPI.SocketMode.Client do
  @moduledoc """
  Supervised Socket Mode connection with post-dispatch acknowledgements.

  Slack envelopes are dispatched in supervised tasks. The websocket owner only
  parses frames, tracks task references, and writes acknowledgements.
  """

  use GenServer

  require Logger

  alias SlackOpenAPI.{Client, Error}
  alias SlackOpenAPI.SocketMode.Dispatcher

  @fatal_reasons ["invalid_auth", "not_allowed_token_type", "forbidden_team"]
  @default_reconnect_interval_s 15
  @default_reconnect_nonce_s 30

  defstruct client: nil,
            dispatcher: nil,
            task_supervisor: nil,
            auto_reconnect: true,
            conn: nil,
            websocket: nil,
            request_ref: nil,
            reconnect_attempt: 0,
            reconnect_timer: nil,
            reconnect_interval_s: @default_reconnect_interval_s,
            reconnect_nonce_s: @default_reconnect_nonce_s,
            dispatch_tasks: %{},
            upgrade_buffer: <<>>,
            status: :disconnected,
            connection_info: %{}

  @type t :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
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

  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server), do: GenServer.cast(server, :reconnect)

  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @doc "Encodes a Socket Mode acknowledgement frame."
  @spec encode_ack(String.t()) :: binary()
  def encode_ack(envelope_id), do: Torque.encode!(%{"envelope_id" => envelope_id})

  @impl true
  def init(opts) do
    opts = validate_opts!(opts)

    state = %__MODULE__{
      client: Keyword.fetch!(opts, :client),
      dispatcher: Keyword.fetch!(opts, :dispatcher),
      task_supervisor: Keyword.get(opts, :task_supervisor, SlackOpenAPI.EventTaskSupervisor),
      auto_reconnect: Keyword.get(opts, :auto_reconnect, true)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast(:reconnect, state) do
    state = state |> clear_reconnect_timer() |> drop_conn()
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, %{conn: conn} = state) when not is_nil(conn), do: {:noreply, state}

  def handle_info(:connect, state) do
    state = clear_reconnect_timer(state)

    case connect(state) do
      {:ok, connected} -> {:noreply, connected}
      {:error, reason, true} -> {:stop, {:shutdown, reason}, state}
      {:error, reason, false} -> maybe_schedule_reconnect(state, reason)
    end
  end

  def handle_info(:reconnect, state) do
    state = clear_reconnect_timer(state)
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info({:shutdown_socket, reason}, state), do: {:stop, {:shutdown, reason}, state}

  def handle_info({ref, result}, %{dispatch_tasks: tasks} = state) when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        {:noreply, state}

      {{envelope_id, event_type, started_at}, rest} ->
        Process.demonitor(ref, [:flush])
        duration = System.monotonic_time(:millisecond) - started_at
        emit([:envelope], %{duration_ms: duration}, %{event_type: event_type, result: result})
        {:noreply, send_ack(envelope_id, duration, %{state | dispatch_tasks: rest})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{dispatch_tasks: tasks} = state)
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        {:noreply, state}

      {{envelope_id, event_type, started_at}, rest} ->
        duration = System.monotonic_time(:millisecond) - started_at
        Logger.error("slack_openapi Socket Mode dispatch crashed: #{inspect(reason)}")
        emit([:envelope], %{duration_ms: duration}, %{event_type: event_type, result: :crashed})
        {:noreply, send_ack(envelope_id, duration, %{state | dispatch_tasks: rest})}
    end
  end

  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, reason, _responses} ->
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

  defp connect(state) do
    with {:ok, endpoint} <- fetch_endpoint(state.client),
         {:ok, scheme, host, port, path} <- parse_url(endpoint),
         {:ok, conn} <- Mint.HTTP.connect(http_scheme(scheme), host, port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(scheme, conn, path, [{"user-agent", "slack_openapi-elixir/0.1"}]) do
      {:ok,
       %{
         state
         | conn: conn,
           request_ref: ref,
           status: :upgrading,
           reconnect_attempt: 0,
           reconnect_timer: nil
       }}
    else
      {:error, %Error{reason: reason} = error} when reason in @fatal_reasons ->
        {:error, error, true}

      {:error, reason} ->
        {:error, reason, false}

      {:error, _conn, reason} ->
        {:error, reason, false}
    end
  end

  defp fetch_endpoint(client) do
    case SlackOpenAPI.post(client, "apps.connections.open", token: :app, body: %{}) do
      {:ok, %{"url" => url}} when is_binary(url) -> {:ok, url}
      {:ok, body} -> {:error, %Error{reason: :unexpected_shape, raw: body}}
      {:error, _reason} = error -> error
    end
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
        state = %{state | conn: conn, websocket: websocket, status: :upgrading}
        state = decode_buffered_upgrade_data(state)
        handle_responses(rest, state)

      {:error, conn, reason} ->
        state = %{state | conn: conn} |> drop_conn()
        maybe_schedule_reconnect(state, reason)
    end
  end

  defp handle_responses(
         [{:data, ref, data} | rest],
         %{request_ref: ref, websocket: nil} = state
       ) do
    handle_responses(rest, %{state | upgrade_buffer: state.upgrade_buffer <> data})
  end

  defp handle_responses([{:data, ref, data} | rest], %{request_ref: ref} = state) do
    state = decode_ws_data(data, state)
    handle_responses(rest, state)
  end

  defp handle_responses([_response | rest], state), do: handle_responses(rest, state)

  defp decode_buffered_upgrade_data(%{upgrade_buffer: <<>>} = state), do: state

  defp decode_buffered_upgrade_data(state) do
    data = state.upgrade_buffer
    decode_ws_data(data, %{state | upgrade_buffer: <<>>})
  end

  defp decode_ws_data(data, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        Enum.reduce(frames, %{state | websocket: websocket}, &handle_frame/2)

      {:error, websocket, reason} ->
        Logger.warning("slack_openapi Socket Mode decode failed: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp handle_frame({:text, json}, state) do
    case Torque.decode(json) do
      {:ok, envelope} when is_map(envelope) ->
        route_envelope(envelope, state)

      {:error, reason} ->
        Logger.warning("slack_openapi Socket Mode JSON decode failed: #{inspect(reason)}")
        state
    end
  end

  defp handle_frame({:ping, payload}, state), do: send_frame({:pong, payload}, state)
  defp handle_frame({:pong, _payload}, state), do: state

  defp handle_frame({:close, code, reason}, state) do
    state |> drop_conn() |> schedule_reconnect_async({:close, code, reason})
  end

  defp handle_frame(_frame, state), do: state

  defp route_envelope(%{"type" => "hello"} = hello, state) do
    info =
      Map.take(hello, ["num_connections", "connection_info", "debug_info"])

    emit([:connected], %{duration_ms: 0}, info)
    %{state | status: :connected, connection_info: info}
  end

  defp route_envelope(%{"type" => "disconnect", "reason" => "link_disabled"}, state) do
    send(self(), {:shutdown_socket, :link_disabled})
    drop_conn(state)
  end

  defp route_envelope(%{"type" => "disconnect", "reason" => reason}, state) do
    emit([:disconnected], %{duration_ms: 0}, %{reason: reason})
    state |> drop_conn() |> reconnect_immediately(reason)
  end

  defp route_envelope(%{"envelope_id" => envelope_id} = envelope, state) do
    started_at = System.monotonic_time(:millisecond)
    event_type = envelope_event_type(envelope)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Dispatcher.dispatch(state.dispatcher, {:envelope, envelope})
      end)

    %{
      state
      | dispatch_tasks:
          Map.put(state.dispatch_tasks, task.ref, {envelope_id, event_type, started_at})
    }
  end

  defp route_envelope(_envelope, state), do: state

  defp envelope_event_type(%{"type" => "events_api"} = envelope),
    do: get_in(envelope, ["payload", "event", "type"]) || "unknown"

  defp envelope_event_type(%{"type" => "interactive"} = envelope),
    do: get_in(envelope, ["payload", "type"]) || "interactive"

  defp envelope_event_type(envelope), do: Map.get(envelope, "type", "unknown")

  defp send_ack(_envelope_id, _duration, %{conn: nil} = state), do: state

  defp send_ack(envelope_id, duration, state) do
    new_state = send_frame({:text, encode_ack(envelope_id)}, state)
    emit([:ack], %{duration_ms: duration}, %{envelope_id: envelope_id})
    new_state
  end

  defp send_frame(_frame, %{websocket: nil} = state), do: state

  defp send_frame(frame, state) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, conn, reason} ->
            %{state | conn: conn, websocket: websocket}
            |> drop_conn()
            |> schedule_reconnect_async(reason)
        end

      {:error, websocket, reason} ->
        %{state | websocket: websocket}
        |> drop_conn()
        |> schedule_reconnect_async(reason)
    end
  end

  defp reconnect_immediately(state, reason) do
    Logger.info("slack_openapi Socket Mode refresh requested: #{inspect(reason)}")
    send(self(), :connect)
    %{state | reconnect_timer: nil}
  end

  defp reconnect_action(state, reason) do
    cond do
      not state.auto_reconnect ->
        {:stop, reason, state}

      state.reconnect_timer ->
        {:schedule, state}

      true ->
        delay =
          if state.reconnect_attempt == 0 do
            :timer.seconds(:rand.uniform(max(state.reconnect_nonce_s, 1)))
          else
            :timer.seconds(state.reconnect_interval_s)
          end

        ref = Process.send_after(self(), :reconnect, delay)

        {:schedule,
         %{state | reconnect_attempt: state.reconnect_attempt + 1, reconnect_timer: ref}}
    end
  end

  defp maybe_schedule_reconnect(state, reason) do
    case reconnect_action(state, reason) do
      {:schedule, state} -> {:noreply, state}
      {:stop, reason, state} -> {:stop, {:shutdown, reason}, state}
    end
  end

  defp schedule_reconnect_async(state, reason) do
    case reconnect_action(state, reason) do
      {:schedule, state} ->
        state

      {:stop, reason, state} ->
        send(self(), {:shutdown_socket, reason})
        state
    end
  end

  defp clear_reconnect_timer(state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)
    %{state | reconnect_timer: nil}
  end

  defp drop_conn(state) do
    if state.conn, do: Mint.HTTP.close(state.conn)
    Enum.each(Map.keys(state.dispatch_tasks), &Process.demonitor(&1, [:flush]))

    %{
      state
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        dispatch_tasks: %{},
        upgrade_buffer: <<>>,
        status: :disconnected,
        connection_info: %{}
    }
  end

  defp emit(suffix, measurements, metadata) do
    :telemetry.execute([:slack_openapi, :socket | suffix], measurements, metadata)
  end

  defp validate_opts!(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [:client, :dispatcher, :auto_reconnect, :name, :task_supervisor])

    unless match?(%Client{}, Keyword.fetch!(opts, :client)),
      do: raise(ArgumentError, ":client must be a SlackOpenAPI.Client")

    unless match?(%Dispatcher{}, Keyword.fetch!(opts, :dispatcher)),
      do: raise(ArgumentError, ":dispatcher must be a SlackOpenAPI.SocketMode.Dispatcher")

    opts
  end
end
