defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBroker do
  @moduledoc """
  Turn-fenced RuntimeFabric RPC broker for durable BackgroundAgentJob work.

  Parent turns may create and operate work visible from their current channel.
  Job turns may only mutate the work item encoded in their own
  `job:<id>` actor session. The worker route is therefore never an
  authorization boundary by itself.
  """

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.AIGatewayLink

  require Ankole.BackgroundAgentJobs

  @terminal_statuses Job.terminal_statuses()

  @spec handle_create(TurnRef.t(), FabricProto.BackgroundAgentJobCreateRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobResponse.t()} | {:error, map()}
  def handle_create(%TurnRef{} = turn_ref, %FabricProto.BackgroundAgentJobCreateRequest{} = request, ctx) do
    with :ok <- require_owner_turn(turn_ref),
         {:ok, actor_event} <- fetch_actor_event_for_turn(turn_ref),
         {:ok, conversation} <- fetch_owner_conversation(turn_ref),
         attrs <-
           create_attrs(request)
           |> Map.put("agent_uid", turn_ref.agent_uid)
           |> Map.put("owner_session_id", turn_ref.session_id)
           |> Map.put("source_actor_event_id", turn_ref.actor_event_id)
           |> Map.put("reply_route", reply_route(actor_event))
           |> put_worker_route_metadata(ctx.route)
           |> put_owner_brain_conversation(conversation.id),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.create_with_dispatch(attrs) do
      {:ok, job_response(job)}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_get(TurnRef.t(), FabricProto.BackgroundAgentJobGetRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobResponse.t()} | {:error, map()}
  def handle_get(%TurnRef{} = turn_ref, %FabricProto.BackgroundAgentJobGetRequest{} = request, ctx) do
    with {:ok,
          %{
            job: %Job{} = job,
            execution: execution,
            attempt_history: attempt_history
          }} <-
           BackgroundAgentJobs.get_job_summary_for_agent(
             request.job_id,
             turn_ref.agent_uid,
             trajectory_options(request)
           ),
         :ok <- authorize_visible_job(turn_ref, job) do
      response = job_response(job)

      {:ok,
       %{
         response
         | execution_json: encode_optional_json(execution),
           attempt_history: attempt_history_entries(attempt_history),
           result_ref: result_ref(job)
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_list(TurnRef.t(), FabricProto.BackgroundAgentJobListRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobListResponse.t()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, %FabricProto.BackgroundAgentJobListRequest{}, ctx) do
    with :ok <- require_owner_turn(turn_ref),
         %ActorEvent{} = actor_event <- actor_event_for_turn(turn_ref) do
      jobs =
        BackgroundAgentJobs.list_for_channel(
          turn_ref.agent_uid,
          turn_ref.session_id,
          actor_event.signal_channel_id
        )

      {:ok, %FabricProto.BackgroundAgentJobListResponse{jobs: Enum.map(jobs, &job_summary/1)}}
    else
      nil -> error(ctx.request_id, turn_ref.agent_uid, :actor_event_not_found)
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_upsert_turn(TurnRef.t(), FabricProto.BackgroundAgentJobTurnUpsertRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobTurnUpsertResponse.t()} | {:error, map()}
  def handle_upsert_turn(%TurnRef{} = turn_ref, %FabricProto.BackgroundAgentJobTurnUpsertRequest{} = request, ctx) do
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
      |> put_json_document("trajectory_groups", request.trajectory_groups_json)
      |> put_json_document("progress", request.progress_json)
      |> put_json_document("usage", request.usage_json)
      |> put_json_document("error", request.error_json)
      |> put_present("started_at", request.started_at)
      |> put_present("completed_at", request.completed_at)

    with :ok <- authorize_job_turn(turn_ref, request.job_id),
         {:ok, turn} <-
           BackgroundAgentJobs.upsert_turn_from_worker(
             request.job_id,
             turn_ref.agent_uid,
             attrs,
             turn_ref,
             ctx.route
           ) do
      {:ok,
       %FabricProto.BackgroundAgentJobTurnUpsertResponse{
         job_id: request.job_id,
         turn: turn_message(BackgroundAgentJobs.console_turn_projection(turn))
       }}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_update_status(TurnRef.t(), FabricProto.BackgroundAgentJobStatusUpdateRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobResponse.t()} | {:error, map()}
  def handle_update_status(%TurnRef{} = turn_ref, %FabricProto.BackgroundAgentJobStatusUpdateRequest{} = request, ctx) do
    attrs =
      %{"status" => request.status}
      |> put_present("runtime_thread_id", request.runtime_thread_id)
      |> put_json_document("result", request.result_json)
      |> put_json_document("error", request.error_json)
      |> put_json_document("metadata", request.metadata_json)
      |> put_worker_route_metadata(ctx.route)

    with :ok <- authorize_job_turn(turn_ref, request.job_id),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.commit_status_with_wakeup(
             request.job_id,
             turn_ref.agent_uid,
             attrs,
             turn_ref: turn_ref,
             worker_route: ctx.route
           ) do
      {:ok, job_response(job)}
    else
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_stop(TurnRef.t(), FabricProto.BackgroundAgentJobStopRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobResponse.t()} | {:error, map()}
  def handle_stop(%TurnRef{} = turn_ref, %FabricProto.BackgroundAgentJobStopRequest{} = request, ctx) do
    with %Job{} = job <-
           BackgroundAgentJobs.get_job_for_agent(request.job_id, turn_ref.agent_uid),
         :ok <- authorize_visible_job(turn_ref, job),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.request_stop(request.job_id, %{
             "agent_uid" => turn_ref.agent_uid,
             "request_id" => ctx.request_id,
             "cancel_requested_by" => "agent:#{turn_ref.agent_uid}",
             "reason" => presence(request.reason)
           }) do
      {:ok, job_response(job)}
    else
      nil -> error(ctx.request_id, turn_ref.agent_uid, :job_not_found)
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_steer(TurnRef.t(), FabricProto.BackgroundAgentJobSteerRequest.t(), map()) ::
          {:ok, FabricProto.BackgroundAgentJobResponse.t()} | {:error, map()}
  def handle_steer(%TurnRef{} = turn_ref, %FabricProto.BackgroundAgentJobSteerRequest{} = request, ctx) do
    with %Job{} = job <-
           BackgroundAgentJobs.get_job_for_agent(request.job_id, turn_ref.agent_uid),
         :ok <- authorize_visible_job(turn_ref, job),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.request_steer(request.job_id, %{
             "agent_uid" => turn_ref.agent_uid,
             "request_id" => ctx.request_id,
             "text" => presence(request.text),
             "answers" => steer_answers(request.answers_json)
           }) do
      {:ok, job_response(job)}
    else
      nil -> error(ctx.request_id, turn_ref.agent_uid, :job_not_found)
      {:error, reason} -> error(ctx.request_id, turn_ref.agent_uid, reason)
    end
  end

  # Empty repeated fields mean the caller did not select anything; the domain
  # contract treats those keys as absent.
  defp create_attrs(request) do
    %{
      "source_tool_call_id" => request.source_tool_call_id,
      "title" => request.title,
      "task" => request.task
    }
    |> put_present("background", request.background)
    |> put_present("notes", request.notes)
    |> put_present("model", request.model)
    |> put_present("reasoning_effort", request.reasoning_effort)
    |> put_nonempty_list("agent_plugin_ids", request.agent_plugin_ids)
    |> put_nonempty_list("skill_names", request.skill_names)
    |> put_nonempty_list(
      "workspace_mounts",
      Enum.map(request.workspace_mounts, &workspace_mount_attrs/1)
    )
  end

  defp put_nonempty_list(map, _key, []), do: map
  defp put_nonempty_list(map, key, values) when is_list(values), do: Map.put(map, key, values)

  defp workspace_mount_attrs(%FabricProto.BackgroundAgentJobWorkspaceMount{} = mount) do
    %{"id" => mount.id, "source" => mount.source, "access" => mount.access}
  end

  defp steer_answers(answers_json) do
    case Common.decode_json_bytes(answers_json) do
      %{} = answers -> answers
      _value -> %{}
    end
  end

  defp authorize_visible_job(%TurnRef{} = turn_ref, %Job{} = job) do
    cond do
      turn_ref.session_id == BackgroundAgentJobs.job_session_id(job.id) ->
        :ok

      BackgroundAgentJobs.is_job_session_id(turn_ref.session_id) ->
        {:error, :background_agent_job_scope_mismatch}

      job.owner_session_id == turn_ref.session_id ->
        :ok

      true ->
        authorize_same_channel(turn_ref, job)
    end
  end

  defp authorize_same_channel(turn_ref, job) do
    with %ActorEvent{signal_channel_id: channel_id} when is_binary(channel_id) <-
           actor_event_for_turn(turn_ref),
         ^channel_id when is_binary(channel_id) <-
           Map.get(job.reply_route || %{}, "signal_channel_id") do
      :ok
    else
      _value -> {:error, :background_agent_job_scope_mismatch}
    end
  end

  defp authorize_job_turn(%TurnRef{} = turn_ref, job_id) do
    case BackgroundAgentJobs.parse_job_session_id(turn_ref.session_id) do
      {:ok, ^job_id} -> :ok
      _other -> {:error, :background_agent_job_turn_mismatch}
    end
  end

  defp require_owner_turn(%TurnRef{session_id: session_id})
       when BackgroundAgentJobs.is_job_session_id(session_id),
       do: {:error, :background_agent_job_owner_turn_required}

  defp require_owner_turn(%TurnRef{}), do: :ok

  defp actor_event_for_turn(%TurnRef{} = turn_ref) do
    case Repo.get(ActorEvent, turn_ref.actor_event_id) do
      %ActorEvent{agent_uid: agent_uid, session_id: session_id} = event
      when agent_uid == turn_ref.agent_uid and session_id == turn_ref.session_id ->
        event

      _event ->
        nil
    end
  end

  defp fetch_actor_event_for_turn(turn_ref) do
    case actor_event_for_turn(turn_ref) do
      %ActorEvent{} = actor_event -> {:ok, actor_event}
      nil -> {:error, :actor_event_not_found}
    end
  end

  defp fetch_owner_conversation(turn_ref) do
    case AIGatewayLink.active_conversation(turn_ref.agent_uid, turn_ref.session_id) do
      %{} = conversation -> {:ok, conversation}
      nil -> {:error, :owner_conversation_not_found}
    end
  end

  defp reply_route(actor_event) do
    %{
      "binding_name" => actor_event.binding_name,
      "signal_channel_id" => actor_event.signal_channel_id,
      "provider_thread_id" => actor_event.provider_thread_id,
      "source_entry_id" => actor_event.source_entry_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Wire projection of one durable Job row. The Console keeps its own map
  # projection; this struct is the RPC contract.
  defp job_response(%Job{} = job) do
    %FabricProto.BackgroundAgentJobResponse{
      job_id: job.id,
      agent_uid: job.agent_uid,
      owner_session_id: job.owner_session_id,
      source_actor_event_id: job.source_actor_event_id || "",
      source_tool_call_id: job.source_tool_call_id || "",
      status: job.status,
      runtime_thread_id: job.runtime_thread_id || "",
      codex_account_id: job.codex_account_id,
      title: job.title,
      task: job.task,
      background: job.background || "",
      notes: job.notes || "",
      reply_route_json: encode_optional_json(job.reply_route),
      attempts: job.attempts,
      agent_plugin_ids: job.agent_plugin_ids || [],
      skill_names: job.skill_names || [],
      workspace_mounts: Enum.map(job.workspace_mounts || [], &workspace_mount_message/1),
      model: job.model || "",
      reasoning_effort: job.reasoning_effort || "",
      queued_at: iso8601(job.queued_at),
      started_at: iso8601(job.started_at),
      completed_at: iso8601(job.completed_at),
      result_json: encode_optional_json(job.result),
      error_json: encode_optional_json(job.error),
      metadata_json: encode_optional_json(job.metadata)
    }
  end

  defp job_summary(%Job{} = job) do
    %FabricProto.BackgroundAgentJobSummary{
      job_id: job.id,
      title: job.title,
      status: job.status,
      agent_plugin_ids: job.agent_plugin_ids || [],
      attempts: job.attempts,
      queued_at: iso8601(job.queued_at),
      started_at: iso8601(job.started_at),
      completed_at: iso8601(job.completed_at)
    }
  end

  defp workspace_mount_message(mount) when is_map(mount) do
    %FabricProto.BackgroundAgentJobWorkspaceMount{
      id: RPCWire.text(mount, "id") || "",
      source: RPCWire.text(mount, "source") || "",
      access: RPCWire.text(mount, "access") || ""
    }
  end

  defp attempt_history_entries(nil), do: []

  defp attempt_history_entries(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %FabricProto.BackgroundAgentJobAttemptHistoryEntry{
        attempt: Map.get(entry, :attempt) || 0,
        turn_statuses: Map.get(entry, :turn_statuses) || [],
        summary: Map.get(entry, :summary) || ""
      }
    end)
  end

  defp result_ref(%Job{status: status, id: id}) when status in @terminal_statuses do
    %FabricProto.BackgroundAgentJobResultRef{type: "background_agent_job", job_id: id}
  end

  defp result_ref(%Job{}), do: nil

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

  defp trajectory_options(request) do
    [
      trajectory_limit: request.trajectory_limit,
      trajectory_cursor: presence(request.trajectory_cursor)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_json_document(map, key, bytes) do
    case Common.decode_json_bytes(bytes) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp encode_optional_json(nil), do: ""
  defp encode_optional_json(value) when value == %{}, do: ""
  defp encode_optional_json(value), do: Torque.encode!(value)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso8601(_value), do: ""

  defp put_worker_route_metadata(map, route) when is_map(map) and is_binary(route) do
    metadata = RPCWire.map_value(map, "metadata", %{})
    Map.put(map, "metadata", Map.put(metadata, "worker_route", route))
  end

  defp put_worker_route_metadata(map, _route), do: map

  defp put_owner_brain_conversation(map, conversation_id) do
    metadata = RPCWire.map_value(map, "metadata", %{})
    Map.put(map, "metadata", Map.put(metadata, "brain_owner_conversation_id", conversation_id))
  end
end
