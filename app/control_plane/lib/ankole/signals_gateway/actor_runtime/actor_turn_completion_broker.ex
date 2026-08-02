defmodule Ankole.SignalsGateway.ActorRuntime.ActorTurnCompletionBroker do
  @moduledoc """
  Adapts the typed RuntimeFabric completion RPC to the durable turn commit.

  The RPC response is the worker's commit acknowledgement. A repeated request
  reaches the same idempotent completion anchor after live delivery fences are
  cleared, so response loss cannot cause a second model turn.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorTurnCompletion

  @spec handle_complete(TurnRef.t(), FabricProto.ActorTurnCompleteRequest.t(), map()) ::
          {:ok, FabricProto.ActorTurnCompleteResponse.t()} | {:error, map()}
  def handle_complete(
        %TurnRef{} = turn_ref,
        %FabricProto.ActorTurnCompleteRequest{} = request,
        ctx
      ) do
    case ActorTurnCompletion.handle(
           turn_ref,
           request.final_response_id,
           request.outcome,
           []
         ) do
      {:ok, result} ->
        {:ok,
         %FabricProto.ActorTurnCompleteResponse{
           status: Atom.to_string(result.status),
           final_response_id: request.final_response_id,
           outcome: request.outcome
         }}

      {:error, reason} ->
        {:error,
         RPCWire.error_payload(ctx.request_id, reason,
           fallback_code: "actor_turn_completion_failed",
           message_style: :tuple_inspect,
           details_json: %{}
         )}
    end
  end
end
