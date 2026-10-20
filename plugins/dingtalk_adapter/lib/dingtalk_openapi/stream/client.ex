defmodule DingTalkOpenAPI.Stream.Client do
  @moduledoc """
  Supervised DingTalk Stream-mode connection with post-dispatch acknowledgements.

  Lifecycle per the Stream protocol:

    1. Register a connection: `POST /v1.0/gateway/connections/open` with
       `{clientId, clientSecret, subscriptions, ua, localIp}` → `{endpoint,
       ticket}`. The ticket is valid for ~90s and single-use, so it is always
       fetched fresh and never cached.
    2. Add the ticket to the returned endpoint and upgrade the WebSocket.
    3. Decode JSON text frames and route by `type`:
       * SYSTEM `ping` → echo the `opaque` payload with the same `messageId`,
         synchronously on the WS loop (never queued behind a handler).
       * SYSTEM `disconnect` → the server is rebalancing; re-register and
         reconnect immediately, letting the old socket close.
       * EVENT / CALLBACK → dispatch in a supervised task; the ack frame is
         written only after the handler (i.e. gateway ingress) commits.

  EVENT frames ack `{"status": "SUCCESS" | "LATER"}` (LATER asks for
  re-delivery); CALLBACK frames ack `{code, data: {"response": ...}}`. A crashed
  dispatch is not acked at all, so the platform re-delivers — ingress idempotency
  keeps that safe.

  A reconnect must re-register for a fresh single-use ticket.
  `IMTransport.WebSocket` owns the Mint connection. This module owns DingTalk
  frames, acknowledgements, and reconnect timing.
  """

  use GenServer

  require Logger

  alias DingTalkOpenAPI.{Client, Error}
  alias DingTalkOpenAPI.Stream.Dispatcher
  alias IMTransport.WebSocket

  @open_path "/v1.0/gateway/connections/open"
  @user_agent "dingtalk_openapi-elixir/0.1"
  @reconnect_cap_s 60

  defstruct client: nil,
            dispatcher: nil,
            subscriptions: [],
            task_supervisor: nil,
            auto_reconnect: true,
            socket: nil,
            reconnect_attempt: 0,
            reconnect_timer: nil,
            dispatch_tasks: %{},
            status: :disconnected

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

  @spec reconnect(GenServer.server()) :: :ok
  def reconnect(server), do: GenServer.cast(server, :reconnect)

  @spec status(GenServer.server()) :: atom()
  def status(server), do: GenServer.call(server, :status)

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  @impl true
  def init(opts) do
    dispatcher = Keyword.fetch!(opts, :dispatcher)

    state = %__MODULE__{
      client: Keyword.fetch!(opts, :client),
      dispatcher: dispatcher,
      subscriptions: subscriptions(opts, dispatcher),
      task_supervisor: Keyword.get(opts, :task_supervisor, DingTalkOpenAPI.EventTaskSupervisor),
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
  def handle_info(:connect, %{socket: socket} = state) when not is_nil(socket),
    do: {:noreply, state}

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

  # A dispatch task finished; write the ack it decided on (or withhold).
  def handle_info({ref, result}, %{dispatch_tasks: tasks} = state) when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        {:noreply, state}

      {{message_id, event_type, started_at}, rest} ->
        Process.demonitor(ref, [:flush])
        duration = System.monotonic_time(:millisecond) - started_at
        state = %{state | dispatch_tasks: rest}

        emit([:frame], %{duration_ms: duration}, %{
          event_type: event_type,
          result: ack_kind(result)
        })

        {:noreply, apply_ack(result, message_id, duration, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{dispatch_tasks: tasks} = state)
      when is_reference(ref) do
    case Map.pop(tasks, ref) do
      {nil, _rest} ->
        {:noreply, state}

      {{_message_id, event_type, started_at}, rest} ->
        duration = System.monotonic_time(:millisecond) - started_at
        Logger.error("dingtalk_openapi Stream dispatch crashed: #{inspect(reason)}")
        emit([:frame], %{duration_ms: duration}, %{event_type: event_type, result: :crashed})
        # No commit guarantee on crash → withhold the ack; the platform redelivers.
        {:noreply, %{state | dispatch_tasks: rest}}
    end
  end

  def handle_info(_message, %{socket: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case WebSocket.stream(state.socket, message) do
      {:ok, socket, frames} ->
        just_opened = is_nil(state.socket.websocket) and not is_nil(socket.websocket)
        state = %{state | socket: socket}
        state = if just_opened, do: on_open(state), else: state
        {:noreply, Enum.reduce(frames, state, &handle_frame/2)}

      {:error, socket, {:websocket_decode, reason}} ->
        Logger.warning("dingtalk_openapi Stream decode failed: #{inspect(reason)}")
        {:noreply, %{state | socket: socket}}

      {:error, socket, reason} ->
        reason = unwrap_upgrade(reason)
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

  defp connect(state) do
    with {:ok, endpoint, ticket} <- register_connection(state),
         url = connect_url(endpoint, ticket),
         {:ok, socket} <- WebSocket.connect(url, headers: [{"user-agent", @user_agent}]) do
      emit([:connect], %{duration_ms: 0}, %{host: URI.parse(url).host})

      # The backoff counter resets only once the WebSocket is established, so an
      # endpoint that accepts the upgrade request but never completes the
      # handshake still backs off exponentially.
      {:ok, %{state | socket: socket, status: :upgrading, reconnect_timer: nil}}
    else
      {:error, %Error{reason: reason} = error} when reason in [:auth] ->
        {:error, error, true}

      {:error, reason} ->
        {:error, reason, false}
    end
  end

  defp register_connection(%{client: client, subscriptions: subscriptions}) do
    body = %{
      "clientId" => client.client_id,
      "clientSecret" => Client.client_secret(client),
      "subscriptions" => subscriptions,
      "ua" => @user_agent,
      "localIp" => "127.0.0.1"
    }

    case DingTalkOpenAPI.post(client, @open_path, body: body, token: nil) do
      {:ok, %{"endpoint" => endpoint, "ticket" => ticket}}
      when is_binary(endpoint) and is_binary(ticket) ->
        {:ok, endpoint, ticket}

      {:ok, other} ->
        {:error, %Error{reason: :unexpected_shape, raw: other}}

      {:error, _reason} = error ->
        error
    end
  end

  defp connect_url(endpoint, ticket) do
    uri = URI.parse(endpoint)

    query =
      case uri.query do
        nil -> %{}
        existing -> URI.decode_query(existing)
      end
      |> Map.put("ticket", ticket)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  defp on_open(state), do: %{state | status: :connected, reconnect_attempt: 0}

  defp unwrap_upgrade({:upgrade, reason}), do: reason
  defp unwrap_upgrade(reason), do: reason

  defp handle_frame({:text, json}, state) do
    case Torque.decode(json) do
      {:ok, frame} when is_map(frame) -> route_frame(frame, state)
      _other -> state
    end
  end

  defp handle_frame({:ping, payload}, state), do: send_ws_frame({:pong, payload}, state)
  defp handle_frame({:pong, _payload}, state), do: state

  defp handle_frame({:close, _code, _reason}, state) do
    state |> drop_conn() |> schedule_reconnect_async(:peer_close)
  end

  defp handle_frame(_frame, state), do: state

  defp route_frame(
         %{"type" => "SYSTEM", "headers" => %{"topic" => "ping"} = headers} = frame,
         state
       ) do
    opaque = frame |> decoded_data() |> Map.get("opaque")
    send_response_frame(headers, 200, %{"opaque" => opaque}, state)
  end

  defp route_frame(%{"type" => "SYSTEM", "headers" => %{"topic" => "disconnect"}}, state) do
    # Server-side load-balancing disconnect: re-register and reconnect at once.
    emit([:disconnect], %{duration_ms: 0}, %{reason: :server_rebalance})
    state |> drop_conn() |> reconnect_immediately()
  end

  defp route_frame(%{"type" => "SYSTEM"}, state), do: state

  defp route_frame(%{"type" => type, "headers" => headers} = frame, state)
       when type in ["EVENT", "CALLBACK"] do
    event = DingTalkOpenAPI.Event.from_frame(frame)
    message_id = Map.get(headers, "messageId")
    event_type = event.event_type || event.topic || type
    started_at = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Dispatcher.dispatch(state.dispatcher, event)
      end)

    %{
      state
      | dispatch_tasks:
          Map.put(state.dispatch_tasks, task.ref, {message_id, event_type, started_at})
    }
  end

  defp route_frame(_frame, state), do: state

  defp decoded_data(%{"data" => data}) when is_binary(data) do
    case Torque.decode(data) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decoded_data(%{"data" => data}) when is_map(data), do: data
  defp decoded_data(_frame), do: %{}

  defp apply_ack({:reply, code, data}, message_id, duration, state) do
    send_response_frame(%{"messageId" => message_id}, code, data, state, duration)
  end

  defp apply_ack({:withhold, _reason}, _message_id, _duration, state), do: state

  defp send_response_frame(request_headers, code, data, state, duration \\ 0)

  defp send_response_frame(_headers, _code, _data, %{socket: nil} = state, _duration), do: state

  defp send_response_frame(
         _headers,
         _code,
         _data,
         %{socket: %{websocket: nil}} = state,
         _duration
       ),
       do: state

  defp send_response_frame(request_headers, code, data, state, duration) do
    response =
      %{
        "code" => code,
        "headers" => %{
          "messageId" => Map.get(request_headers, "messageId"),
          "contentType" => "application/json"
        },
        "message" => "OK",
        "data" => Torque.encode!(data || %{})
      }

    new_state = send_ws_frame({:text, Torque.encode!(response)}, state)
    emit([:ack], %{duration_ms: duration}, %{code: code})
    new_state
  end

  defp ack_kind({:reply, code, %{"status" => status}}), do: {code, status}
  defp ack_kind({:reply, code, _data}), do: code
  defp ack_kind({:withhold, _reason}), do: :withheld
  defp ack_kind(_other), do: :unknown

  defp send_ws_frame(_frame, %{socket: nil} = state), do: state
  defp send_ws_frame(_frame, %{socket: %{websocket: nil}} = state), do: state

  defp send_ws_frame(frame, state) do
    case WebSocket.send_frame(state.socket, frame) do
      {:ok, socket} ->
        %{state | socket: socket}

      {:error, socket, reason} ->
        %{state | socket: socket} |> drop_conn() |> schedule_reconnect_async(reason)
    end
  end

  defp reconnect_immediately(state) do
    send(self(), :connect)
    %{state | reconnect_timer: nil}
  end

  defp reconnect_action(state, _reason) do
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

  # Every retry re-registers. The ticket is single-use.
  defp backoff_seconds(attempt) do
    min(Bitwise.bsl(1, min(attempt, 6)), @reconnect_cap_s)
  end

  defp maybe_schedule_reconnect(state, reason) do
    case reconnect_action(state, reason) do
      {:schedule, state} -> {:noreply, state}
      {:stop, state} -> {:stop, {:shutdown, reason}, state}
    end
  end

  defp schedule_reconnect_async(state, reason) do
    case reconnect_action(state, reason) do
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

  defp drop_conn(state) do
    WebSocket.close(state.socket)
    Enum.each(Map.keys(state.dispatch_tasks), &Process.demonitor(&1, [:flush]))

    %{
      state
      | socket: nil,
        dispatch_tasks: %{},
        status: :disconnected
    }
  end

  defp subscriptions(opts, dispatcher) do
    case Keyword.get(opts, :subscriptions) do
      subs when is_list(subs) -> subs
      _absent -> derive_subscriptions(dispatcher)
    end
  end

  defp derive_subscriptions(dispatcher) do
    callbacks =
      dispatcher
      |> Dispatcher.callback_topics()
      |> Enum.map(&%{"type" => "CALLBACK", "topic" => &1})

    events =
      if Dispatcher.events?(dispatcher), do: [%{"type" => "EVENT", "topic" => "*"}], else: []

    callbacks ++ events
  end

  defp emit(suffix, measurements, metadata) do
    :telemetry.execute([:dingtalk_openapi, :stream | suffix], measurements, metadata)
  end

  defp validate_opts!(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :client,
        :dispatcher,
        :subscriptions,
        :auto_reconnect,
        :name,
        :task_supervisor
      ])

    unless match?(%Client{}, Keyword.fetch!(opts, :client)),
      do: raise(ArgumentError, ":client must be a DingTalkOpenAPI.Client")

    unless match?(%Dispatcher{}, Keyword.fetch!(opts, :dispatcher)),
      do: raise(ArgumentError, ":dispatcher must be a DingTalkOpenAPI.Stream.Dispatcher")

    opts
  end
end
