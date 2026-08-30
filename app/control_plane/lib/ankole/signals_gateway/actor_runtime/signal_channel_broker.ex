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
               action: request.action,
               authority: request.authority,
               handoff_job_id: request.handoff_job_id,
               reason: request.reason,
               asked_by_source_entry_id: request.asked_by_source_entry_id,
               asked_by_degraded: request.asked_by_degraded
             }) do
        {:ok,
         %{
           "status" => "ok",
           "action" => result.action,
           "authority" => result.authority,
           "handoff_job_id" => optional_job_id(result.handoff_job_id),
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

  defp optional_job_id(nil), do: nil
  defp optional_job_id(job_id) when is_integer(job_id), do: Integer.to_string(job_id)

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
