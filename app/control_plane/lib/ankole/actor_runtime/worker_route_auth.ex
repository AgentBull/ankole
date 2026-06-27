defmodule Ankole.ActorRuntime.WorkerRouteAuth do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo

  @spec authorize_turn_route(map(), String.t(), :read | :write) :: :ok | {:error, atom()}
  def authorize_turn_route(turn, route, effect)
      when is_map(turn) and is_binary(route) and effect in [:read, :write] do
    with {:ok, turn_ref} <- normalize_turn_ref(turn) do
      case Repo.transact(fn repo ->
             with %AgentComputerWorker{} = worker <- worker_by_route(repo, route),
                  %ActorSessionWorkerAssignment{} <-
                    live_assignment(repo, turn_ref.agent_uid, turn_ref.session_id, worker),
                  %ActorSessionActivation{} = activation <-
                    live_activation(repo, turn_ref, worker),
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
  end

  def authorize_turn_route(_turn, _route, _effect), do: {:error, :invalid_turn_ref}

  defp worker_by_route(repo, route) do
    AgentComputerWorker
    |> where([worker], worker.transport_route == ^route)
    |> where([worker], worker.status in ["ready", "draining"])
    |> repo.one()
  end

  defp live_assignment(repo, agent_uid, session_id, %AgentComputerWorker{} = worker) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^String.downcase(agent_uid))
    |> where([assignment], assignment.session_id == ^session_id)
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
    |> where([activation], activation.current_llm_turn_id == ^turn_ref.llm_turn_id)
    |> where([activation], activation.assigned_worker_id == ^worker.worker_id)
    |> where([activation], activation.status in ["starting", "active", "draining"])
    |> repo.one()
  end

  defp authorize_revision(%ActorSessionActivation{}, _turn_ref, :read), do: :ok

  defp authorize_revision(
         %ActorSessionActivation{revision: revision},
         %{revision: revision},
         :write
       ),
       do: :ok

  defp authorize_revision(%ActorSessionActivation{}, _turn_ref, :write),
    do: {:error, :stale_revision}

  defp normalize_turn_ref(turn) do
    with %{} = actor <- map_value(turn, "actor"),
         agent_uid when is_binary(agent_uid) <- text(actor, "agent_uid"),
         session_id when is_binary(session_id) <- text(actor, "session_id"),
         activation_uid when is_binary(activation_uid) <- text(turn, "activation_uid"),
         actor_epoch when is_integer(actor_epoch) <- integer(turn, "actor_epoch"),
         llm_turn_id when is_binary(llm_turn_id) <- text(turn, "llm_turn_id"),
         revision when is_integer(revision) <- integer(turn, "revision") do
      {:ok,
       %{
         agent_uid: String.downcase(agent_uid),
         session_id: session_id,
         activation_uid: activation_uid,
         actor_epoch: actor_epoch,
         llm_turn_id: llm_turn_id,
         revision: revision
       }}
    else
      _value -> {:error, :invalid_turn_ref}
    end
  end

  defp map_value(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp integer(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> nil
    end
  end
end
