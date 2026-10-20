defmodule Ankole.AutomationJobs.RPCBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for automation job management and emission.
  """

  alias Ankole.AutomationJobs
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.Common
  alias Ankole.Conversations.Route
  alias Ankole.AgentWorkers.RPCWire
  alias Ankole.Sessions.RunRef

  @spec handle_create(RunRef.t(), FabricProto.AutomationJobCreateRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_create(%{agent_uid: _} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, %{source: source, owner_session_id: owner_session_id, reply_route: route}} <-
             Route.long_lived_source(turn_ref),
           {:ok, drive_prefix} <- required_text(request.drive_prefix, :drive_prefix),
           {:ok, label} <- required_text(request.label, :label),
           {:ok, job} <-
             AutomationJobs.create_job(%{
               agent_uid: turn_ref.agent_uid,
               owner_session_id: owner_session_id,
               source_signal_id: source.signal_id,
               provider_message_id: source.provider_message_id,
               source_provenance: %{
                 "rpc_request_id" => ctx.request_id,
                 "transport_route" => ctx.route
               },
               reply_route: route,
               drive_prefix: drive_prefix,
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

  @spec handle_list(RunRef.t(), FabricProto.AutomationJobListRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_list(%{agent_uid: _} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, owner} <- Route.long_lived_owner(turn_ref.agent_uid, turn_ref.session_id) do
        jobs =
          AutomationJobs.list_jobs(turn_ref.agent_uid, owner.session_id,
            limit: list_limit(request.limit)
          )

        {:ok,
         %{
           "status" => "ok",
           "automation_jobs" => Enum.map(jobs, &AutomationJobs.model_projection/1)
         }}
      end
    end)
  end

  @spec handle_show(RunRef.t(), FabricProto.AutomationJobShowRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_show(%{agent_uid: _} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, owner} <- Route.long_lived_owner(turn_ref.agent_uid, turn_ref.session_id),
           {:ok, job_id} <- positive_integer(request.automation_job_id, :automation_job_id),
           {:ok, %{automation_job: job, runs: runs}} <-
             AutomationJobs.show_job(turn_ref.agent_uid, owner.session_id, job_id,
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

  @spec handle_cancel(RunRef.t(), FabricProto.AutomationJobTargetRequest.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def handle_cancel(%{agent_uid: _} = turn_ref, request, ctx) do
    respond(ctx, fn ->
      with {:ok, owner} <- Route.long_lived_owner(turn_ref.agent_uid, turn_ref.session_id),
           {:ok, job_id} <- positive_integer(request.automation_job_id, :automation_job_id),
           {:ok, %{status: status, automation_job: job}} <-
             AutomationJobs.cancel_job(turn_ref.agent_uid, owner.session_id, job_id) do
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
           {:ok, _signal} <-
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
