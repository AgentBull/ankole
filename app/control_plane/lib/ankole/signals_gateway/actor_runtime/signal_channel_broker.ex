defmodule Ankole.SignalsGateway.ActorRuntime.SignalChannelBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for worker-originated signal channel writes:
  ambient judgment records and standing orders.
  """

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.AmbientCuration

  @spec handle_ambient_judgment_record(
          TurnRef.t(),
          FabricProto.AmbientJudgmentRecordRequest.t(),
          map()
        ) :: {:ok, map()} | {:error, map()}
  def handle_ambient_judgment_record(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "signal_channel_rpc_failed", fn ->
      with {:ok, result} <-
             AmbientCuration.record_judgment(turn_ref.agent_uid, turn_ref.actor_event_id, %{
               decision: request.decision,
               reason: request.reason,
               asked_by_source_entry_id: request.asked_by_source_entry_id,
               asked_by_degraded: request.asked_by_degraded
             }) do
        {:ok,
         %{
           "status" => "ok",
           "decision" => result.decision,
           "asked_by" => result.asked_by_state || "none"
         }}
      end
    end)
  end

  @spec handle_standing_orders_set(
          TurnRef.t(),
          FabricProto.SignalChannelStandingOrdersSetRequest.t(),
          map()
        ) :: {:ok, map()} | {:error, map()}
  def handle_standing_orders_set(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "signal_channel_rpc_failed", fn ->
      with {:ok, result} <-
             AmbientCuration.set_standing_orders(
               turn_ref.agent_uid,
               turn_ref.actor_event_id,
               request.orders
             ) do
        {:ok,
         %{
           "status" => "ok",
           "orders" => result.orders,
           "set_by" => result.set_by,
           "active" => result.active
         }}
      end
    end)
  end

  defp respond(ctx, fallback_code, fun) do
    case fun.() do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         RPCWire.error_payload(ctx.request_id, reason,
           fallback_code: fallback_code,
           details_json: %{"reason" => inspect(reason)}
         )}
    end
  end
end
