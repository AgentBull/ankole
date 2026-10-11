defmodule Ankole.SignalsGateway.ActorRuntime.ActorTurnCompletionBroker do
  @moduledoc "Accepts a failed Codex startup through the Job attempt fence."
  alias Ankole.Conversations.{CodexJob, JobTurnRef}
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.SignalsGateway.ActorRuntime.{Common, RPCWire}

  def handle_abort(%JobTurnRef{} = ref, %Proto.ActorTurnAbortRequest{} = request, ctx) do
    reason = %{
      "code" => request.code,
      "message" => request.message,
      "details_json" => Common.decode_json_bytes(request.details_json) || %{}
    }

    case CodexJob.abort(ref, ctx.worker_id, reason) do
      {:ok, event} ->
        {:ok,
         %Proto.ActorTurnAbortResponse{
           retry_available_at: DateTime.to_iso8601(event.available_at)
         }}

      {:error, reason} ->
        {:error, RPCWire.error_payload(ctx.request_id, reason, fallback_code: "job_abort_failed")}
    end
  end
end
