defmodule Ankole.ActorRuntime do
  @moduledoc """
  Control-plane API for the Actor Runtime PING/PONG main path.

  This is the durable turn/commit/fence core. It owns the boundary between two
  layers with deliberately different guarantees:

    * AI-agent state (conversations, turns, messages) is *durable truth*.
    * Actor-runtime projections (activations, deliveries, assignments) are
      cheaper *runtime hints* that fence in-flight work and can be rebuilt.

  Every worker reply must echo a `turn_ref` whose fields are checked by equality
  against database rows (the "triple fence": activation, actor epoch, and the
  delivery rows that name a turn). This makes a late or cross-session worker
  reply fail harmlessly instead of corrupting the durable transcript, and it
  needs no in-memory session state to do so. The one intentionally weak spot —
  a durable started turn whose runtime fences were lost on a restart — is
  repaired by the exact runtime event handler for the affected message row.
  """

  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.FileTransferLane
  alias Ankole.ActorRuntime.ReadyEventProcessor
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.SessionReset
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.ActorRuntime.WorkerPool

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Lists worker registry rows for operator-facing views.
  """
  @spec list_workers() :: [AgentComputerWorker.t()]
  defdelegate list_workers(), to: WorkerAdmission

  @doc """
  Admits an authenticated worker-ready message.
  """
  @spec admit_worker_ready(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate admit_worker_ready(worker_ready, authenticated_route), to: WorkerAdmission

  @doc """
  Records an authenticated worker heartbeat projection.
  """
  @spec handle_worker_heartbeat(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate handle_worker_heartbeat(worker_heartbeat, authenticated_route), to: WorkerAdmission

  @doc """
  Records an authenticated worker capacity projection.
  """
  @spec handle_worker_capacity(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate handle_worker_capacity(worker_capacity, authenticated_route), to: WorkerAdmission

  @doc """
  Assigns a ready worker to one actor key.
  """
  @spec assign_worker(actor_key()) ::
          {:ok, ActorSessionWorkerAssignment.t()} | {:error, term()}
  defdelegate assign_worker(actor_key), to: WorkerPool

  @doc """
  Writes bytes into a worker-owned filesystem root through RuntimeFabric.
  """
  @spec put_worker_file(String.t(), String.t(), iodata(), keyword()) ::
          FileTransferLane.operation_result()
  def put_worker_file(root, relative_path, content, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.file_worker_route() do
      FileTransferLane.put(route, root, relative_path, content, opts)
    end
  end

  @doc """
  Reads bytes from a worker-owned filesystem root through RuntimeFabric.
  """
  @spec get_worker_file(String.t(), String.t(), keyword()) :: FileTransferLane.get_result()
  def get_worker_file(root, relative_path, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.file_worker_route() do
      FileTransferLane.get(route, root, relative_path, opts)
    end
  end

  @doc """
  Lists a directory inside a specific worker's filesystem root.

  Targets the exact worker because each worker owns its own per-worker PVC.
  """
  @spec list_files_on_worker(String.t(), String.t(), String.t(), keyword()) ::
          FileTransferLane.operation_result()
  def list_files_on_worker(worker_id, root, relative_path, opts \\ [])
      when is_binary(worker_id) and is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.worker_file_route(worker_id) do
      FileTransferLane.list(route, root, relative_path, opts)
    end
  end

  @doc """
  Reads filesystem information for one path on a specific worker.
  """
  @spec stat_file_on_worker(String.t(), String.t(), String.t(), keyword()) ::
          FileTransferLane.operation_result()
  def stat_file_on_worker(worker_id, root, relative_path, opts \\ [])
      when is_binary(worker_id) and is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.worker_file_route(worker_id) do
      FileTransferLane.stat(route, root, relative_path, opts)
    end
  end

  @doc """
  Reads bytes from a specific worker's filesystem root.
  """
  @spec get_file_from_worker(String.t(), String.t(), String.t(), keyword()) ::
          FileTransferLane.get_result()
  def get_file_from_worker(worker_id, root, relative_path, opts \\ [])
      when is_binary(worker_id) and is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.worker_file_route(worker_id) do
      FileTransferLane.get(route, root, relative_path, opts)
    end
  end

  @doc """
  Writes bytes into a specific worker's filesystem root.
  """
  @spec put_file_on_worker(String.t(), String.t(), String.t(), iodata(), keyword()) ::
          FileTransferLane.operation_result()
  def put_file_on_worker(worker_id, root, relative_path, content, opts \\ [])
      when is_binary(worker_id) and is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.worker_file_route(worker_id) do
      FileTransferLane.put(route, root, relative_path, content, opts)
    end
  end

  @doc """
  Deletes a file or directory on a specific worker.
  """
  @spec delete_file_on_worker(String.t(), String.t(), String.t(), keyword()) ::
          FileTransferLane.operation_result()
  def delete_file_on_worker(worker_id, root, relative_path, opts \\ [])
      when is_binary(worker_id) and is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.worker_file_route(worker_id) do
      FileTransferLane.delete(route, root, relative_path, opts)
    end
  end

  @doc """
  Moves or renames a path on a specific worker.
  """
  @spec move_file_on_worker(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          FileTransferLane.operation_result()
  def move_file_on_worker(worker_id, root, from_relative_path, to_relative_path, opts \\ [])
      when is_binary(worker_id) and is_binary(root) and is_binary(from_relative_path) and
             is_binary(to_relative_path) do
    with {:ok, route} <- WorkerPool.worker_file_route(worker_id) do
      FileTransferLane.move(route, root, from_relative_path, to_relative_path, opts)
    end
  end

  @doc """
  Starts a worker-backed turn for a ready actor event.
  """
  @spec start_worker_turn(actor_key(), ActorEvent.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate start_worker_turn(actor_key, actor_event, opts \\ []), to: TurnLifecycle

  @doc """
  Marks a delivery sent.
  """
  @spec mark_delivery_sent(Ecto.UUID.t(), String.t() | atom()) ::
          {:ok, ActorEventDelivery.t()} | {:error, term()}
  defdelegate mark_delivery_sent(delivery_id, send_outcome \\ "sent_or_queued"),
    to: TurnLifecycle

  @doc """
  Marks a delivery transport failure.
  """
  @spec mark_delivery_failed(Ecto.UUID.t(), String.t() | atom(), term()) ::
          {:ok, ActorEventDelivery.t()} | {:error, term()}
  defdelegate mark_delivery_failed(delivery_id, send_outcome, reason), to: TurnLifecycle

  @doc """
  Handles an actor lane turn.accepted envelope.
  """
  @spec handle_turn_accepted(map()) :: {:ok, [ActorEventDelivery.t()]} | {:error, term()}
  defdelegate handle_turn_accepted(envelope), to: TurnLifecycle

  @doc """
  Extends the live activation lease for a matching in-flight worker turn.
  """
  @spec handle_worker_progress(map(), keyword()) ::
          {:ok, ActorSessionActivation.t()} | {:error, term()}
  defdelegate handle_worker_progress(envelope, opts \\ []), to: TurnLifecycle

  @doc """
  Completes a worker turn that deliberately produced no AIGateway response.
  """
  @spec handle_turn_noop_completed(map()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_turn_noop_completed(envelope), to: TurnLifecycle

  @doc """
  Handles a worker turn.error envelope and releases the actor event for retry.
  """
  @spec handle_turn_error(map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_turn_error(envelope, opts \\ []), to: TurnLifecycle

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    Ankole.Actors.runtime_event_snapshot() ++
      WorkerAdmission.runtime_event_snapshot() ++
      TurnLifecycle.runtime_event_snapshot()
  end

  @doc false
  @spec mark_worker_stale_if_due(String.t(), keyword()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate mark_worker_stale_if_due(worker_id, opts \\ []), to: WorkerAdmission

  @doc false
  @spec delete_worker_if_due(String.t(), keyword()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate delete_worker_if_due(worker_id, opts \\ []), to: WorkerAdmission

  @doc false
  @spec fail_activation_if_expired(String.t(), keyword()) ::
          {:ok, ActorSessionActivation.t()} | {:error, term()}
  defdelegate fail_activation_if_expired(activation_uid, opts \\ []), to: TurnLifecycle

  @doc false
  @spec reconcile_projection_lost_started_turn(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate reconcile_projection_lost_started_turn(message_id, opts \\ []), to: TurnLifecycle

  @doc """
  Enqueues daily reset barrier inputs for sessions due at the latest local 04:30.
  """
  @spec enqueue_daily_session_resets(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate enqueue_daily_session_resets(opts \\ []), to: SessionReset

  @spec enqueue_daily_session_resets(DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate enqueue_daily_session_resets(boundary_at, opts), to: SessionReset

  @doc """
  Starts one ready event for an actor key.
  """
  @spec process_ready_event_for_actor(actor_key(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate process_ready_event_for_actor(actor_key, opts \\ []), to: ReadyEventProcessor
end
