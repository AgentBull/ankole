defmodule Ankole.Pod.JobsBoard.Operations do
  @moduledoc """
  Creates Background Agent Jobs and Cron Schedules from Pod `/jobs`, and
  controls existing routines and executions.
  """

  alias Ankole.{ActorRef, AgentWorkers, BackgroundAgentJobs, Conversations, Principals, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: AgentJob
  alias Ankole.Conversations.{Executions, Native}
  alias Ankole.Pod.JobsBoard.Queries
  alias Ankole.Principals.WorkAccess
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.{CronSchedule, ScheduledEvent}
  alias Ankole.Sessions.Key

  @title_limit 200
  @task_limit 20_000

  @doc """
  Creates either a one-off `BackgroundAgentJob` (`mode: :one_off`) or a
  recurring `CronSchedule` (`mode: :cron`) and returns its projected board card.
  """
  def create(%Actor{} = actor, raw_attrs) when is_map(raw_attrs) do
    attrs = normalize_create_attrs(raw_attrs)

    with true <- Native.active_human?(actor),
         {:ok, mode} <- normalize_mode(attrs.mode),
         {:ok, title} <- validate_title(attrs.title),
         {:ok, task} <- validate_task(attrs.task),
         {:ok, agent_uid} <- validate_agent(actor, attrs.agent_uid),
         {:ok, request_id} <- cast_uuid(attrs.request_id) do
      case mode do
        :one_off ->
          create_one_off(actor, agent_uid, title, task, request_id, attrs)

        :cron ->
          create_cron(actor, agent_uid, title, task, request_id, attrs)
      end
    else
      false -> {:error, :invalid_job}
      {:error, _} = error -> error
    end
  end

  defp create_one_off(actor, agent_uid, title, task, request_id, attrs) do
    with {:ok, normalized_runner_id} <-
           authorize_optional_runner(actor, agent_uid, attrs.runner_id),
         {:ok, owner_session_id, reply_route} <-
           resolve_one_off_route(actor, agent_uid, attrs.conversation_id, request_id),
         {:ok, %{job: job}} <-
           BackgroundAgentJobs.create_with_dispatch(%{
             "agent_uid" => agent_uid,
             "runner_id" => normalized_runner_id,
             "title" => title,
             "task" => task,
             "owner_session_id" => owner_session_id,
             "source_tool_call_id" => "pod-job:" <> request_id,
             "created_by" => %{"principal_uid" => to_string(ActorRef.from_actor(actor))},
             "reply_route" => reply_route
           })
           |> normalize_dispatch_error() do
      Conversations.Events.publish_rooms_changed()
      fetch_card(actor, "job:#{job.id}")
    end
  end

  defp create_cron(actor, agent_uid, title, task, request_id, attrs) do
    default_quiet? = is_nil(attrs.conversation_id) or attrs.conversation_id == ""

    quiet_success? =
      if is_boolean(attrs.quiet_success), do: attrs.quiet_success, else: default_quiet?

    with {:ok, repeat} <- validate_repeat(attrs.repeat),
         {:ok, room_id} <- resolve_cron_delivery_room(actor, agent_uid, attrs.conversation_id),
         {:ok, %{cron_schedule: rule}} <-
           Schedule.create_cron_schedule(
             %{
               agent_uid: agent_uid,
               owner_session_id: Key.conversation(room_id),
               name: title,
               idempotency_key: "pod-cron:" <> request_id,
               schedule: Map.put(repeat, "kind", "cron"),
               delivery: %{
                 "targets" => [%{"conversation_id" => room_id}],
                 "quiet_success" => quiet_success?
               },
               payload: %{"task" => task}
             },
             authorization: WorkAccess.from_sender(Actor.uid(actor)),
             created_by: %{
               "kind" => "pod_jobs",
               "principal_uid" => actor.principal |> ActorRef.from_principal() |> to_string()
             }
           )
           |> normalize_cron_error(),
         {:ok, _} <-
           if(attrs.run_now == true,
             do:
               Schedule.run_cron_schedule(rule.id,
                 idempotency_key: "pod-cron-init:" <> request_id
               ),
             else: {:ok, nil}
           ) do
      Conversations.Events.publish_rooms_changed()
      fetch_card(actor, "cron:#{rule.id}")
    end
  end

  @doc "Pauses, resumes, runs now, or removes a Cron schedule, or cancels a checkback."
  def change_routine(%Actor{} = actor, kind, raw_id, action) do
    uid = Actor.uid(actor)

    case {normalize_routine_kind(kind), normalize_routine_action(action)} do
      {:cron, act} when act in [:pause, :resume, :run, :remove] ->
        with true <- Native.active_human?(actor),
             {:ok, %CronSchedule{human_uid: ^uid, owner_job_id: nil} = rule} <-
               Schedule.get_cron_schedule(raw_id),
             {:ok, _} <- apply_cron_action(rule.id, act) do
          Conversations.Events.publish_rooms_changed()
          {:ok, %{id: "cron:#{rule.id}", action: to_string(act)}}
        else
          _ -> {:error, :job_not_found}
        end

      {:checkback, :cancel} ->
        with true <- Native.active_human?(actor),
             {:ok, parsed_id} <- Ankole.ModelIntegerID.parse(raw_id),
             %ScheduledEvent{kind: "check_back_later", human_uid: ^uid} <-
               Schedule.Store.get_scheduled_event(parsed_id),
             {:ok, _} <- Schedule.cancel_checkback(parsed_id) do
          Conversations.Events.publish_rooms_changed()
          {:ok, %{id: "checkback:#{parsed_id}", action: "cancel"}}
        else
          _ -> {:error, :job_not_found}
        end

      _ ->
        {:error, :invalid_job}
    end
  end

  @doc "Stops a live BackgroundAgentJob or Workflow directly from `/jobs`."
  def stop_execution(%Actor{} = actor, kind, run_id)
      when kind in [:background_agent_job, :workflow, "background_agent_job", "workflow"] do
    exec_kind = if kind in [:workflow, "workflow"], do: :workflow, else: :background_agent_job

    Executions.stop_with_policy(actor, exec_kind, "Stopped from Pod Jobs board", fn ->
      case Queries.authorize_execution_read(actor, exec_kind, run_id) do
        {:ok, run, true} -> {:ok, run}
        {:ok, _run, false} -> {:error, :execution_not_found}
        error -> error
      end
    end)
  end

  def stop_execution(_actor, _kind, _run_id), do: {:error, :execution_not_found}

  @doc "Steers a live BackgroundAgentJob or respawns a terminal one from `/jobs`."
  def message_execution(%Actor{} = actor, run_id, request_id, text) do
    with {:ok, normalized_request_id} <- cast_uuid(request_id) do
      Executions.message_with_policy(actor, normalized_request_id, text, fn ->
        case Queries.authorize_execution_read(actor, :background_agent_job, run_id) do
          {:ok, %AgentJob{} = job, true} -> {:ok, job, job.reply_route || %{}}
          {:ok, _job, false} -> {:error, :execution_not_found}
          error -> error
        end
      end)
    end
  end

  defp resolve_one_off_route(_actor, _agent_uid, nil, request_id),
    do: {:ok, Key.pod_job(request_id), %{}}

  defp resolve_one_off_route(_actor, _agent_uid, "", request_id),
    do: {:ok, Key.pod_job(request_id), %{}}

  defp resolve_one_off_route(actor, agent_uid, conversation_id, _request_id) do
    with {:ok, room_id} <- validate_agent_room(actor, agent_uid, conversation_id) do
      {:ok, Key.conversation(room_id), %{"conversation_id" => room_id}}
    end
  end

  defp resolve_cron_delivery_room(actor, agent_uid, conversation_id)
       when conversation_id in [nil, ""] do
    Repo.transact_top_level(fn ->
      with {:ok, room} <- Conversations.ensure_agent_delivery_room_in_tx(actor, agent_uid) do
        {:ok, room.id}
      end
    end)
  end

  defp resolve_cron_delivery_room(actor, agent_uid, conversation_id),
    do: validate_agent_room(actor, agent_uid, conversation_id)

  defp validate_agent_room(actor, agent_uid, conversation_id) do
    with {:ok, id} <- cast_uuid(conversation_id),
         {:ok, room} <- Conversations.visible_native_conversation(actor, id),
         %{role: :agent} <- Conversations.get_participant!(room.id, agent_uid) do
      {:ok, room.id}
    else
      {:error, :conversation_not_found} -> {:error, :conversation_not_found}
      _ -> {:error, :invalid_job}
    end
  end

  defp authorize_optional_runner(_actor, _agent_uid, nil), do: {:ok, nil}
  defp authorize_optional_runner(_actor, _agent_uid, ""), do: {:ok, nil}

  defp authorize_optional_runner(actor, agent_uid, runner_id) do
    with {:ok, id} <- cast_uuid(runner_id),
         :ok <- AgentWorkers.authorize_runner_for_job(actor, agent_uid, id) do
      {:ok, id}
    else
      {:error, :runner_unavailable} -> {:error, :runner_unavailable}
      _ -> {:error, :invalid_job}
    end
  end

  defp validate_agent(actor, agent_uid) when is_binary(agent_uid) do
    uid = Actor.uid(actor)

    with {:ok, normalized} <- Principals.normalize_uid(agent_uid),
         {:ok, %{type: :agent, status: :active}} <- Principals.get_principal(normalized),
         :ok <- check_pa_ownership(uid, normalized),
         :ok <- Conversations.authorize_agent(actor, normalized) do
      {:ok, normalized}
    else
      {:error, :agent_unavailable} -> {:error, :agent_unavailable}
      _ -> {:error, :invalid_job}
    end
  end

  defp validate_agent(_actor, _), do: {:error, :invalid_job}

  defp check_pa_ownership(viewer_uid, agent_uid) do
    case Principals.get_agent_record!(agent_uid) do
      %{type: :personal_assistant, owner_principal_uid: owner} when owner != viewer_uid ->
        {:error, :invalid_job}

      _ ->
        :ok
    end
  end

  defp validate_title(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @title_limit,
      do: {:ok, trimmed},
      else: {:error, :invalid_job}
  end

  defp validate_title(_), do: {:error, :invalid_job}

  defp validate_task(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @task_limit,
      do: {:ok, trimmed},
      else: {:error, :invalid_job}
  end

  defp validate_task(_), do: {:error, :invalid_job}

  defp normalize_create_attrs(raw) do
    map = Map.new(raw, fn {k, v} -> {to_string(k), v} end)

    %{
      mode: map["mode"],
      title: map["title"],
      task: map["task"],
      agent_uid: map["agent_uid"] || map["agentUID"],
      request_id: map["request_id"] || map["requestID"],
      runner_id: map["runner_id"] || map["runnerID"],
      conversation_id: map["conversation_id"] || map["conversationID"],
      repeat: map["repeat"],
      quiet_success:
        if(Map.has_key?(map, "quiet_success"),
          do: map["quiet_success"],
          else: map["quietSuccess"]
        ),
      run_now: map["run_now"] || map["runNow"]
    }
  end

  defp validate_repeat(%{} = repeat) do
    map = Map.new(repeat, fn {k, v} -> {to_string(k), v} end)
    expression = map["expression"]
    timezone = map["timezone"]

    with true <- is_binary(expression) and is_binary(timezone),
         {:ok, schedule, _zone} <-
           Schedule.Planner.normalize_schedule_json(
             %{"kind" => "cron", "expression" => expression, "timezone" => timezone},
             %{},
             []
           ) do
      {:ok, schedule}
    else
      _ -> {:error, :invalid_job}
    end
  end

  defp validate_repeat(_), do: {:error, :invalid_job}

  defp apply_cron_action(id, :pause), do: Schedule.pause_cron_schedule(id)
  defp apply_cron_action(id, :resume), do: Schedule.resume_cron_schedule(id)
  defp apply_cron_action(id, :remove), do: Schedule.remove_cron_schedule(id)

  defp apply_cron_action(id, :run),
    do:
      Schedule.run_cron_schedule(id,
        idempotency_key: "pod-jobs-run:" <> Ankole.Ecto.UUIDv7.autogenerate()
      )

  defp fetch_card(actor, card_id) do
    with {:ok, %{items: items}} <- Queries.list(actor),
         %{} = card <- Enum.find(items, &(&1.id == card_id)) do
      {:ok, card}
    else
      _ -> {:error, :job_not_found}
    end
  end

  defp normalize_dispatch_error({:ok, _} = ok), do: ok

  defp normalize_dispatch_error({:error, reason}) do
    cond do
      reason in [:agent_unavailable, :runner_unavailable, :worker_runtime_not_configured] ->
        {:error, reason}

      match?({:model_profile_not_configured, _}, reason) or
        match?({:model_not_available, _}, reason) or
          reason in [:model_profile_unavailable, :no_available_model] ->
        {:error, :model_profile_unavailable}

      true ->
        {:error, :invalid_job}
    end
  end

  defp normalize_cron_error({:ok, _} = ok), do: ok

  defp normalize_cron_error({:error, :conversation_not_found}),
    do: {:error, :conversation_not_found}

  defp normalize_cron_error({:error, _}), do: {:error, :invalid_job}

  defp normalize_mode(mode) when mode in [:one_off, "one_off"], do: {:ok, :one_off}
  defp normalize_mode(mode) when mode in [:cron, "cron"], do: {:ok, :cron}
  defp normalize_mode(_), do: {:error, :invalid_job}

  defp normalize_routine_kind(kind) when kind in [:cron, "cron"], do: :cron
  defp normalize_routine_kind(kind) when kind in [:checkback, "checkback"], do: :checkback
  defp normalize_routine_kind(_), do: :invalid

  defp normalize_routine_action(a) when a in [:pause, "pause"], do: :pause
  defp normalize_routine_action(a) when a in [:resume, "resume"], do: :resume
  defp normalize_routine_action(a) when a in [:run, "run"], do: :run
  defp normalize_routine_action(a) when a in [:remove, "remove"], do: :remove
  defp normalize_routine_action(a) when a in [:cancel, "cancel"], do: :cancel
  defp normalize_routine_action(_), do: :invalid

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_job}
    end
  end

  defp cast_uuid(_), do: {:error, :invalid_job}
end
