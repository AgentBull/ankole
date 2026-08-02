defmodule Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo

  @type effect :: :read | :write

  @spec authorize_turn_route(TurnRef.t(), String.t(), effect()) :: :ok | {:error, atom()}
  def authorize_turn_route(%TurnRef{} = turn_ref, route, effect)
      when is_binary(route) and effect in [:read, :write] do
    case Repo.transact(fn repo ->
           authorize_turn_route_in_tx(repo, turn_ref, route, effect)
         end) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def authorize_turn_route(_turn, _route, _effect), do: {:error, :invalid_turn_ref}

  @spec authorize_turn_completion_route(TurnRef.t(), String.t()) :: :ok | {:error, atom()}
  def authorize_turn_completion_route(%TurnRef{} = turn_ref, route) when is_binary(route) do
    case Repo.transact(fn repo ->
           case authorize_turn_route_in_tx(repo, turn_ref, route, :write) do
             {:ok, :authorized} = authorized -> authorized
             {:error, _reason} -> authorize_completed_turn_retry_in_tx(repo, turn_ref, route)
           end
         end) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def authorize_turn_completion_route(_turn, _route), do: {:error, :invalid_turn_ref}

  @doc false
  @spec authorize_turn_route_in_tx(module(), TurnRef.t(), String.t(), effect(), keyword()) ::
          {:ok, :authorized} | {:error, atom()}
  def authorize_turn_route_in_tx(repo, turn_ref, route, effect, opts \\ [])

  def authorize_turn_route_in_tx(repo, %TurnRef{} = turn_ref, route, effect, opts)
      when is_binary(route) and effect in [:read, :write] and is_list(opts) do
    lock? = Keyword.get(opts, :lock, false)

    with %AgentComputerWorker{} = worker <- worker_by_route(repo, route, lock?),
         %ActorSessionActivation{} = activation <-
           live_activation(repo, turn_ref, worker, lock?),
         %ActorSessionWorkerAssignment{} <- live_assignment(repo, turn_ref, worker, lock?),
         :ok <- authorize_revision(activation, turn_ref, effect) do
      {:ok, :authorized}
    else
      nil -> {:error, :worker_not_assigned_to_turn}
      {:error, _reason} = error -> error
    end
  end

  def authorize_turn_route_in_tx(_repo, _turn_ref, _route, _effect, _opts),
    do: {:error, :invalid_turn_ref}

  defp worker_by_route(repo, route, lock?) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> where([worker], worker.status in ["ready", "draining"])
    |> maybe_lock(lock?)
    |> repo.one()
  end

  defp live_assignment(
         repo,
         %TurnRef{} = turn_ref,
         %AgentComputerWorker{} = worker,
         lock?
       ) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^turn_ref.agent_uid)
    |> where([assignment], assignment.session_id == ^turn_ref.session_id)
    |> where([assignment], assignment.worker_id == ^worker.worker_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> maybe_lock(lock?)
    |> repo.one()
  end

  defp live_activation(repo, turn_ref, %AgentComputerWorker{} = worker, lock?) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^turn_ref.agent_uid)
    |> where([activation], activation.session_id == ^turn_ref.session_id)
    |> where([activation], activation.activation_uid == ^turn_ref.activation_uid)
    |> where([activation], activation.actor_epoch == ^turn_ref.actor_epoch)
    |> where([activation], activation.current_actor_event_id == ^turn_ref.actor_event_id)
    |> where([activation], activation.assigned_worker_id == ^worker.worker_id)
    |> where([activation], activation.status in ["starting", "active", "draining"])
    |> maybe_lock(lock?)
    |> repo.one()
  end

  defp authorize_completed_turn_retry_in_tx(repo, turn_ref, route) do
    with %AgentComputerWorker{} = worker <- worker_by_route(repo, route, false),
         %ActorSessionActivation{} <- completed_turn_activation(repo, turn_ref, worker),
         %ActorEvent{} <- completed_actor_event(repo, turn_ref) do
      {:ok, :authorized}
    else
      nil -> {:error, :worker_not_assigned_to_turn}
    end
  end

  defp completed_turn_activation(repo, turn_ref, worker) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^turn_ref.agent_uid)
    |> where([activation], activation.session_id == ^turn_ref.session_id)
    |> where([activation], activation.activation_uid == ^turn_ref.activation_uid)
    |> where([activation], activation.actor_epoch == ^turn_ref.actor_epoch)
    |> where([activation], activation.assigned_worker_id == ^worker.worker_id)
    |> where([activation], activation.revision >= ^turn_ref.revision)
    |> where([activation], activation.status in ["active", "draining"])
    |> repo.one()
  end

  defp completed_actor_event(repo, turn_ref) do
    ActorEvent
    |> where([event], event.id == ^turn_ref.actor_event_id)
    |> where([event], event.agent_uid == ^turn_ref.agent_uid)
    |> where([event], event.session_id == ^turn_ref.session_id)
    |> where([event], not is_nil(event.completed_at))
    |> repo.one()
  end

  defp maybe_lock(query, true), do: lock(query, "FOR UPDATE")
  defp maybe_lock(query, false), do: query

  defp authorize_revision(%ActorSessionActivation{}, _turn_ref, :read), do: :ok

  defp authorize_revision(
         %ActorSessionActivation{revision: activation_revision},
         %{revision: turn_revision},
         :write
       )
       when activation_revision >= turn_revision,
       do: :ok

  defp authorize_revision(%ActorSessionActivation{}, _turn_ref, :write),
    do: {:error, :stale_revision}
end
