defmodule Ankole.Sessions.BackgroundAgentJobBroker do
  @moduledoc """
  Turn-fenced RuntimeFabric RPC broker for durable BackgroundAgentJob work.

  Job turns may read their own Job and its direct continuation source.
  A Job turn may only mutate its own Job. A request is authorized by the Agent of its
  connection and by the fence of the Turn that it names.
  """

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.Common
  alias Ankole.AgentWorkers.RPCWire
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Text

  @max_result_offset 2_147_483_646

  @spec handle_get(JobTurnRef.t(), FabricProto.BackgroundAgentJobGetRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobResponse.t()} | {:error, map()}
  def handle_get(
        %JobTurnRef{} = turn_ref,
        %FabricProto.BackgroundAgentJobGetRequest{result_offset: result_offset} = request,
        ctx
      )
      when result_offset != "" do
    with {:ok, job_id} <- request_job_id(request.job_id),
         {:ok, offset} <- request_result_offset(result_offset),
         %{
           job: %Job{} = job,
           output_window: output_window,
           total_bytes: total_bytes
         } <- BackgroundAgentJobs.get_result_window_for_agent(job_id, turn_ref.agent_uid, offset),
         :ok <- authorize_job_target(turn_ref, job),
         {:ok, response} <-
           result_output_response(job, offset, output_window, total_bytes) do
      {:ok, response}
    else
      nil -> error(ctx.request_id, turn_ref.agent_uid, :job_not_found)
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  def handle_get(
        %JobTurnRef{} = turn_ref,
        %FabricProto.BackgroundAgentJobGetRequest{} = request,
        ctx
      ) do
    with {:ok, job_id} <- request_job_id(request.job_id),
         %Job{} = job <- BackgroundAgentJobs.get_job_for_agent(job_id, turn_ref.agent_uid),
         :ok <- authorize_job_target(turn_ref, job) do
      {:ok,
       %{
         job_response(job)
         | attempt_history:
             attempt_history_entries(Ankole.BackgroundAgentJobs.Turns.attempt_history(job))
       }}
    else
      nil -> error(ctx.request_id, turn_ref.agent_uid, :job_not_found)
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_upsert_turn(
          JobTurnRef.t(),
          FabricProto.BackgroundAgentJobTurnUpsertRequest.t(),
          map()
        ) ::
          {:ok, FabricProto.BackgroundAgentJobTurnUpsertResponse.t()} | {:error, map()}
  def handle_upsert_turn(
        %JobTurnRef{} = turn_ref,
        %FabricProto.BackgroundAgentJobTurnUpsertRequest{} = request,
        ctx
      ) do
    attrs =
      %{
        "attempt" => request.attempt,
        "runtime_thread_id" => request.runtime_thread_id,
        "runtime_turn_id" => request.runtime_turn_id,
        "kind" => request.kind,
        "status" => request.status,
        "revision" => request.revision
      }
      |> put_json_document("trajectory", request.trajectory_json)
      |> put_json_document("turn_items", request.turn_items_json)
      |> put_json_document("progress", request.progress_json)
      |> put_json_document("usage", request.usage_json)
      |> put_json_document("error", request.error_json)
      |> put_present("started_at", request.started_at)
      |> put_present("completed_at", request.completed_at)

    with {:ok, job_id} <- request_job_id(request.job_id),
         :ok <- authorize_job_turn(turn_ref, job_id),
         {:ok, turn} <-
           BackgroundAgentJobs.upsert_turn_from_worker(
             job_id,
             turn_ref.agent_uid,
             attrs,
             turn_ref,
             ctx.worker_id
           ) do
      {:ok,
       %FabricProto.BackgroundAgentJobTurnUpsertResponse{
         job_id: Integer.to_string(job_id),
         turn: turn_message(BackgroundAgentJobs.worker_turn_projection(turn))
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_turn_items_list(
          JobTurnRef.t(),
          FabricProto.BackgroundAgentJobTurnItemsListRequest.t(),
          map()
        ) ::
          {:ok, FabricProto.BackgroundAgentJobTurnItemsListResponse.t()} | {:error, map()}
  def handle_turn_items_list(
        %JobTurnRef{} = turn_ref,
        %FabricProto.BackgroundAgentJobTurnItemsListRequest{} = request,
        ctx
      ) do
    with {:ok, job_id} <- request_job_id(request.job_id),
         :ok <- authorize_job_turn(turn_ref, job_id),
         %Job{} = job <- BackgroundAgentJobs.get_job_for_agent(job_id, turn_ref.agent_uid),
         {:ok, page} <-
           BackgroundAgentJobs.replay_items_page(job, present_or_nil(request.cursor)) do
      {:ok,
       %FabricProto.BackgroundAgentJobTurnItemsListResponse{
         job_id: Integer.to_string(job_id),
         items: Enum.map(page.items, &turn_item_message/1),
         next_cursor: page.next_cursor || ""
       }}
    else
      nil -> error(ctx.request_id, turn_ref.agent_uid, :job_not_found)
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_update_status(
          JobTurnRef.t(),
          FabricProto.BackgroundAgentJobStatusUpdateRequest.t(),
          map()
        ) ::
          {:ok, FabricProto.BackgroundAgentJobResponse.t()} | {:error, map()}
  def handle_update_status(
        %JobTurnRef{} = turn_ref,
        %FabricProto.BackgroundAgentJobStatusUpdateRequest{} = request,
        ctx
      ) do
    attrs =
      %{"status" => request.status}
      |> put_present("runtime_thread_id", request.runtime_thread_id)
      |> put_json_document("result", request.result_json)
      |> put_json_document("error", request.error_json)
      |> put_json_document("metadata", request.metadata_json)

    with {:ok, job_id} <- request_job_id(request.job_id),
         :ok <- authorize_job_turn(turn_ref, job_id),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.commit_status_with_wakeup(
             job_id,
             turn_ref.agent_uid,
             attrs,
             turn_ref: turn_ref,
             worker_id: ctx.worker_id,
             applied_signal_ids: request.applied_signal_ids
           ) do
      {:ok, job_response(job)}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  defp authorize_job_target(%JobTurnRef{job_id: id}, %Job{id: id}), do: :ok

  defp authorize_job_target(%JobTurnRef{} = turn_ref, %Job{id: source_id}) do
    case BackgroundAgentJobs.get_job_for_agent(turn_ref.job_id, turn_ref.agent_uid) do
      %Job{continued_from_job_id: ^source_id} -> :ok
      _other -> {:error, :background_agent_job_scope_mismatch}
    end
  end

  defp authorize_job_turn(%JobTurnRef{} = turn_ref, job_id) do
    case BackgroundAgentJobs.parse_job_session_id(turn_ref.session_id) do
      {:ok, ^job_id} -> :ok
      _other -> {:error, :background_agent_job_turn_mismatch}
    end
  end

  # Wire projection of one durable Job row. The Console keeps its own map
  # projection; this struct is the RPC contract.
  defp job_response(%Job{} = job) do
    %FabricProto.BackgroundAgentJobResponse{
      agent_uid: job.agent_uid,
      status: job.status,
      runtime_thread_id: job.runtime_thread_id || "",
      task: job.task,
      attempts: job.attempts,
      workspace_template_id: job.workspace_template_id || "",
      continued_from_job_id: optional_job_id(job.continued_from_job_id),
      workspace_owner_job_id: optional_job_id(job.workspace_owner_job_id),
      metadata_json: encode_optional_json(job.metadata),
      runtime_projection_json: encode_optional_json(job.runtime_projection)
    }
  end

  defp attempt_history_entries(nil), do: []

  defp attempt_history_entries(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %FabricProto.BackgroundAgentJobAttemptHistoryEntry{
        attempt: Map.get(entry, :attempt) || 0,
        turn_statuses: Map.get(entry, :turn_statuses) || [],
        summary: Map.get(entry, :summary) || "",
        used_skill_names: Map.get(entry, :used_skill_names) || []
      }
    end)
  end

  defp result_output_response(%Job{} = job, offset, output_window, total_bytes) do
    with {:ok, {output_text, total_bytes}} <-
           result_output_window(job, offset, output_window, total_bytes) do
      {:ok,
       %FabricProto.BackgroundAgentJobResponse{
         status: job.status,
         task: job.task,
         result_output_text: output_text,
         result_output_total_bytes: Integer.to_string(total_bytes)
       }}
    end
  end

  defp result_output_window(%Job{status: status}, _offset, _output_window, _total_bytes)
       when status != "succeeded",
       do: {:ok, {"", 0}}

  defp result_output_window(
         %Job{status: "succeeded"},
         offset,
         output_window,
         total_bytes
       )
       when is_binary(output_window) and is_integer(total_bytes) and total_bytes >= 0 do
    cond do
      offset > total_bytes ->
        {:error, :invalid_background_agent_job_result_offset}

      utf8_boundary?(output_window, offset, total_bytes) ->
        {:ok, {result_output_prefix(output_window), total_bytes}}

      true ->
        {:error, :invalid_background_agent_job_result_offset}
    end
  end

  defp result_output_window(%Job{}, _offset, _output_window, _total_bytes),
    do: {:error, :background_agent_job_result_output_missing}

  defp utf8_boundary?(_output_window, offset, total_bytes) when offset == total_bytes, do: true

  defp utf8_boundary?(<<byte, _suffix::binary>>, _offset, _total_bytes) do
    byte < 0x80 or byte >= 0xC0
  end

  defp utf8_boundary?(<<>>, _offset, _total_bytes), do: false

  defp result_output_prefix(output_window) do
    if String.valid?(output_window) do
      output_window
    else
      Text.utf8_prefix(output_window, byte_size(output_window) - 1)
    end
  end

  defp optional_job_id(nil), do: ""
  defp optional_job_id(job_id) when is_integer(job_id), do: Integer.to_string(job_id)

  defp turn_message(projection) when is_map(projection) do
    %FabricProto.BackgroundAgentJobTurn{
      id: Map.get(projection, :id) || "",
      attempt: Map.get(projection, :attempt) || 0,
      runtime_thread_id: Map.get(projection, :runtime_thread_id) || "",
      runtime_turn_id: Map.get(projection, :runtime_turn_id) || "",
      kind: Map.get(projection, :kind) || "",
      status: Map.get(projection, :status) || "",
      revision: Map.get(projection, :revision) || 0,
      trajectory_json: encode_optional_json(Map.get(projection, :trajectory)),
      progress_json: encode_optional_json(Map.get(projection, :progress)),
      usage_json: encode_optional_json(Map.get(projection, :usage)),
      error_json: encode_optional_json(Map.get(projection, :error)),
      started_at: Map.get(projection, :started_at) || "",
      completed_at: Map.get(projection, :completed_at) || "",
      inserted_at: Map.get(projection, :inserted_at) || "",
      updated_at: Map.get(projection, :updated_at) || ""
    }
  end

  defp request_job_id(value) do
    case BackgroundAgentJobs.parse_job_id(value) do
      {:ok, job_id} -> {:ok, job_id}
      :error -> {:error, :invalid_background_agent_job_id}
    end
  end

  defp request_result_offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset >= 0 and offset <= @max_result_offset -> {:ok, offset}
      _value -> {:error, :invalid_background_agent_job_result_offset}
    end
  end

  defp error(request_id, agent_uid, reason) do
    {:error,
     RPCWire.error_payload(request_id, reason,
       fallback_code: "background_agent_job_failed",
       changeset_code: "invalid_background_agent_job",
       message_style: :tuple_inspect,
       details_json: %{"agent_uid" => agent_uid}
     )}
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_json_document(map, key, bytes) do
    case Common.decode_json_bytes(bytes) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp turn_item_message(item) when is_map(item) do
    %FabricProto.BackgroundAgentJobTurnItem{
      runtime_thread_id: Map.get(item, :runtime_thread_id) || "",
      runtime_turn_id: Map.get(item, :runtime_turn_id) || "",
      position: Map.get(item, :position) || 0,
      item_key: Map.get(item, :item_key) || "",
      item_json: Torque.encode!(Map.get(item, :item) || %{})
    }
  end

  defp present_or_nil(""), do: nil
  defp present_or_nil(value) when is_binary(value), do: value

  defp encode_optional_json(nil), do: ""
  defp encode_optional_json(value) when value == %{}, do: ""
  defp encode_optional_json(value), do: Torque.encode!(value)
end
