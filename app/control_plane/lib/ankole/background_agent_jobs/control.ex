defmodule Ankole.BackgroundAgentJobs.Control do
  @moduledoc false

  import Ecto.Query

  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Turns

  @terminal_statuses Job.terminal_statuses()

  @spec request_stop(pos_integer(), map()) ::
          {:ok, %{job: Job.t(), command_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def request_stop(job_id, attrs)
      when is_integer(job_id) and job_id > 0 and is_map(attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")) do
      now = now()

      Repo.transact(fn repo ->
        case Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE") do
          %Job{status: status} = job when status in @terminal_statuses ->
            {:ok, %{job: job, command_event: nil}}

          %Job{status: status} = job when status in ["queued", "waiting_on_user"] ->
            with {:ok, job} <- stop_without_live_turn(repo, job, attrs, now),
                 :ok <- complete_pending_job_events(repo, job, now),
                 :ok <- Lifecycle.nudge_queued_after_slot_release(repo, job, now) do
              {:ok, %{job: job, command_event: nil}}
            end

          %Job{} = job ->
            with {:ok, job} <- stop_without_live_turn(repo, job, attrs, now),
                 :ok <- Lifecycle.nudge_queued_after_slot_release(repo, job, now),
                 {:ok, command_event} <- append_command(repo, job, "stop", attrs, now) do
              {:ok, %{job: job, command_event: command_event}}
            end

          nil ->
            {:error, :job_not_found}
        end
      end)
    end
  end

  @doc """
  Commits an externally verified completion for a live Job.

  The caller owns the outcome judgment: the commit skips the worker deliverable
  contract, records the caller's result summary, and produces the ordinary
  succeeded wakeup. A running Job also receives a runtime stop command so the
  Worker does not keep executing a Turn whose Job is already terminal. Open
  steers close with the completion itself; an external completion never seeds a
  successor.
  """
  @spec request_complete(pos_integer(), map()) ::
          {:ok, %{job: Job.t(), command_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def request_complete(job_id, attrs)
      when is_integer(job_id) and job_id > 0 and is_map(attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         {:ok, summary} <- require_result_summary(attrs) do
      now = now()

      Repo.transact(fn repo ->
        case Queries.get_for_agent(repo, job_id, agent_uid, []) do
          nil ->
            {:error, :job_not_found}

          %Job{status: "succeeded"} = job ->
            {:ok, %{job: job, command_event: nil}}

          %Job{status: status} when status in ["failed", "stopped"] ->
            {:error, :background_agent_job_terminal}

          %Job{status: pre_status} ->
            completed_by = Attrs.text(attrs, "completed_by")

            result =
              Attrs.reject_nil_values(%{
                "summary" => summary,
                "completed_by" => completed_by
              })

            with {:ok, %{job: job}} <-
                   Lifecycle.commit_status_with_wakeup_in_tx(
                     repo,
                     job_id,
                     agent_uid,
                     %{"status" => "succeeded", "result" => result},
                     now,
                     nil,
                     nil,
                     %{
                       "code" => "background_agent_job_succeeded",
                       "summary" =>
                         "The Job was completed externally before this runtime Turn reported completion."
                     },
                     external_completion: true
                   ),
                 {:ok, command_event} <-
                   maybe_append_runtime_stop(repo, job, pre_status, attrs, now) do
              {:ok, %{job: job, command_event: command_event}}
            end
        end
      end)
    end
  end

  defp require_result_summary(attrs) do
    case Attrs.text(attrs, "result_summary") do
      summary when is_binary(summary) -> {:ok, summary}
      nil -> {:error, :background_agent_job_result_summary_missing}
    end
  end

  defp maybe_append_runtime_stop(repo, job, "running", attrs, now) do
    append_command(
      repo,
      job,
      "stop",
      Map.put(attrs, "reason", "background_agent_job_completed_externally"),
      now
    )
  end

  defp maybe_append_runtime_stop(_repo, _job, _pre_status, _attrs, _now), do: {:ok, nil}

  @spec send_message(pos_integer(), map()) ::
          {:ok, %{job: Job.t(), command_event: ActorEvent.t()}}
          | {:error, term()}
  def send_message(job_id, attrs)
      when is_integer(job_id) and job_id > 0 and is_map(attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         {:ok, source_tool_call_id} <- require_source_tool_call_id(attrs),
         {:ok, message} <- require_message(Map.get(attrs, "message")) do
      Repo.transact(fn repo ->
        with %Job{} = job <-
               Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
             :ok <- ensure_messageable(job),
             now <- now(),
             {:ok, job} <- touch_job(repo, job, now),
             {:ok, command_event} <-
               append_command(
                 repo,
                 job,
                 "steer",
                 attrs
                 |> Map.put("request_id", source_tool_call_id)
                 |> Map.put("text", message),
                 now
               ) do
          {:ok, %{job: job, command_event: command_event}}
        else
          nil -> {:error, :job_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  @doc false
  @spec lock_ambient_handoff_target_in_tx(
          module(),
          String.t(),
          pos_integer()
        ) :: Job.t() | nil
  def lock_ambient_handoff_target_in_tx(repo, agent_uid, job_id)
      when is_binary(agent_uid) and is_integer(job_id) and job_id > 0 do
    Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE")
  end

  @doc false
  @spec handoff_ambient_message_in_tx(
          module(),
          ActorEvent.t(),
          Job.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, %{job: Job.t(), command_event: ActorEvent.t()}} | {:error, term()}
  def handoff_ambient_message_in_tx(
        repo,
        %ActorEvent{} = source_event,
        %Job{} = job,
        message,
        %DateTime{} = now
      ) do
    with {:ok, message} <- require_message(message),
         :ok <- ensure_ambient_handoff_target(job, source_event),
         :ok <- ensure_messageable(job),
         {:ok, job} <- touch_job(repo, job, now),
         {:ok, command_event} <-
           append_command(
             repo,
             job,
             "steer",
             %{
               "request_id" => "ambient-handoff:#{source_event.id}",
               "text" => message
             },
             now
           ) do
      {:ok, %{job: job, command_event: command_event}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp ensure_ambient_handoff_target(%Job{} = job, %ActorEvent{} = event) do
    reply_route = job.reply_route || %{}
    metadata = job.metadata || %{}

    cond do
      job.agent_uid != event.agent_uid ->
        {:error, :background_agent_job_ambient_agent_mismatch}

      job.owner_session_id != event.session_id ->
        {:error, :background_agent_job_ambient_session_mismatch}

      Map.get(reply_route, "signal_channel_id") != event.signal_channel_id ->
        {:error, :background_agent_job_ambient_channel_mismatch}

      Map.get(reply_route, "binding_name") != event.binding_name ->
        {:error, :background_agent_job_ambient_binding_mismatch}

      Map.get(metadata, "skill_lesson_reflection") == true ->
        {:error, :background_agent_job_ambient_target_hidden}

      true ->
        :ok
    end
  end

  defp stop_without_live_turn(repo, job, attrs, now) do
    metadata =
      job.metadata
      |> Kernel.||(%{})
      |> Map.delete("pending_user_input")
      |> Map.merge(
        Attrs.reject_nil_values(%{
          "cancel_requested_by" => Attrs.text(attrs, "cancel_requested_by"),
          "cancel_reason" => Attrs.text(attrs, "reason")
        })
      )

    with :ok <-
           Turns.interrupt_active_for_current_attempt_in_tx(
             repo,
             job,
             %{
               "code" => "background_agent_job_stopped",
               "summary" => "The Job stopped before this runtime Turn reported completion."
             },
             now
           ) do
      job
      |> Job.changeset(%{status: "stopped", completed_at: now, metadata: metadata})
      |> repo.update()
    end
  end

  defp complete_pending_job_events(repo, job, now) do
    ActorEvent
    |> where([event], event.agent_uid == ^job.agent_uid)
    |> where([event], event.session_id == ^BackgroundAgentJobs.job_session_id(job.id))
    |> where([event], event.type in ["background_agent_job.dispatch", "command.steer"])
    |> where([event], is_nil(event.completed_at))
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case SignalsGateway.mark_actor_event_completed_in_tx(repo, event, now) do
        {:ok, %ActorEvent{}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_source_tool_call_id(attrs) do
    case Attrs.text(attrs, "request_id") do
      source_tool_call_id when is_binary(source_tool_call_id) -> {:ok, source_tool_call_id}
      nil -> {:error, :background_agent_job_source_tool_call_id_missing}
    end
  end

  defp require_message(message) when is_binary(message) do
    if String.trim(message) == "",
      do: {:error, :background_agent_job_message_missing},
      else: {:ok, message}
  end

  defp require_message(_message), do: {:error, :background_agent_job_message_missing}

  defp ensure_messageable(%Job{status: status}) when status in @terminal_statuses,
    do: {:error, {:background_agent_job_message_status_invalid, status}}

  defp ensure_messageable(%Job{}), do: :ok

  defp touch_job(repo, %Job{} = job, now) do
    job
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:updated_at, now)
    |> repo.update()
  end

  defp append_command(repo, job, command, attrs, now) do
    reply_route = job.reply_route || %{}
    request_id = Attrs.text(attrs, "request_id") || Ecto.UUID.generate()

    args_text =
      if command == "steer",
        do: Map.fetch!(attrs, "text"),
        else: Attrs.text(attrs, "reason") || command

    command_data =
      Attrs.reject_nil_values(%{
        "argsText" => args_text,
        "cancel_requested_by" => Attrs.text(attrs, "cancel_requested_by")
      })

    SignalsGateway.append_actor_event_in_tx(repo, %{
      agent_uid: job.agent_uid,
      binding_name: Map.fetch!(reply_route, "binding_name"),
      session_id: BackgroundAgentJobs.job_session_id(job.id),
      source_event_id: "background_agent_job:#{job.id}:#{command}:#{request_id}",
      signal_channel_id: Map.get(reply_route, "signal_channel_id"),
      provider_thread_id: Map.get(reply_route, "provider_thread_id"),
      type: "command.#{command}",
      available_at: now,
      payload: %{
        "type" => "command.#{command}",
        "data" => %{"command" => command_data}
      }
    })
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
