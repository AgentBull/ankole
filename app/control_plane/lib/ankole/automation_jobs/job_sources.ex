defmodule Ankole.AutomationJobs.JobSources do
  @moduledoc "Job-owned schedules and webhook endpoints share the Job's Page and work authorization."
  require Ash.Query
  alias Ankole.{AutomationJobs, Pod, Repo}
  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.Principals.WorkAccess

  def schedules(actor, page_id, job_id, operation, attrs \\ %{}) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    source =
      if operation in [:resume, :run] and is_binary(attrs["id"]) do
        case Ankole.Schedule.get_cron_schedule(attrs["id"]) do
          {:ok, source} -> source
          {:error, _} -> nil
        end
      end

    operate(
      actor,
      page_id,
      job_id,
      operation,
      fn job ->
        Ankole.Schedule.job_source_operation_in_tx(
          job,
          operation,
          Map.put(attrs, "created_by", %{
            "kind" => "pod",
            "principal_uid" => to_string(Ankole.ActorRef.from_principal(actor.principal))
          })
        )
      end,
      source
    )
  end

  def webhooks(actor, page_id, job_id, operation, attrs \\ %{}) do
    operate(actor, page_id, job_id, operation, fn job ->
      Ankole.Signals.job_webhook_operation_in_tx(
        job,
        operation,
        Ankole.Attrs.normalize_external_attrs(attrs)
      )
    end)
  end

  defp operate(actor, page_id, id, operation, fun, source \\ nil)

  defp operate(actor, page_id, id, operation, fun, _source) when operation in [:list, :runs] do
    with {:ok, %Job{} = job} <- AutomationJobs.get_automation_job(id),
         :ok <- AutomationJobs.authorize_applet_job(actor, job, page_id, "node_view"),
         do: fun.(job),
         else: (
           {:ok, nil} -> {:error, :not_found}
           error -> error
         )
  end

  defp operate(actor, page_id, id, _operation, fun, source) do
    with {:ok, %Job{} = snapshot} <- AutomationJobs.get_automation_job(id) do
      Repo.transact_top_level(fn ->
        with :ok <- WorkAccess.lock_authorizers_in_tx([snapshot, source]),
             :ok <- WorkAccess.check_in_tx(snapshot),
             :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority, lock: false),
             %Job{} = job <- AutomationJobs.lock_job_in_tx(id),
             :ok <-
               AutomationJobs.authorize_applet_job(
                 actor,
                 job,
                 page_id,
                 permission(job)
               ),
             true <- job.status == :active,
             {:ok, result} <- fun.(job),
             :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
             do: {:ok, result},
             else: (
               nil -> {:error, :not_found}
               false -> {:error, :automation_job_not_active}
               error -> error
             )
      end)
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp permission(%{authorization_kind: "human"}), do: "node_contribute"
  defp permission(_), do: "node_edit"

  def purge_in_tx(job_ids) do
    schedule_ids = Ankole.Schedule.job_source_ids(job_ids)
    endpoint_ids = Ankole.Signals.job_webhook_ids(job_ids)

    references =
      Enum.map(schedule_ids, &"schedule://#{&1}") ++
        Enum.map(endpoint_ids, &"webhook-endpoint://#{&1}") ++ Enum.map(job_ids, &"job://#{&1}")

    bindings = Ankole.Signals.bindings_for_jobs(job_ids, references)

    consumer_ids =
      (job_ids ++ Enum.map(bindings, & &1.automation_job_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(consumer_ids, &AutomationJobs.lock_job_in_tx/1)
    binding_ids = Enum.map(bindings, & &1.id)

    # Source creation and subscription edits lock the owning Job. Recheck the
    # snapshot after waiting for those writers before removing its dependents.
    unchanged =
      Enum.sort(schedule_ids) == Enum.sort(Ankole.Schedule.job_source_ids(job_ids)) and
        Enum.sort(endpoint_ids) == Enum.sort(Ankole.Signals.job_webhook_ids(job_ids)) and
        binding_targets(bindings) ==
          binding_targets(Ankole.Signals.bindings_for_jobs(job_ids, references))

    with true <- unchanged,
         :ok <- Ankole.Signals.purge_source_bindings_in_tx(binding_ids),
         :ok <- Ankole.Signals.purge_job_webhooks_in_tx(endpoint_ids),
         :ok <- Ankole.Schedule.purge_job_sources_in_tx(schedule_ids),
         {:ok, _} <-
           Ankole.AutomationJobs.Schemas.Run
           |> Ash.Query.filter(automation_job_id in ^job_ids)
           |> Ankole.Ash.destroy_where(:remove),
         {:ok, _} <-
           Ankole.AutomationJobs.Schemas.State
           |> Ash.Query.filter(automation_job_id in ^job_ids)
           |> Ankole.Ash.destroy_where(:remove),
         {:ok, _} <- Job |> Ash.Query.filter(id in ^job_ids) |> Ankole.Ash.destroy_where(:remove),
         do: :ok,
         else: (
           false -> {:error, :job_sources_changed}
           error -> error
         )
  end

  defp binding_targets(bindings),
    do: bindings |> Enum.map(&{&1.id, &1.automation_job_id}) |> Enum.sort()

  def live?(%{owner_job_id: id}) when is_integer(id) do
    case AutomationJobs.get_automation_job(id) do
      {:ok, %Job{status: :active, page_id: page_id}} -> Pod.page_live?(page_id)
      _ -> false
    end
  end

  def live?(_), do: true
end
