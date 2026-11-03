defmodule Ankole.AutomationJobs.Emission do
  @moduledoc "Fenced script events fan out through the Job's source Bindings."
  alias Ankole.{AutomationJobs, Repo, Signals}
  alias Ankole.AutomationJobs.AttemptRef

  def emit(uid, run_id, attempt_id, payload, now) do
    with {:ok, uid} <- Ankole.PrincipalKey.normalize(uid),
         %{automation_job_id: job_id} <- AutomationJobs.get_run_record(run_id),
         {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(job_id),
         {:ok, payload} <- normalize(payload),
         {:ok, plan} <- prepare(job, run_id, payload, now) do
      Repo.transact_top_level(
        fn ->
          with {:ok, plan} <- Signals.lock_dispatch_in_tx(plan, [job]),
               {:ok, _} <-
                 AutomationJobs.authorize_attempt_actor_in_tx(
                   %AttemptRef{
                     job_id: job.id,
                     run_id: run_id,
                     attempt_id: attempt_id,
                     agent_uid: uid
                   },
                   %{worker_id: uid}
                 ),
               {:ok, delivery} <- Signals.deliver_dispatch_in_tx(plan) do
            {:ok, delivery.signals}
          end
        end,
        after_commit: &Signals.publish_committed/1
      )
      |> case do
        {:ok, signals} -> {:ok, Enum.find(signals, &(&1.agent_uid == uid))}
        error -> error
      end
    else
      nil -> {:error, :automation_job_run_not_found}
      {:ok, nil} -> {:error, :automation_job_run_not_found}
      error -> error
    end
  end

  defp prepare(job, run_id, payload, now) do
    Signals.prepare_dispatch(
      "job://#{job.id}",
      %{
        id: "automation-job:#{job.id}:run:#{run_id}:#{Ash.UUIDv7.generate()}",
        type: "automation_job.emitted",
        subject: "automation_job_run:#{run_id}",
        time: DateTime.to_iso8601(now),
        data: %{
          "automation_job" => %{"id" => job.id, "label" => job.label},
          "automation_job_run_id" => run_id,
          "payload" => payload
        }
      },
      authorization: Ankole.Principals.WorkAccess.fields(job),
      reply_route: job.reply_route
    )
  end

  defp normalize(payload) do
    with {:ok, payload} <- Ankole.Ecto.JSONPayload.normalize(payload),
         true <- byte_size(Ankole.JSON.encode!(payload)) <= 1_048_576,
         do: {:ok, payload},
         else: (
           false -> {:error, :automation_job_payload_too_large}
           error -> error
         )
  end
end
