defmodule Ankole.SignalsGateway.ActorRuntime.ActorTurnCompletionBroker do
  @moduledoc """
  Adapts the typed RuntimeFabric completion RPC to the durable turn commit.

  The RPC response is the worker's commit acknowledgement. A repeated request
  reaches the same idempotent completion anchor after live delivery fences are
  cleared, so response loss cannot cause a second model turn.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorTurnCompletion

  @spec handle_noop(TurnRef.t(), FabricProto.ActorTurnNoopRequest.t(), map()) ::
          {:ok, FabricProto.ActorTurnNoopResponse.t()} | {:error, map()}
  def handle_noop(%TurnRef{} = turn_ref, %FabricProto.ActorTurnNoopRequest{} = request, ctx) do
    payload = %FabricProto.TurnNoopCompleted{
      turn: TurnRef.to_proto(turn_ref),
      reason: request.reason
    }

    case ActorRuntime.handle_turn_noop_completed(payload) do
      {:ok, result} ->
        {:ok,
         %FabricProto.ActorTurnNoopResponse{
           status: Atom.to_string(result.status),
           reason: result.reason
         }}

      {:error, reason} ->
        {:error, terminal_error(ctx, reason, "actor_turn_noop_failed")}
    end
  end

  @spec handle_abort(TurnRef.t(), FabricProto.ActorTurnAbortRequest.t(), map()) ::
          {:ok, FabricProto.ActorTurnAbortResponse.t()} | {:error, map()}
  def handle_abort(%TurnRef{} = turn_ref, %FabricProto.ActorTurnAbortRequest{} = request, ctx) do
    payload = %FabricProto.TurnError{
      turn: TurnRef.to_proto(turn_ref),
      code: request.code,
      message: request.message,
      details_json: request.details_json
    }

    case ActorRuntime.handle_turn_error(payload) do
      {:ok, result} ->
        {:ok,
         %FabricProto.ActorTurnAbortResponse{
           status: Atom.to_string(result.status),
           dead_lettered: result.dead_lettered?,
           retry_available_at: encode_datetime(result.retry_available_at)
         }}

      {:error, reason} ->
        {:error, terminal_error(ctx, reason, "actor_turn_abort_failed")}
    end
  end

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
        {:error, terminal_error(ctx, reason, "actor_turn_completion_failed")}
    end
  end

  defp terminal_error(ctx, reason, fallback_code) do
    RPCWire.error_payload(ctx.request_id, reason,
      fallback_code: fallback_code,
      message_style: :tuple_inspect,
      details_json: %{}
    )
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_datetime), do: ""
end
