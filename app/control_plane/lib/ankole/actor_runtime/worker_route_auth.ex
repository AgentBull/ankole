defmodule Ankole.ActorRuntime.WorkerRouteAuth do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.TurnRef
  alias Ankole.Repo

  @type effect :: :read | :write

  @spec authorize_turn_route(TurnRef.t(), String.t(), effect()) :: :ok | {:error, atom()}
  def authorize_turn_route(%TurnRef{} = turn_ref, route, effect)
      when is_binary(route) and effect in [:read, :write] do
    case Repo.transact(fn repo ->
           with %AgentComputerWorker{} = worker <- worker_by_route(repo, route),
                %ActorSessionWorkerAssignment{} <- live_assignment(repo, turn_ref, worker),
                %ActorSessionActivation{} = activation <- live_activation(repo, turn_ref, worker),
                :ok <- authorize_revision(activation, turn_ref, effect) do
             {:ok, :authorized}
           else
             nil -> {:error, :worker_not_assigned_to_turn}
             {:error, _reason} = error -> error
           end
         end) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def authorize_turn_route(_turn, _route, _effect), do: {:error, :invalid_turn_ref}

  defp worker_by_route(repo, route) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> where([worker], worker.status in ["ready", "draining"])
    |> repo.one()
  end

  defp live_assignment(repo, %TurnRef{} = turn_ref, %AgentComputerWorker{} = worker) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^turn_ref.agent_uid)
    |> where([assignment], assignment.session_id == ^turn_ref.session_id)
    |> where([assignment], assignment.worker_id == ^worker.worker_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.one()
  end

  defp live_activation(repo, turn_ref, %AgentComputerWorker{} = worker) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^turn_ref.agent_uid)
    |> where([activation], activation.session_id == ^turn_ref.session_id)
    |> where([activation], activation.activation_uid == ^turn_ref.activation_uid)
    |> where([activation], activation.actor_epoch == ^turn_ref.actor_epoch)
    |> where([activation], activation.current_actor_event_id == ^turn_ref.actor_event_id)
    |> where([activation], activation.assigned_worker_id == ^worker.worker_id)
    |> where([activation], activation.status in ["starting", "active", "draining"])
    |> repo.one()
  end

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
