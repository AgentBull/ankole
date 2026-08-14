defmodule Ankole.SignalsGateway.ActorRuntime.ObservabilityBroker do
  @moduledoc false

  alias Ankole.Observability
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire

  @spec handle_export(
          String.t() | nil,
          FabricProto.ObservabilitySpansExportRequest.t(),
          map()
        ) ::
          {:ok, FabricProto.ObservabilitySpansExportResponse.t()} | {:error, map()}
  def handle_export(
        agent_uid,
        %FabricProto.ObservabilitySpansExportRequest{payload: payload},
        ctx
      ) do
    with true <- is_binary(agent_uid) and agent_uid != "",
         :ok <- Observability.export_worker_spans(payload) do
      {:ok, %FabricProto.ObservabilitySpansExportResponse{}}
    else
      false -> {:error, error_payload(ctx, :missing_agent_uid)}
      {:error, reason} -> {:error, error_payload(ctx, reason)}
    end
  end

  defp error_payload(ctx, reason) do
    RPCWire.error_payload(ctx.request_id, reason,
      fallback_code: "observability_spans_export_failed",
      message_style: :tuple_inspect,
      details_json: %{}
    )
  end
end
