defmodule Ankole.AutomationJobs.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for automation job management and emission.
  """

  alias Ankole.AutomationJobs
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.ReplyRoute
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef

  @spec handle_create(TurnRef.t(), FabricProto.AutomationJobCreateRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_create(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, source} <- ReplyRoute.source(turn_ref),
           {:ok, directory_path} <- required_text(request.directory_path, :directory_path),
           {:ok, label} <- required_text(request.label, :label),
           {:ok, job} <-
             AutomationJobs.create_job(%{
               agent_uid: turn_ref.agent_uid,
               owner_session_id: turn_ref.session_id,
               source_actor_event_id: source.actor_event_id,
               source_entry_id: source.source_entry_id,
               source_provenance: %{
                 "rpc_request_id" => ctx.request_id,
                 "transport_route" => ctx.route,
                 "activation_uid" => turn_ref.activation_uid,
                 "actor_epoch" => turn_ref.actor_epoch,
                 "revision" => turn_ref.revision
               },
               reply_route: %{
                 "binding_name" => source.binding_name,
                 "signal_channel_id" => source.signal_channel_id,
                 "provider_thread_id" => source.provider_thread_id,
                 "source_entry_id" => source.source_entry_id
               },
               directory_path: directory_path,
               label: label,
               wake_on_failure: request.wake_on_failure
             }) do
        {:ok,
         %{
           "status" => "created",
           "automation_job" => AutomationJobs.model_projection(job)
         }}
      end
    end)
  end

  @spec handle_list(TurnRef.t(), FabricProto.AutomationJobListRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      jobs =
        AutomationJobs.list_jobs(turn_ref.agent_uid, turn_ref.session_id,
          limit: list_limit(request.limit)
        )

      {:ok,
       %{
         "status" => "ok",
         "automation_jobs" => Enum.map(jobs, &AutomationJobs.model_projection/1)
       }}
    end)
  end

  @spec handle_show(TurnRef.t(), FabricProto.AutomationJobShowRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_show(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, job_id} <- positive_integer(request.automation_job_id, :automation_job_id),
           {:ok, %{automation_job: job, runs: runs}} <-
             AutomationJobs.show_job(turn_ref.agent_uid, turn_ref.session_id, job_id,
               runs: run_limit(request.runs)
             ) do
        {:ok,
         %{
           "status" => "ok",
           "result" => AutomationJobs.model_detail_projection(job, runs)
         }}
      end
    end)
  end

  @spec handle_cancel(TurnRef.t(), FabricProto.AutomationJobTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cancel(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, job_id} <- positive_integer(request.automation_job_id, :automation_job_id),
           {:ok, %{status: status, automation_job: job}} <-
             AutomationJobs.cancel_job(turn_ref.agent_uid, turn_ref.session_id, job_id) do
        {:ok,
         %{
           "status" => Atom.to_string(status),
           "automation_job" => AutomationJobs.model_projection(job)
         }}
      end
    end)
  end

  @spec handle_emit(
          String.t() | nil,
          FabricProto.AutomationJobEmitRequest.t(),
          map()
        ) ::
          {:ok, FabricProto.AutomationJobEmitResponse.t()} | {:error, map()}
  def handle_emit(agent_uid, request, ctx) do
    respond(ctx, fn ->
      with {:ok, agent_uid} <- required_text(agent_uid, :agent_uid),
           {:ok, run_id} <-
             positive_integer(request.automation_job_run_id, :automation_job_run_id),
           {:ok, attempt_id} <- uuid(request.attempt_id, :attempt_id),
           payload <- Common.decode_json_bytes(request.payload_json),
           {:ok, _actor_event} <-
             AutomationJobs.emit_event(agent_uid, run_id, attempt_id, payload) do
        {:ok, %FabricProto.AutomationJobEmitResponse{}}
      end
    end)
  end

  defp respond(ctx, fun) do
    case fun.() do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, error_payload(ctx.request_id, reason)}
    end
  end

  defp positive_integer(value, key) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 and integer <= 9_007_199_254_740_991 ->
        {:ok, integer}

      _invalid ->
        {:error, {:invalid_positive_integer, key}}
    end
  end

  defp positive_integer(_value, key), do: {:error, {:invalid_positive_integer, key}}

  defp uuid(value, key) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, key}}
    end
  end

  defp required_text(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:missing_text, key}}
      text -> {:ok, text}
    end
  end

  defp required_text(_value, key), do: {:error, {:missing_text, key}}

  defp list_limit(value) when is_integer(value) and value > 0, do: min(value, 500)
  defp list_limit(_value), do: 100

  defp run_limit(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp run_limit(_value), do: 20

  defp error_payload(request_id, reason) do
    RPCWire.error_payload(request_id, reason,
      fallback_code: "automation_job_rpc_failed",
      details_json: %{"reason" => inspect(reason)}
    )
  end
end
