defmodule Ankole.SignalsGateway.ActorRuntime do
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

  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.SessionReset
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.SignalsGateway.ActorTurnCompletion
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SubagentDelegations

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
  Completes a worker turn that deliberately adopts no provider-visible output.
  """
  @spec handle_turn_noop_completed(map()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_turn_noop_completed(envelope), to: TurnLifecycle

  @doc """
  Commits a response-backed Agent turn completion through SignalsGateway.
  """
  @spec handle_turn_completed(map()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_turn_completed(envelope), to: ActorTurnCompletion, as: :handle

  @doc """
  Handles a worker turn.error envelope and releases the actor event for retry.
  """
  @spec handle_turn_error(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_turn_error(envelope, opts \\ []) do
    opts =
      Keyword.put(
        opts,
        :compensate_turn_error_in_tx,
        &SubagentDelegations.compensate_turn_error_in_tx/4
      )

    result =
      envelope
      |> TurnLifecycle.handle_turn_error(opts)
      |> SubagentDelegations.finalize_turn_error()

    case result do
      {:ok, %{dead_lettered?: true, actor_event: event}} ->
        AIReplyPreview.stop(event.id)
        result

      _result ->
        result
    end
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    Ankole.SignalsGateway.Actors.runtime_event_snapshot() ++
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
