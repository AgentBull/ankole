defmodule Ankole.AgentWorkers.WorkerRoute do
  @moduledoc """
  Single exit for control-plane messages to Workers.

  Workers connect over the Worker Channel. The transport route is the
  `connection_id` of one channel. The route directory is
  `Ankole.AgentWorkers.WorkerTracker`: each admitted channel
  tracks itself under the topic `worker/<worker_id>` with its
  `connection_id` as the key.

  A send follows one path:

    1. Look the route up with `Phoenix.Tracker.get_by_key/3`.
    2. Check the entry's `incarnation_id` and `connection_id` against the
       current PostgreSQL route fence; a stale entry is `:stale_route`.
    3. Call the channel process directly, on this node or over Distributed
       Erlang, and wait for the Worker's explicit acknowledgement. No PubSub
       broadcast enters the Worker command path.
    4. An empty directory, a stale entry, or a missing acknowledgement is an
       error. A lost connection marks only the Worker that still owns this route
       stale. A stale directory entry leaves its replacement unchanged.
  """

  import Ecto.Query, only: [from: 2]

  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.Common
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerAdmission
  alias Ankole.AgentWorkers.WorkerTracker

  @type target :: %{worker_id: String.t(), transport_route: String.t()} | String.t()
  @default_rpc_timeout_ms 60_000
  @deliver_timeout_ms 15_000

  @retryable_errors [:unknown_route, :socket_closed, :stale_route, :backpressure, :timeout]
  def retryable?(reason), do: reason in @retryable_errors

  @doc "Returns the tracker topic of one Worker."
  @spec topic(String.t()) :: String.t()
  def topic(worker_id), do: "worker/" <> worker_id

  @doc "Returns the metadata required to fence one admitted connection."
  @spec directory_meta(String.t()) :: map()
  def directory_meta(incarnation_id), do: %{incarnation_id: incarnation_id}

  @doc """
  Closes one connection of a Worker.

  Admission calls it when a join moves the Worker to another connection or
  its heartbeat stops. The channel process disconnects the socket, so a
  process that is still alive connects again and proves its credential.
  """
  @spec close_connection(String.t(), String.t(), term()) :: :ok
  def close_connection(worker_id, route, reason) when is_binary(worker_id) and is_binary(route) do
    WorkerTracker
    |> Phoenix.Tracker.get_by_key(topic(worker_id), route)
    |> Enum.each(fn {pid, _meta} -> send(pid, {:close_connection, reason}) end)
  end

  @doc """
  Sends one command envelope to a transport route.

  The send is mandatory from the control-plane point of view: an unknown route
  must become a scheduling signal, not a silently dropped actor turn.
  `{:ok, :sent_or_queued}` means the Worker acknowledged the command.
  """
  @spec send_mandatory(target(), FabricProto.Envelope.t()) ::
          {:ok, :sent_or_queued}
          | {:error, :unknown_route | :stale_route | :backpressure | :timeout | term()}
  def send_mandatory(target, %FabricProto.Envelope{} = envelope) do
    deliver(target, {:deliver, envelope}, @deliver_timeout_ms)
    |> tap(fn
      {:error, reason} when reason in [:unknown_route, :socket_closed] ->
        WorkerAdmission.mark_route_unusable(route_of(target), reason)

      _ ->
        :ok
    end)
  end

  defp route_of(%{transport_route: route}), do: route
  defp route_of(route) when is_binary(route), do: route

  @doc """
  Sends one reply envelope to a transport route without waiting for an acknowledgement.

  RPC responses and errors are answers to Worker requests; the Worker repeats
  a request whose answer it never sees.
  """
  @spec push(target(), FabricProto.Envelope.t()) ::
          {:ok, :sent_or_queued} | {:error, :unknown_route | :stale_route | term()}
  def push(target, %FabricProto.Envelope{} = envelope) do
    deliver(target, {:push, envelope}, @deliver_timeout_ms)
  end

  @doc """
  Sends a control-plane-originated RPC request to one worker route.

  Each call has one caller, one callee, and one `request_id`. This function
  owns the control-plane caller side and resolves when the worker sends
  `rpc_response` or `rpc_error` back on the same route.
  """
  @spec request_rpc(target(), String.t(), binary(), keyword()) ::
          {:ok, binary()} | {:error, map() | term()}
  def request_rpc(target, method, payload \\ <<>>, opts \\ [])
      when is_binary(method) and is_binary(payload) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_rpc_timeout_ms)
    request_id = request_id(opts)
    envelope = rpc_request_envelope(request_id, method, payload, timeout_ms)
    deliver(target, {:request_rpc, envelope, timeout_ms}, timeout_ms + 1_000)
  end

  @doc """
  Builds the error result shape for control-plane RPC callers.
  """
  @spec rpc_error_payload(FabricProto.RPCError.t()) :: map()
  def rpc_error_payload(%FabricProto.RPCError{} = error) do
    %{
      "request_id" => error.request_id,
      "code" => error.code,
      "message" => error.message,
      "retryable" => error.retryable,
      "details_json" => Common.decode_json_bytes(error.details_json) || %{}
    }
  end

  # The test build preserves its fixture API. No test route process, lookup,
  # or inbound shortcut is compiled into other builds.
  if Application.compile_env(:ankole, :test_worker_routes, false) do
    alias Ankole.AgentWorkers.LocalWorkerRoutes

    defdelegate register_local_worker(route, handler), to: LocalWorkerRoutes
    defdelegate unregister_local_worker(route), to: LocalWorkerRoutes

    def local_inbound(route, envelope, worker_id \\ nil),
      do: LocalWorkerRoutes.local_inbound(route, envelope, worker_id)

    defp deliver(target, request, timeout_ms),
      do: LocalWorkerRoutes.call(target, request, timeout_ms, &channel_call/3)
  else
    defp deliver(target, request, timeout_ms), do: channel_call(target, request, timeout_ms)
  end

  defp channel_call(%{worker_id: worker_id, transport_route: route}, request, timeout_ms)
       when is_binary(worker_id) and is_binary(route) do
    with {:ok, pid} <- route_member(worker_id, route) do
      try do
        GenServer.call(pid, request, timeout_ms)
      catch
        :exit, {:noproc, _call} -> {:error, :unknown_route}
        :exit, {:normal, _call} -> {:error, :unknown_route}
        :exit, {:shutdown, _call} -> {:error, :unknown_route}
        :exit, {{:shutdown, _reason}, _call} -> {:error, :unknown_route}
        :exit, {:timeout, _call} -> {:error, :timeout}
        :exit, {{:nodedown, _node}, _call} -> {:error, :unknown_route}
      end
    end
  end

  defp channel_call(_route, _request, _timeout_ms), do: {:error, :unknown_route}

  # The directory names a process; PostgreSQL decides whether that process
  # still owns the route. A directory entry that does not match the current
  # fence only fails this send and never changes durable state.
  @doc "Resolves the admitted channel process so callers can monitor its lifetime."
  @spec connection_pid(target()) :: {:ok, pid()} | {:error, term()}
  def connection_pid(%{worker_id: worker_id, transport_route: route}),
    do: route_member(worker_id, route)

  defp route_member(worker_id, route) do
    case Phoenix.Tracker.get_by_key(WorkerTracker, topic(worker_id), route) do
      [] ->
        {:error, :unknown_route}

      entries ->
        case current_fence(worker_id) do
          %{transport_route: ^route, incarnation_id: incarnation_id} ->
            entries
            |> Enum.filter(fn {_pid, meta} ->
              meta.incarnation_id == incarnation_id
            end)
            |> Enum.sort_by(fn {pid, _meta} -> node(pid) != node() end)
            |> case do
              [{pid, _meta} | _rest] -> {:ok, pid}
              [] -> {:error, :stale_route}
            end

          _fence ->
            {:error, :stale_route}
        end
    end
  end

  # The worker id of a channel route is the Agent UID: each Agent has one
  # Worker row, and only a ready or draining row has a connection.
  defp current_fence(agent_uid) do
    Repo.one(
      from(worker in AgentWorker,
        where: worker.agent_uid == ^agent_uid and worker.state in ["ready", "draining"],
        select: %{transport_route: worker.transport_route, incarnation_id: worker.incarnation_id}
      )
    )
  end

  @doc false
  @spec rpc_request_envelope(String.t(), String.t(), binary(), pos_integer()) ::
          FabricProto.Envelope.t()
  def rpc_request_envelope(request_id, method, payload, timeout_ms) do
    %FabricProto.Envelope{
      message_id: "rpc-request-#{Ecto.UUID.generate()}",
      body:
        {:rpc_request,
         %FabricProto.RPCRequest{
           request_id: request_id,
           method: method,
           deadline_unix_ms: System.system_time(:millisecond) + timeout_ms,
           payload: payload
         }}
    }
  end

  defp request_id(opts) do
    case Keyword.get(opts, :request_id) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> "rpc-#{Ecto.UUID.generate()}"
          request_id -> request_id
        end

      _value ->
        "rpc-#{Ecto.UUID.generate()}"
    end
  end
end
