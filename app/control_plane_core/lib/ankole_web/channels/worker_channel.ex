defmodule AnkoleWeb.WorkerChannel do
  @moduledoc """
  One Worker connection: transport admission, flow control, and acknowledgements.

  The channel owns nothing durable. `join/3` admits the Worker through
  `WorkerAdmission` from the ready fields in the join payload, registers its
  `connection_id` (the transport route) in `WorkerTracker`, and then moves
  protobuf envelopes between the socket and the inbound dispatcher. Lifecycle
  writes run in this process. Actor and RPC operations run in supervised tasks. When the
  control plane closes the connection (`{:close_connection, reason}`), the
  channel disconnects the socket, so a live Worker connects again and proves
  its credential again.

  Three logical streams share the socket. Each has its own in-flight budget
  (messages and bytes) so telemetry cannot starve durable turn traffic. Every
  envelope carries its stream and a per-stream `transport_seq` that increases
  by one per accepted message; a rejected message does not advance the
  sequence, so the Worker repeats it with the same number. Every reply
  carries the cumulative acknowledged sequence and the remaining message and
  byte credit of that stream. An RPC request is acknowledged when its task
  starts in the bounded in-flight set. The RPC response confirms the operation's
  result and any PostgreSQL commit. Other envelopes follow the acknowledgement
  points in `RuntimeFabric.md`.

  Commands from the control plane are pushed on `command` and replies on
  `reply`, with one shared sequence per connection. The Worker acknowledges
  them cumulatively with its own remaining credit; the caller waits inside
  `WorkerRoute`.
  """

  use AnkoleWeb, :channel

  alias Ankole.RuntimeFabric
  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers.InboundDispatcher
  alias Ankole.AgentWorkers.WorkerAdmission
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.AgentWorkers.WorkerTracker

  @streams [:control, :durable, :telemetry]
  @stream_enums %{
    control: :STREAM_CONTROL,
    durable: :STREAM_DURABLE,
    telemetry: :STREAM_TELEMETRY
  }
  @telemetry_methods ["observability.spans.export"]
  @mailbox_limit 10_000
  @initial_worker_byte_credit 64 * 1024 * 1024
  @max_message_bytes 16 * 1024 * 1024

  @default_limits %{
    command_ack_timeout_ms: 10_000,
    pending_command_limit: 64,
    inflight: %{
      control: {32, 4 * 1024 * 1024},
      durable: {256, 64 * 1024 * 1024},
      telemetry: {64, 16 * 1024 * 1024}
    },
    rpc_tasks: %{durable: 64, telemetry: 16}
  }

  @impl true
  def join("worker", payload, socket) do
    with :ok <- Ankole.Repo.put_tenant_id(socket.assigns.tenant_id),
         {:ok, ready} <- ready_from_payload(payload) do
      worker_id = socket.assigns.worker_id
      connection_id = Ecto.UUID.generate()

      auth = %{
        transport_route: connection_id,
        worker_id: worker_id,
        generation: socket.assigns.worker_generation
      }

      # The route is in the directory before admission makes it current:
      # admission broadcasts to this Agent's drivers, and their first send must find
      # the route. Until the admission commits, the route fence still names
      # the previous connection, so nothing reaches this one early. A failed
      # join ends this process, and the tracker drops its entry.
      {:ok, _ref} =
        Phoenix.Tracker.track(
          WorkerTracker,
          self(),
          WorkerRoute.topic(worker_id),
          connection_id,
          WorkerRoute.directory_meta(ready.incarnation_id)
        )

      case WorkerAdmission.admit_join(ready, auth) do
        {:ok, _worker} ->
          limits = limits()

          socket =
            assign(socket, %{
              incarnation_id: ready.incarnation_id,
              connection_id: connection_id,
              limits: limits,
              streams: Map.new(@streams, &{&1, new_stream()}),
              out_seq: 0,
              pending_commands: %{},
              worker_credit: %{
                messages: limits.pending_command_limit,
                bytes: @initial_worker_byte_credit
              },
              rpc_waiters: %{},
              rpc_tasks: %{durable: MapSet.new(), telemetry: MapSet.new()}
            })

          {:ok, %{"connection_id" => connection_id}, socket}

        {:error, reason} ->
          {:error,
           %{
             "reason" => Ankole.AgentWorkers.RPCWire.error_message(reason, :tuple_inspect)
           }}
      end
    else
      {:error, reason} ->
        {:error,
         %{
           "reason" => Ankole.AgentWorkers.RPCWire.error_message(reason, :tuple_inspect)
         }}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{"reason" => "unknown_topic"}}

  @impl true
  def handle_in(_event, {:binary, bytes}, socket) when byte_size(bytes) > @max_message_bytes,
    do: {:reply, {:error, %{"reason" => "message_too_large"}}, socket}

  def handle_in(event, payload, socket) do
    case mailbox_overflow?() do
      true ->
        Logging.error(
          "runtime_fabric.channel_mailbox_overflow",
          "runtime fabric worker channel mailbox overflow",
          %{worker_id: socket.assigns.worker_id, route: socket.assigns.connection_id}
        )

        {:stop, {:shutdown, :mailbox_overflow}, socket}

      false ->
        handle_event(event, payload, socket)
    end
  end

  # The Worker acknowledges commands cumulatively and reports how much more it
  # can take. Its credit bounds the unacknowledged commands on this connection.
  defp handle_event("ack", %{"acked_seq" => acked_seq} = payload, socket)
       when is_integer(acked_seq) do
    {resolved, pending} =
      Enum.split_with(socket.assigns.pending_commands, fn {seq, _command} -> seq <= acked_seq end)

    Enum.each(resolved, fn {_seq, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:ok, :sent_or_queued})
    end)

    credit = %{
      messages: non_neg_integer(payload["message_credit"], socket.assigns.worker_credit.messages),
      bytes: non_neg_integer(payload["byte_credit"], socket.assigns.worker_credit.bytes)
    }

    {:noreply, assign(socket, %{pending_commands: Map.new(pending), worker_credit: credit})}
  end

  defp handle_event(event, {:binary, bytes}, socket)
       when event in ["control", "durable", "telemetry"] do
    stream = String.to_existing_atom(event)

    case RuntimeFabric.decode_and_validate(bytes) do
      {:ok, envelope} -> handle_envelope(stream, envelope, byte_size(bytes), socket)
      {:error, _reason} -> {:reply, {:error, %{"reason" => "invalid_envelope"}}, socket}
    end
  end

  defp handle_event(_event, _payload, socket) do
    {:reply, {:error, %{"reason" => "unknown_event"}}, socket}
  end

  defp handle_envelope(stream, envelope, bytes, socket) do
    state = Map.fetch!(socket.assigns.streams, stream)

    cond do
      envelope.stream != Map.fetch!(@stream_enums, stream) or envelope_stream(envelope) != stream ->
        {:reply, {:error, rejection(socket, stream, "wrong_stream")}, socket}

      envelope.transport_seq != state.next_seq ->
        {:reply,
         {:error, Map.put(rejection(socket, stream, "bad_sequence"), "expected", state.next_seq)},
         socket}

      rpc_reply?(envelope) ->
        socket =
          socket
          |> accept(stream, envelope.transport_seq, 0, envelope)
          |> complete(stream, envelope.transport_seq, 0)
          |> resolve_rpc_reply(envelope)

        {:reply, {:ok, credit_map(socket, stream)}, socket}

      not inflight_available?(socket, stream, bytes) ->
        {:reply, {:error, rejection(socket, stream, "flow_control")}, socket}

      true ->
        socket = accept(socket, stream, envelope.transport_seq, bytes, envelope)

        reply_to = %{
          ref: socket_ref(socket),
          channel: self(),
          stream: stream,
          seq: envelope.transport_seq,
          bytes: bytes
        }

        InboundDispatcher.dispatch(
          {:ok, socket.assigns.connection_id, envelope},
          auth(socket),
          reply_to
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_call({:deliver, %FabricProto.Envelope{} = envelope}, from, socket) do
    %{pending_commands: pending, limits: limits, worker_credit: credit} = socket.assigns
    pending_bytes = pending |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum()
    message_budget = min(limits.pending_command_limit, credit.messages)

    with true <- map_size(pending) < message_budget || {:error, :backpressure},
         {bytes, seq} = seal_sequenced(socket, envelope),
         true <-
           (pending == %{} or pending_bytes + byte_size(bytes) <= credit.bytes) ||
             {:error, :backpressure} do
      push(socket, "command", {:binary, bytes})

      timer =
        Process.send_after(self(), {:command_ack_timeout, seq}, limits.command_ack_timeout_ms)

      pending = Map.put(pending, seq, %{from: from, timer: timer, bytes: byte_size(bytes)})
      {:noreply, assign(socket, %{pending_commands: pending, out_seq: seq})}
    else
      {:error, reason} -> {:reply, {:error, reason}, socket}
    end
  end

  def handle_call({:push, %FabricProto.Envelope{} = envelope}, _from, socket) do
    socket = push_sequenced(socket, "reply", envelope)
    {:reply, {:ok, :sent_or_queued}, release_rpc_task(socket, envelope)}
  end

  def handle_call({:request_rpc, %FabricProto.Envelope{} = envelope, timeout_ms}, from, socket) do
    {:rpc_request, request} = envelope.body
    socket = push_sequenced(socket, "command", envelope)
    timer = Process.send_after(self(), {:rpc_request_timeout, request.request_id}, timeout_ms)
    waiters = Map.put(socket.assigns.rpc_waiters, request.request_id, %{from: from, timer: timer})
    {:noreply, assign(socket, :rpc_waiters, waiters)}
  end

  @impl true
  def handle_info({:reply_done, ref, stream, seq, bytes, result}, socket) do
    socket = complete(socket, stream, seq, bytes)
    Phoenix.Channel.reply(ref, wire_result(result, credit_map(socket, stream)))
    {:noreply, socket}
  end

  def handle_info({:command_ack_timeout, seq}, socket) do
    case Map.pop(socket.assigns.pending_commands, seq) do
      {nil, _pending} ->
        {:noreply, socket}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, assign(socket, :pending_commands, pending)}
    end
  end

  def handle_info({:close_connection, reason}, socket) do
    send(socket.transport_pid, %Phoenix.Socket.Broadcast{
      topic: socket.id,
      event: "disconnect",
      payload: %{}
    })

    {:stop, {:shutdown, reason}, socket}
  end

  def handle_info({:rpc_request_timeout, request_id}, socket) do
    case Map.pop(socket.assigns.rpc_waiters, request_id) do
      {nil, _waiters} ->
        {:noreply, socket}

      {%{from: from}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, assign(socket, :rpc_waiters, waiters)}
    end
  end

  @impl true
  def terminate(_reason, %{assigns: assigns} = _socket) do
    Enum.each(Map.get(assigns, :pending_commands, %{}), fn {_seq, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :socket_closed})
    end)

    Enum.each(Map.get(assigns, :rpc_waiters, %{}), fn {_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :socket_closed})
    end)

    if connection_id = Map.get(assigns, :connection_id) do
      _ =
        Phoenix.Tracker.untrack(
          WorkerTracker,
          self(),
          WorkerRoute.topic(assigns.worker_id),
          connection_id
        )

      # Only the worker whose current route is this connection becomes stale;
      # a connection replaced by a reconnect no longer owns any fence.
      _ = WorkerAdmission.mark_route_unusable(connection_id, :socket_closed)
    end

    :ok
  end

  defp new_stream do
    %{next_seq: 1, acked_seq: 0, completed: MapSet.new(), count: 0, bytes: 0}
  end

  # Accepting a message consumes its sequence number and its in-flight budget.
  defp accept(socket, stream, seq, bytes, envelope) do
    socket =
      update_stream(socket, stream, fn state ->
        %{state | next_seq: seq + 1, count: state.count + 1, bytes: state.bytes + bytes}
      end)

    case envelope.body do
      {:rpc_request, request} when stream in [:durable, :telemetry] ->
        tasks = Map.update!(socket.assigns.rpc_tasks, stream, &MapSet.put(&1, request.request_id))
        assign(socket, :rpc_tasks, tasks)

      _body ->
        socket
    end
  end

  # Completion returns the budget and advances the cumulative acknowledgement
  # over every completed sequence with no gap below it.
  defp complete(socket, stream, seq, bytes) do
    update_stream(socket, stream, fn state ->
      completed = MapSet.put(state.completed, seq)
      {acked_seq, completed} = advance_acked(state.acked_seq, completed)

      %{
        state
        | acked_seq: acked_seq,
          completed: completed,
          count: max(state.count - 1, 0),
          bytes: max(state.bytes - bytes, 0)
      }
    end)
  end

  defp advance_acked(acked_seq, completed) do
    if MapSet.member?(completed, acked_seq + 1),
      do: advance_acked(acked_seq + 1, MapSet.delete(completed, acked_seq + 1)),
      else: {acked_seq, completed}
  end

  defp update_stream(socket, stream, fun) do
    assign(socket, :streams, Map.update!(socket.assigns.streams, stream, fun))
  end

  defp credit_map(socket, stream) do
    state = Map.fetch!(socket.assigns.streams, stream)
    {max_count, max_bytes} = Map.fetch!(socket.assigns.limits.inflight, stream)

    message_credit =
      [max_count - state.count, rpc_task_credit(socket, stream)]
      |> Enum.min()
      |> max(0)

    %{
      "stream" => Atom.to_string(stream),
      "acked_seq" => state.acked_seq,
      "message_credit" => message_credit,
      "byte_credit" => max(max_bytes - state.bytes, 0)
    }
  end

  defp rejection(socket, stream, reason) do
    Map.put(credit_map(socket, stream), "reason", reason)
  end

  defp wire_result(:ok, credits), do: {:ok, credits}
  defp wire_result({:ok, _value}, credits), do: {:ok, credits}

  defp wire_result({:error, reason}, credits),
    do:
      {:error,
       Map.put(
         credits,
         "reason",
         Ankole.AgentWorkers.RPCWire.error_message(reason, :tuple_inspect)
       )}

  defp wire_result(_other, credits), do: {:ok, credits}

  defp inflight_available?(socket, stream, bytes) do
    state = Map.fetch!(socket.assigns.streams, stream)
    {max_count, max_bytes} = Map.fetch!(socket.assigns.limits.inflight, stream)

    state.count < max_count and state.bytes + bytes <= max_bytes and
      rpc_task_credit(socket, stream) > 0
  end

  defp rpc_task_credit(socket, stream) when stream in [:durable, :telemetry] do
    Map.fetch!(socket.assigns.limits.rpc_tasks, stream) -
      MapSet.size(Map.fetch!(socket.assigns.rpc_tasks, stream))
  end

  defp rpc_task_credit(socket, :control),
    do: elem(Map.fetch!(socket.assigns.limits.inflight, :control), 0)

  # Commands and replies share one sequence so the Worker's cumulative
  # acknowledgement covers everything it took in order.
  defp push_sequenced(socket, event, envelope) do
    {bytes, seq} = seal_sequenced(socket, envelope)
    push(socket, event, {:binary, bytes})
    assign(socket, :out_seq, seq)
  end

  defp seal_sequenced(socket, envelope) do
    seq = socket.assigns.out_seq + 1

    bytes =
      RuntimeFabric.seal_and_encode(%{envelope | stream: :STREAM_DURABLE, transport_seq: seq})

    {bytes, seq}
  end

  defp envelope_stream(%FabricProto.Envelope{body: {type, payload}}) do
    case type do
      type when type in [:worker_heartbeat, :control_shutdown] ->
        :control

      :rpc_request ->
        if payload.method in @telemetry_methods, do: :telemetry, else: :durable

      _type ->
        :durable
    end
  end

  defp rpc_reply?(%FabricProto.Envelope{body: {type, _payload}}),
    do: type in [:rpc_response, :rpc_error]

  defp resolve_rpc_reply(socket, %FabricProto.Envelope{body: {type, reply}}) do
    result =
      case type do
        :rpc_response -> {:ok, reply.payload}
        :rpc_error -> {:error, WorkerRoute.rpc_error_payload(reply)}
      end

    case Map.pop(socket.assigns.rpc_waiters, reply.request_id) do
      {nil, _waiters} ->
        Logging.debug(
          "runtime_fabric.rpc_reply_without_waiter",
          "runtime fabric rpc reply without waiter",
          %{request_id: reply.request_id, route: socket.assigns.connection_id}
        )

        socket

      {%{from: from, timer: timer}, waiters} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result)
        assign(socket, :rpc_waiters, waiters)
    end
  end

  # An RPC answer pushed back through this connection closes the Worker's
  # in-flight request slot.
  defp release_rpc_task(socket, %FabricProto.Envelope{body: {type, reply}})
       when type in [:rpc_response, :rpc_error] do
    tasks =
      Map.new(socket.assigns.rpc_tasks, fn {stream, ids} ->
        {stream, MapSet.delete(ids, reply.request_id)}
      end)

    assign(socket, :rpc_tasks, tasks)
  end

  defp release_rpc_task(socket, _envelope), do: socket

  defp auth(socket) do
    %{transport_route: socket.assigns.connection_id, worker_id: socket.assigns.worker_id}
  end

  defp mailbox_overflow? do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, length} -> length > @mailbox_limit
      nil -> false
    end
  end

  defp ready_from_payload(payload) when is_map(payload) do
    with {:ok, incarnation_id} <- required_text(payload, "incarnation_id"),
         {:ok, max_slots} <- required_integer(payload, "max_slots"),
         true <- max_slots > 0 || {:error, "max_slots_must_be_positive"},
         {:ok, available_slots} <- required_integer(payload, "available_slots"),
         true <- available_slots <= max_slots || {:error, "available_slots_exceeds_max_slots"} do
      {:ok,
       %{incarnation_id: incarnation_id, max_slots: max_slots, available_slots: available_slots}}
    end
  end

  defp ready_from_payload(_payload), do: {:error, "worker_join_required"}

  defp required_text(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, "#{key}_required"}
    end
  end

  defp required_integer(payload, key) do
    case Map.get(payload, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, "#{key}_required"}
    end
  end

  defp non_neg_integer(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp non_neg_integer(_value, fallback), do: fallback

  defp limits do
    configured = Application.get_env(:ankole, __MODULE__, [])

    %{
      command_ack_timeout_ms:
        Keyword.get(configured, :command_ack_timeout_ms, @default_limits.command_ack_timeout_ms),
      pending_command_limit:
        Keyword.get(configured, :pending_command_limit, @default_limits.pending_command_limit),
      inflight:
        Map.merge(@default_limits.inflight, Map.new(Keyword.get(configured, :inflight, []))),
      rpc_tasks:
        Map.merge(@default_limits.rpc_tasks, Map.new(Keyword.get(configured, :rpc_tasks, [])))
    }
  end
end
