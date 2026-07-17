defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobBroker do
  @moduledoc """
  Turn-fenced RuntimeFabric RPC broker for durable BackgroundAgentJob work.

  Parent turns may create and operate work visible from their current channel.
  Job turns may only mutate the work item encoded in their own
  `job:<id>` actor session. The worker route is therefore never an
  authorization boundary by itself.
  """

  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @create_request_fields ~w(
    background
    model
    notes
    agent_plugin_ids
    reasoning_effort
    skill_names
    source_tool_call_id
    task
    title
    workspace_mounts
  )

  @terminal_statuses Job.terminal_statuses()

  @spec handle_create(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_create(%TurnRef{} = turn_ref, request, route) when is_map(request) do
    request_id = request_id(request, "create")

    with :ok <- require_owner_turn(turn_ref),
         {:ok, actor_event} <- fetch_actor_event_for_turn(turn_ref),
         {:ok, conversation} <- fetch_owner_conversation(turn_ref),
         attrs <-
           request
           |> Map.take(@create_request_fields)
           |> Map.put("agent_uid", turn_ref.agent_uid)
           |> Map.put("owner_session_id", turn_ref.session_id)
           |> Map.put("source_actor_event_id", turn_ref.actor_event_id)
           |> Map.put("reply_route", reply_route(actor_event))
           |> put_worker_route_metadata(route)
           |> put_owner_brain_conversation(conversation.id),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.create_with_dispatch(attrs) do
      {:ok, job_payload(request_id, job)}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_get(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_get(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "get")
    job_id = RPCWire.text(request, "job_id") || ""

    with {:ok,
          %{
            job: %Job{} = job,
            execution: execution,
            attempt_history: attempt_history
          }} <-
           BackgroundAgentJobs.get_job_summary_for_agent(
             job_id,
             turn_ref.agent_uid,
             trajectory_options(request)
           ),
         :ok <- authorize_visible_job(turn_ref, job) do
      payload =
        request_id
        |> job_payload(job)
        |> maybe_put("execution", execution)
        |> maybe_put("attempt_history", attempt_history)
        |> maybe_put_result_ref(job)

      {:ok, payload}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_list(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_list(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "list")

    with :ok <- require_owner_turn(turn_ref),
         %ActorEvent{} = actor_event <- actor_event_for_turn(turn_ref) do
      jobs =
        BackgroundAgentJobs.list_for_channel(
          turn_ref.agent_uid,
          turn_ref.session_id,
          actor_event.signal_channel_id
        )

      {:ok,
       %{
         "request_id" => request_id,
         "jobs" => Enum.map(jobs, &job_summary/1)
       }}
    else
      nil -> error(request_id, turn_ref.agent_uid, :actor_event_not_found)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_upsert_turn(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_upsert_turn(%TurnRef{} = turn_ref, request, route) when is_map(request) do
    request_id = request_id(request, "turn")
    job_id = RPCWire.text(request, "job_id") || ""

    attrs =
      Map.take(
        request,
        ~w(attempt runtime_thread_id runtime_turn_id kind status revision trajectory progress usage error started_at completed_at)
      )

    with :ok <- authorize_job_turn(turn_ref, job_id),
         {:ok, turn} <-
           BackgroundAgentJobs.upsert_turn_from_worker(
             job_id,
             turn_ref.agent_uid,
             attrs,
             turn_ref,
             route
           ) do
      {:ok,
       %{
         "request_id" => request_id,
         "job_id" => job_id,
         "turn" => BackgroundAgentJobs.console_turn_projection(turn)
       }}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_update_status(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_update_status(%TurnRef{} = turn_ref, request, route) when is_map(request) do
    request_id = request_id(request, "update")
    job_id = RPCWire.text(request, "job_id") || ""

    attrs =
      request
      |> Map.take(~w(status runtime_thread_id result error metadata started_at completed_at))
      |> put_worker_route_metadata(route)

    with :ok <- authorize_job_turn(turn_ref, job_id),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.commit_status_with_wakeup(
             job_id,
             turn_ref.agent_uid,
             attrs,
             turn_ref: turn_ref,
             worker_route: route
           ) do
      {:ok, job_payload(request_id, job)}
    else
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_stop(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_stop(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "stop")
    job_id = RPCWire.text(request, "job_id") || ""

    with %Job{} = job <-
           BackgroundAgentJobs.get_job_for_agent(job_id, turn_ref.agent_uid),
         :ok <- authorize_visible_job(turn_ref, job),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.request_stop(job_id, %{
             "agent_uid" => turn_ref.agent_uid,
             "request_id" => request_id,
             "cancel_requested_by" => "agent:#{turn_ref.agent_uid}",
             "reason" => RPCWire.text(request, "reason")
           }) do
      {:ok, job_payload(request_id, job)}
    else
      nil -> error(request_id, turn_ref.agent_uid, :job_not_found)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  @spec handle_steer(TurnRef.t(), map(), String.t()) :: {:ok, map()} | {:error, map()}
  def handle_steer(%TurnRef{} = turn_ref, request, _route) when is_map(request) do
    request_id = request_id(request, "steer")
    job_id = RPCWire.text(request, "job_id") || ""

    with %Job{} = job <-
           BackgroundAgentJobs.get_job_for_agent(job_id, turn_ref.agent_uid),
         :ok <- authorize_visible_job(turn_ref, job),
         {:ok, %{job: %Job{} = job}} <-
           BackgroundAgentJobs.request_steer(job_id, %{
             "agent_uid" => turn_ref.agent_uid,
             "request_id" => request_id,
             "text" => RPCWire.text(request, "text"),
             "answers" => RPCWire.map_value(request, "answers", %{})
           }) do
      {:ok, job_payload(request_id, job)}
    else
      nil -> error(request_id, turn_ref.agent_uid, :job_not_found)
      {:error, reason} -> error(request_id, turn_ref.agent_uid, reason)
    end
  end

  defp authorize_visible_job(%TurnRef{} = turn_ref, %Job{} = job) do
    cond do
      turn_ref.session_id == "job:#{job.id}" ->
        :ok

      String.starts_with?(turn_ref.session_id, "job:") ->
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
    case turn_ref.session_id do
      "job:" <> ^job_id -> :ok
      _session_id -> {:error, :background_agent_job_turn_mismatch}
    end
  end

  defp require_owner_turn(%TurnRef{session_id: "job:" <> _job_id}),
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

  defp job_payload(request_id, %Job{} = job) do
    %{
      "request_id" => request_id,
      "job_id" => job.id,
      "agent_uid" => job.agent_uid,
      "owner_session_id" => job.owner_session_id,
      "source_actor_event_id" => job.source_actor_event_id,
      "source_tool_call_id" => job.source_tool_call_id,
      "status" => job.status,
      "runtime_thread_id" => job.runtime_thread_id,
      "codex_account_id" => job.codex_account_id,
      "title" => job.title,
      "task" => job.task,
      "background" => job.background,
      "notes" => job.notes,
      "reply_route" => job.reply_route,
      "attempts" => job.attempts,
      "agent_plugin_ids" => job.agent_plugin_ids,
      "skill_names" => job.skill_names,
      "workspace_mounts" => job.workspace_mounts,
      "model" => job.model,
      "reasoning_effort" => job.reasoning_effort,
      "queued_at" => iso8601(job.queued_at),
      "started_at" => iso8601(job.started_at),
      "completed_at" => iso8601(job.completed_at),
      "result" => job.result || %{},
      "error" => job.error || %{},
      "metadata" => job.metadata || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp job_summary(%Job{} = job) do
    %{
      "job_id" => job.id,
      "title" => job.title,
      "status" => job.status,
      "agent_plugin_ids" => job.agent_plugin_ids,
      "attempts" => job.attempts,
      "queued_at" => iso8601(job.queued_at),
      "started_at" => iso8601(job.started_at),
      "completed_at" => iso8601(job.completed_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp trajectory_options(request) do
    [
      trajectory_limit: RPCWire.value(request, "trajectory_limit"),
      trajectory_cursor: RPCWire.value(request, "trajectory_cursor")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp request_id(request, action) do
    RPCWire.text(request, "request_id") ||
      "background-agent-job-#{action}-#{Ecto.UUID.generate()}"
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

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_result_ref(map, %Job{status: status, id: id})
       when status in @terminal_statuses do
    Map.put(map, "result_ref", %{"type" => "background_agent_job", "job_id" => id})
  end

  defp maybe_put_result_ref(map, %Job{}), do: map

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
