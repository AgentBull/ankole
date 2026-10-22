defmodule Ankole.BackgroundAgentJobs.Control do
  @moduledoc false

  require Ankole.ModelIntegerID

  alias Ankole.Signals.Signal
  alias Ankole.Principals
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Dispatch
  alias Ankole.BackgroundAgentJobs.JobState
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.BackgroundAgentJobs.WorkerWait
  alias Ankole.Sessions.JobTurnRef

  @doc "Requests cancellation inside the `request_stop` action of the Job."
  @spec request_stop_in_tx(module(), pos_integer(), map()) ::
          {:ok, %{job: Job.t(), turn: JobTurnRef.t() | nil}}
          | {:error, term()}
  def request_stop_in_tx(repo, job_id, attrs)
      when Ankole.ModelIntegerID.valid?(job_id) and is_map(attrs) do
    with {:ok, sessions, commit} <- prepare_stop_in_tx(repo, job_id, attrs),
         :ok <- Ankole.Sessions.Queue.lock_sessions_in_tx(repo, sessions),
         do: commit.()
  end

  def prepare_stop_in_tx(repo, job_id, attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         :ok <- Lifecycle.lock_agent_slots(repo, agent_uid),
         %Job{} = job <- Queries.lock_for_agent_in_tx(job_id, agent_uid),
         :ok <- Turns.lock_active_for_current_attempt_in_tx(job) do
      {:ok, job_sessions(job), fn -> request_stop_locked_in_tx(repo, job, attrs, now()) end}
    else
      nil -> {:error, :job_not_found}
      {:error, _} = error -> error
    end
  end

  defp request_stop_locked_in_tx(repo, %Job{} = job, attrs, now) do
    cond do
      job.status in JobState.terminal_statuses() ->
        {:ok, %{job: job, turn: nil}}

      job.status in [:queued, :waiting_on_user] ->
        with {:ok, job} <- stop_without_live_turn(repo, job, attrs, now),
             {:ok, :ok} <-
               Dispatch.complete_all_open_events_in_tx(repo, job.id, job.agent_uid, now) do
          {:ok, %{job: job, turn: nil}}
        end

      true ->
        turn = live_turn_ref_in_tx(repo, job)

        with {:ok, job} <- stop_without_live_turn(repo, job, attrs, now) do
          {:ok, %{job: job, turn: turn}}
        end
    end
  end

  @doc """
  Commits an externally verified completion for a live Job.

  The caller owns the outcome judgment: the commit skips the worker deliverable
  contract, records the caller's result summary, and produces the ordinary
  succeeded wakeup. The caller sends a stop to the returned Turn after commit. Open
  steers close with the completion itself; an external completion never seeds a
  successor.
  """
  @spec request_complete_in_tx(module(), pos_integer(), map()) ::
          {:ok, %{job: Job.t(), turn: JobTurnRef.t() | nil}}
          | {:error, term()}
  def request_complete_in_tx(repo, job_id, attrs)
      when Ankole.ModelIntegerID.valid?(job_id) and is_map(attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         {:ok, summary} <- require_result_summary(attrs) do
      case Queries.get_for_agent(job_id, agent_uid) do
        nil ->
          {:error, :job_not_found}

        %Job{status: :succeeded} = job ->
          {:ok, %{job: job, turn: nil}}

        %Job{status: status} when status in [:failed, :stopped] ->
          {:error, :background_agent_job_terminal}

        %Job{status: pre_status} = job ->
          turn = if pre_status == :running, do: live_turn_ref_in_tx(repo, job)

          result =
            Attrs.reject_nil_values(%{
              "summary" => summary,
              "completed_by" => Attrs.text(attrs, "completed_by")
            })

          with {:ok, %{job: job, wakeup_event: wakeup_event}} <-
                 Lifecycle.commit_status_with_wakeup_in_tx(
                   repo,
                   job_id,
                   agent_uid,
                   %{"status" => :succeeded, "result" => result},
                   now(),
                   nil,
                   nil,
                   %{
                     "code" => "background_agent_job_succeeded",
                     "summary" =>
                       "The Job was completed externally before this runtime Turn reported completion."
                   },
                   transition_action: :external_complete
                 ) do
            {:ok, %{job: job, turn: turn, wakeup_event: wakeup_event}}
          end
      end
    end
  end

  defp require_result_summary(attrs) do
    case Attrs.text(attrs, "result_summary") do
      summary when is_binary(summary) -> {:ok, summary}
      nil -> {:error, :background_agent_job_result_summary_missing}
    end
  end

  @spec send_message_in_tx(module(), pos_integer(), map()) ::
          {:ok, %{job: Job.t(), command_event: Signal.t()}}
          | {:error, term()}
  def send_message_in_tx(repo, job_id, attrs)
      when Ankole.ModelIntegerID.valid?(job_id) and is_map(attrs) do
    with {:ok, sessions, commit} <- prepare_message_in_tx(repo, job_id, attrs),
         :ok <- Ankole.Sessions.Queue.lock_sessions_in_tx(repo, sessions),
         do: commit.()
  end

  def prepare_message_in_tx(repo, job_id, attrs) do
    attrs = Attrs.normalize(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         {:ok, request_id} <- require_source_tool_call_id(attrs),
         {:ok, message} <- require_message(Map.get(attrs, "message")),
         %Job{} = job <- Queries.lock_for_agent_in_tx(job_id, agent_uid),
         :ok <- ensure_messageable(job) do
      {:ok, job_sessions(job),
       fn ->
         now = now()

         with {:ok, job} <- JobState.touch_in_tx(job, now),
              {:ok, command_event} <-
                append_steer(
                  repo,
                  job,
                  attrs |> Map.put("request_id", request_id) |> Map.put("text", message),
                  now
                ),
              do: {:ok, %{job: job, command_event: command_event}}
       end}
    else
      nil -> {:error, :job_not_found}
      {:error, _} = error -> error
    end
  end

  defp job_sessions(job),
    do: [
      {job.agent_uid, job.owner_session_id},
      {job.agent_uid, BackgroundAgentJobs.job_session_id(job.id)}
    ]

  @doc false
  @spec lock_ambient_handoff_target_in_tx(
          module(),
          String.t(),
          pos_integer()
        ) :: Job.t() | nil
  def lock_ambient_handoff_target_in_tx(_repo, agent_uid, job_id)
      when is_binary(agent_uid) and Ankole.ModelIntegerID.valid?(job_id),
      do: Queries.lock_for_agent_in_tx(job_id, agent_uid)

  @doc false
  @spec handoff_ambient_message_in_tx(
          module(),
          Signal.t(),
          Job.t(),
          String.t(),
          DateTime.t()
        ) :: {:ok, %{job: Job.t(), command_event: Signal.t()}} | {:error, term()}
  def handoff_ambient_message_in_tx(
        repo,
        %Signal{} = source_event,
        %Job{} = job,
        message,
        %DateTime{} = now
      ) do
    with {:ok, message} <- require_message(message),
         :ok <- ensure_ambient_handoff_target(job, source_event),
         :ok <- ensure_messageable(job),
         {:ok, job} <- JobState.touch_in_tx(job, now),
         {:ok, command_event} <-
           append_steer(
             repo,
             job,
             %{
               "request_id" => "ambient-handoff:#{source_event.id}",
               "source_signal_id" => source_event.id,
               "text" => message
             },
             now
           ) do
      {:ok, %{job: job, command_event: command_event}}
    else
      {:error, _reason} = error -> error
    end
  end

  defp ensure_ambient_handoff_target(%Job{} = job, %Signal{} = event) do
    reply_route = job.reply_route || %{}
    metadata = job.metadata || %{}

    cond do
      job.agent_uid != event.agent_uid ->
        {:error, :background_agent_job_ambient_agent_mismatch}

      job.owner_session_id != event.session_id ->
        {:error, :background_agent_job_ambient_session_mismatch}

      Map.get(reply_route, "conversation_id") != event.conversation_id ->
        {:error, :background_agent_job_ambient_channel_mismatch}

      Map.get(reply_route, "binding_name") != event.reply_binding_name ->
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

    with {:ok, stopped} <-
           Ankole.Errors.reason(
             Ankole.Ash.update(
               job,
               :stop,
               WorkerWait.clear(%{completed_at: now, metadata: metadata})
             )
           ),
         :ok <-
           Turns.interrupt_active_for_current_attempt_in_tx(
             repo,
             job,
             %{
               "code" => "background_agent_job_stopped",
               "summary" => "The Job stopped before this runtime Turn reported completion."
             },
             now
           ) do
      {:ok, stopped}
    end
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

  defp ensure_messageable(%Job{status: status}) do
    if status in JobState.terminal_statuses(),
      do: {:error, {:background_agent_job_message_status_invalid, status}},
      else: :ok
  end

  defp live_turn_ref_in_tx(repo, job) do
    event =
      Ankole.Sessions.Queue.oldest_started(
        repo,
        job.agent_uid,
        BackgroundAgentJobs.job_session_id(job.id)
      )

    if event,
      do: %JobTurnRef{
        agent_uid: job.agent_uid,
        session_id: event.session_id,
        signal_id: event.id,
        job_id: job.id,
        attempt: job.attempts
      }
  end

  defp append_steer(repo, job, attrs, now) do
    reply_route = job.reply_route || %{}
    request_id = Attrs.text(attrs, "request_id") || Ecto.UUID.generate()
    command_data = %{"argsText" => Map.fetch!(attrs, "text")}

    Ankole.Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: "control-plane://background-agent-job",
      id: "background_agent_job:#{job.id}:steer:#{request_id}",
      type: "command.steer",
      subject: "background-agent-job:#{job.id}",
      time: now,
      available_at: now,
      target: %{agent_uid: job.agent_uid, session_id: BackgroundAgentJobs.job_session_id(job.id)},
      sender: nil,
      authorization: Ankole.Principals.WorkAccess.fields(job),
      reply_route: %{
        binding_name: Map.get(reply_route, "binding_name"),
        conversation_id: Map.get(reply_route, "conversation_id"),
        provider_thread_id: Map.get(reply_route, "provider_thread_id"),
        provider_message_id: nil
      },
      data:
        Attrs.reject_nil_values(%{
          "command" => command_data,
          "source_signal_id" => Attrs.text(attrs, "source_signal_id")
        })
    })
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
