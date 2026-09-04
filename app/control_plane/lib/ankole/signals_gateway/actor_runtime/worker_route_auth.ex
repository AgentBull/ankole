defmodule Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
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
             {:error, _reason} -> authorize_terminal_retry_in_tx(repo, turn_ref, route)
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
    rows = TurnRef.lookup(repo, turn_ref, route: route, lock: Keyword.get(opts, :lock, false))

    with :ok <- TurnRef.match(rows, turn_ref, route_mode(effect)) do
      {:ok, :authorized}
    end
  end

  def authorize_turn_route_in_tx(_repo, _turn_ref, _route, _effect, _opts),
    do: {:error, :invalid_turn_ref}

  defp route_mode(:read), do: :route_read
  defp route_mode(:write), do: :route_write

  # A terminal RPC can repeat after its commit already happened. The activation
  # keeps the static fence and may hold a newer revision than the worker's; the
  # terminal record proves which end the turn reached.
  defp authorize_terminal_retry_in_tx(repo, turn_ref, route) do
    rows = TurnRef.lookup(repo, turn_ref, route: route, lock: false)

    with :ok <- TurnRef.match(rows, turn_ref, :terminal_retry),
         true <- terminal_record?(repo, rows.activation, turn_ref) do
      {:ok, :authorized}
    else
      _missing -> {:error, :worker_not_assigned_to_turn}
    end
  end

  defp terminal_record?(repo, %ActorSessionActivation{status: "failed"}, turn_ref),
    do: TurnLifecycle.aborted_delivery_exists_in_tx(repo, turn_ref)

  defp terminal_record?(repo, %ActorSessionActivation{}, turn_ref) do
    ActorEvent
    |> where([event], event.id == ^turn_ref.actor_event_id)
    |> where([event], event.agent_uid == ^turn_ref.agent_uid)
    |> where([event], event.session_id == ^turn_ref.session_id)
    |> where([event], not is_nil(event.completed_at))
    |> repo.exists?()
  end
end
