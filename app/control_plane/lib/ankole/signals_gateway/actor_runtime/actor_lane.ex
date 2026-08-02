defmodule Ankole.SignalsGateway.ActorRuntime.ActorLane do
  @moduledoc """
  Domain dispatcher for authenticated worker turn envelopes.

  Transport only decides that an envelope belongs to the actor lane. This
  module resolves its actor key, checks the worker route against the durable
  turn fence, and invokes the matching ActorRuntime transition with the
  generated payload struct.

  `turn_completed` is a rolling-deployment compatibility input. Current
  workers use the typed completion RPC, which reaches the same domain owner.
  """

  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth

  @turn_types ~w(
    turn_accepted
    worker_progress
    turn_noop_completed
    turn_completed
    turn_error
  )a

  @spec turn_type?(term()) :: boolean()
  def turn_type?(type), do: type in @turn_types

  @spec actor_key(FabricProto.Envelope.t()) ::
          {:ok, %{agent_uid: String.t(), session_id: String.t()}} | {:error, term()}
  def actor_key(%FabricProto.Envelope{body: {type, payload}}) when type in @turn_types do
    with {:ok, turn_ref} <- TurnRef.from_proto(payload.turn) do
      {:ok, TurnRef.actor_key(turn_ref)}
    end
  end

  def actor_key(_envelope), do: {:error, :missing_turn_ref}

  @spec handle(FabricProto.Envelope.t(), String.t()) :: :ok
  def handle(%FabricProto.Envelope{body: {type, payload}}, route)
      when type in @turn_types and is_binary(route) do
    payload
    |> authorize_turn(route, :write)
    |> dispatch(type)
    |> log_result(type, route)
  end

  defp authorize_turn(payload, route, effect) do
    with {:ok, turn_ref} <- TurnRef.from_proto(payload.turn),
         :ok <- WorkerRouteAuth.authorize_turn_route(turn_ref, route, effect) do
      {:ok, payload}
    end
  end

  defp dispatch({:ok, payload}, :turn_accepted),
    do: ActorRuntime.handle_turn_accepted(payload)

  defp dispatch({:ok, payload}, :worker_progress),
    do: ActorRuntime.handle_worker_progress(payload)

  defp dispatch({:ok, payload}, :turn_noop_completed),
    do: ActorRuntime.handle_turn_noop_completed(payload)

  defp dispatch({:ok, payload}, :turn_completed),
    do: ActorRuntime.handle_turn_completed(payload)

  defp dispatch({:ok, payload}, :turn_error),
    do: ActorRuntime.handle_turn_error(payload)

  defp dispatch({:error, _reason} = error, _type), do: error

  defp log_result({:ok, _result}, _type, _route), do: :ok

  defp log_result({:error, reason}, type, route) do
    Logging.warning(
      "runtime_fabric.actor_lane_handling_failed",
      "runtime fabric actor lane handling failed",
      %{
        type: type,
        route: route,
        reason: inspect(reason)
      }
    )

    :ok
  end
end
