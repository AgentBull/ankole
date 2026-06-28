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
  repaired by `reconcile_projection_lost_started_turns/1`.
  """

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.CommitCoordinator
  alias Ankole.ActorRuntime.FileTransferLane
  alias Ankole.ActorRuntime.ReadyInputProcessor
  alias Ankole.ActorRuntime.Recovery
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.SessionReset
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.ActorRuntime.WorkerPool

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Delegates active-conversation creation to the AI-agent context.
  """
  @spec ensure_conversation(String.t(), String.t()) :: {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation(agent_uid, session_id),
    do: AIAgent.ensure_conversation(agent_uid, session_id)

  @doc """
  Admits an authenticated worker-ready message.
  """
  @spec admit_worker_ready(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate admit_worker_ready(worker_ready, authenticated_route), to: WorkerAdmission

  @doc """
  Records a worker-ready projection.
  """
  @spec record_worker_ready(map(), String.t() | nil) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate record_worker_ready(attrs, route \\ nil), to: WorkerAdmission

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
  Calls one semantic RPC method on a worker route.
  """
  @spec request_worker_rpc(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def request_worker_rpc(transport_route, method, payload \\ %{}, opts \\ [])
      when is_binary(transport_route) and is_binary(method) and is_map(payload) do
    Broker.request_rpc(transport_route, method, payload, opts)
  end

  @doc """
  Starts a worker-backed LLM turn for a ready actor input set.
  """
  @spec start_llm_turn(actor_key(), [ActorInput.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate start_llm_turn(actor_key, actor_inputs, opts \\ []), to: TurnLifecycle

  @doc """
  Creates a delivery attempt for one actor input.
  """
  @spec create_input_delivery(Ecto.UUID.t(), map(), String.t() | nil) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  defdelegate create_input_delivery(actor_input_id, turn_ref, route), to: TurnLifecycle

  @doc """
  Marks a delivery sent.
  """
  @spec mark_delivery_sent(Ecto.UUID.t(), String.t() | atom()) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  defdelegate mark_delivery_sent(delivery_id, send_outcome \\ "sent_or_queued"),
    to: TurnLifecycle

  @doc """
  Marks a delivery accepted by a matching worker turn.accepted message.
  """
  @spec mark_delivery_accepted(Ecto.UUID.t(), map()) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  defdelegate mark_delivery_accepted(delivery_id, turn_ref), to: TurnLifecycle

  @doc """
  Marks a delivery transport failure.
  """
  @spec mark_delivery_failed(Ecto.UUID.t(), String.t() | atom(), term()) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  defdelegate mark_delivery_failed(delivery_id, send_outcome, reason), to: TurnLifecycle

  @doc """
  Handles an actor lane turn.accepted envelope.
  """
  @spec handle_turn_accepted(map()) :: {:ok, [ActorInputDelivery.t()]} | {:error, term()}
  defdelegate handle_turn_accepted(envelope), to: TurnLifecycle

  @doc """
  Extends the live activation lease for a matching in-flight worker turn.
  """
  @spec handle_worker_progress(map(), keyword()) ::
          {:ok, ActorSessionActivation.t()} | {:error, term()}
  defdelegate handle_worker_progress(envelope, opts \\ []), to: TurnLifecycle

  @doc """
  Handles a final proposal envelope or body and commits it durably.
  """
  @spec commit_final_proposal(map()) :: {:ok, map()} | {:error, term()}
  defdelegate commit_final_proposal(proposal), to: CommitCoordinator

  @doc """
  Handles a worker turn.error envelope and releases the actor input for retry.
  """
  @spec handle_turn_error(map()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_turn_error(envelope), to: CommitCoordinator

  @doc """
  Marks a turn failed.
  """
  @spec mark_turn_failed(Ecto.UUID.t(), term()) :: {:ok, LlmTurn.t()} | {:error, term()}
  def mark_turn_failed(llm_turn_id, reason), do: AIAgent.mark_turn_failed(llm_turn_id, reason)

  @doc """
  Fails started turns whose unlogged activation/delivery fence was lost.
  """
  @spec reconcile_projection_lost_started_turns(keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defdelegate reconcile_projection_lost_started_turns(opts \\ []), to: Recovery

  @doc """
  Starts one ready actor if a worker is available.
  """
  @spec process_ready_inputs_once(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate process_ready_inputs_once(opts \\ []), to: ReadyInputProcessor

  @doc """
  Starts ready actors up to the requested limit.
  """
  @spec process_ready_inputs(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate process_ready_inputs(opts \\ []), to: ReadyInputProcessor

  @doc """
  Enqueues daily reset barrier inputs for sessions due at the latest local 04:30.
  """
  @spec enqueue_daily_session_resets(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate enqueue_daily_session_resets(opts \\ []), to: SessionReset

  @spec enqueue_daily_session_resets(DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate enqueue_daily_session_resets(boundary_at, opts), to: SessionReset

  @doc """
  Starts one ready input for an actor key.
  """
  @spec process_ready_inputs_for_actor(actor_key(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate process_ready_inputs_for_actor(actor_key, opts \\ []), to: ReadyInputProcessor

  @doc """
  Runs one actor-runtime watchdog pass.
  """
  @spec watchdog_once(keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate watchdog_once(opts \\ []), to: Recovery
end
