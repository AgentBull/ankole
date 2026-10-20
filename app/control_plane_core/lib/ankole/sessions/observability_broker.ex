defmodule Ankole.Sessions.ObservabilityBroker do
  @moduledoc false

  alias Ankole.Observability
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers.RPCWire

  @spec handle_export(
          String.t(),
          FabricProto.ObservabilitySpansExportRequest.t(),
          map()
        ) ::
          {:ok, FabricProto.ObservabilitySpansExportResponse.t()} | {:error, map()}
  def handle_export(
        _agent_uid,
        %FabricProto.ObservabilitySpansExportRequest{payload: payload},
        ctx
      ) do
    case Observability.export_worker_spans(payload) do
      :ok -> {:ok, %FabricProto.ObservabilitySpansExportResponse{}}
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
