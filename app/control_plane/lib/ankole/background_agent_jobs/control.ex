defmodule Ankole.BackgroundAgentJobs.Control do
  @moduledoc false

  import Ecto.Query

  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs.Attrs
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  @terminal_statuses Job.terminal_statuses()

  @spec request_stop(String.t(), map()) ::
          {:ok, %{job: Job.t(), command_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def request_stop(job_id, attrs)
      when is_binary(job_id) and is_map(attrs) do
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

  @spec request_steer(String.t(), map()) ::
          {:ok, %{job: Job.t(), command_event: ActorEvent.t()}}
          | {:error, term()}
  def request_steer(job_id, attrs)
      when is_binary(job_id) and is_map(attrs) do
    attrs = Attrs.normalize(attrs)
    answers = Map.get(attrs, "answers")

    with {:ok, agent_uid} <- Principals.normalize_uid(Attrs.text(attrs, "agent_uid")),
         :ok <- require_steer_input(Attrs.text(attrs, "text"), answers) do
      Repo.transact(fn repo ->
        with %Job{} = job <-
               Queries.get_for_agent(repo, job_id, agent_uid, lock: "FOR UPDATE"),
             :ok <- ensure_steerable(job),
             now <- now(),
             {:ok, job} <- queue_settled_continuation(repo, job, now),
             {:ok, command_event} <- append_command(repo, job, "steer", attrs, now) do
          {:ok, %{job: job, command_event: command_event}}
        else
          nil -> {:error, :job_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  defp stop_without_live_turn(repo, job, attrs, now) do
    metadata =
      job.metadata
      |> Kernel.||(%{})
      |> Map.merge(
        Attrs.reject_nil_values(%{
          "cancel_requested_by" => Attrs.text(attrs, "cancel_requested_by"),
          "cancel_reason" => Attrs.text(attrs, "reason")
        })
      )

    job
    |> Job.changeset(%{status: "stopped", completed_at: now, metadata: metadata})
    |> repo.update()
  end

  defp complete_pending_job_events(repo, job, now) do
    ActorEvent
    |> where([event], event.agent_uid == ^job.agent_uid)
    |> where([event], event.session_id == ^"job:#{job.id}")
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

  defp require_steer_input(text, answers)
       when is_binary(text) or (is_map(answers) and map_size(answers) > 0),
       do: :ok

  defp require_steer_input(_text, _answers),
    do: {:error, :background_agent_job_steer_input_missing}

  defp ensure_steerable(%Job{status: "stopped"}),
    do: {:error, :background_agent_job_terminal}

  defp ensure_steerable(%Job{status: status, runtime_thread_id: nil})
       when status in ["succeeded", "failed"],
       do: {:error, :background_agent_job_runtime_thread_unavailable}

  defp ensure_steerable(%Job{}), do: :ok

  defp queue_settled_continuation(repo, %Job{status: status} = job, now)
       when status in ["succeeded", "failed"] do
    job
    |> Job.changeset(%{status: "queued", queued_at: now, completed_at: nil})
    |> repo.update()
  end

  defp queue_settled_continuation(_repo, %Job{} = job, _now),
    do: {:ok, job}

  defp append_command(repo, job, command, attrs, now) do
    reply_route = job.reply_route || %{}
    request_id = Attrs.text(attrs, "request_id") || Ecto.UUID.generate()
    args_text = Attrs.text(attrs, "text") || Attrs.text(attrs, "reason") || command

    command_data =
      Attrs.reject_nil_values(%{
        "argsText" => args_text,
        "answers" => map_or_nil(Map.get(attrs, "answers")),
        "cancel_requested_by" => Attrs.text(attrs, "cancel_requested_by")
      })

    SignalsGateway.append_actor_event_in_tx(repo, %{
      agent_uid: job.agent_uid,
      binding_name: Map.fetch!(reply_route, "binding_name"),
      session_id: "job:#{job.id}",
      source_event_id: "background_agent_job:#{job.id}:#{command}:#{request_id}",
      signal_channel_id: Map.get(reply_route, "signal_channel_id"),
      provider_thread_id: Map.get(reply_route, "provider_thread_id"),
      source_entry_id: Map.get(reply_route, "source_entry_id"),
      type: "command.#{command}",
      available_at: now,
      payload: %{
        "type" => "command.#{command}",
        "data" => %{"command" => command_data}
      }
    })
  end

  defp map_or_nil(value) when is_map(value) and map_size(value) > 0, do: value
  defp map_or_nil(_value), do: nil
  defp now, do: DateTime.utc_now(:microsecond)
end
