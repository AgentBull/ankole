defmodule Ankole.Signals.SourceBindings do
  @moduledoc "The default Binding managed by a built-in source's create and edit flow."
  require Ash.Query
  alias Ankole.Signals.Binding

  def reference(%{schedule: _, id: id}), do: "schedule://#{id}"
  def reference(%{kind: "cron_fire", cron_schedule_id: id}), do: "schedule://#{id}"
  def reference(%{kind: "check_back_later", id: id}), do: "scheduled-event://#{id}"
  def reference(%{event_format: _, id: id}), do: "webhook-endpoint://#{id}"

  def job_id(source) do
    case default(source) do
      nil -> nil
      binding -> binding.automation_job_id
    end
  end

  def routing_mode(source) do
    case default(source) do
      nil -> nil
      binding -> binding.routing_mode
    end
  end

  def job_ids(sources) do
    references = Enum.map(sources, &reference/1)

    jobs =
      Binding
      |> Ash.Query.filter(config_ref in ^references)
      |> Ash.Query.select([:config_ref, :name, :automation_job_id])
      |> Ankole.Ash.read!()
      |> Enum.filter(&(&1.name == "source:" <> &1.config_ref))
      |> Map.new(&{&1.config_ref, &1.automation_job_id})

    Enum.map(references, &Map.get(jobs, &1))
  end

  def lock_in_tx(reference, additional_job_id \\ nil) do
    bindings =
      Binding
      |> Ash.Query.filter(config_ref == ^reference)
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read!()

    ids =
      (List.wrap(additional_job_id) ++ Enum.map(bindings, & &1.automation_job_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(ids, &Ankole.AutomationJobs.lock_job_in_tx/1)
    binding_ids = Enum.map(bindings, & &1.id)

    Binding
    |> Ash.Query.filter(id in ^binding_ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {"signal_bindings", binding_ids})

    :ok
  end

  def put_in_tx(reference, uid, session_id, job_id) do
    previous = default(reference)

    attrs = %{
      id: if(previous, do: previous.id, else: Ash.UUIDv7.generate()),
      name: "source:#{reference}",
      adapter: "internal",
      config_ref: reference,
      routing_mode: if(job_id, do: :action, else: :ai_colleague),
      automation_job_id: job_id,
      agent_uid: if(is_nil(job_id), do: uid),
      target: if(is_nil(job_id), do: %{"session_id" => session_id}, else: %{})
    }

    with {:ok, _} <- Ankole.Ash.create(Binding, :put, attrs), do: :ok
  end

  def remove_disabled_source_bindings_in_tx(reference) do
    if Binding
       |> Ash.Query.filter(config_ref == ^reference and enabled)
       |> Ankole.Ash.exists?() do
      {:error, :signal_source_in_use}
    else
      with {:ok, _} <-
             Binding
             |> Ash.Query.filter(config_ref == ^reference)
             |> Ankole.Ash.destroy_where(:remove, %{}),
           do: :ok
    end
  end

  defp default(source) do
    reference = if is_binary(source), do: source, else: reference(source)

    Binding
    |> Ash.Query.filter(config_ref == ^reference and name == ^("source:" <> reference))
    |> Ankole.Ash.read_one!()
  end

  def deliveries(reference) when is_binary(reference),
    do: Map.fetch!(deliveries([reference]), reference)

  def deliveries([]), do: %{}

  def deliveries(references) when is_list(references) do
    recent =
      Ankole.Signals.BindingReceipt
      |> Ash.Query.sort(received_at: :desc)
      |> Ash.Query.limit(100)

    receipts =
      Binding
      |> Ash.Query.filter(config_ref in ^references)
      |> Ash.Query.select([:config_ref])
      |> Ash.Query.load(receipts: recent)
      |> Ankole.Ash.read!()
      |> Enum.group_by(& &1.config_ref, & &1.receipts)
      |> Map.new(fn {reference, groups} ->
        # A source's newest 100 receipts are contained in its bindings' newest 100.
        recent = groups |> List.flatten() |> Enum.sort_by(& &1.received_at, {:desc, DateTime})
        {reference, Enum.take(recent, 100)}
      end)

    run_ids =
      receipts
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.automation_job_run_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    runs =
      case run_ids do
        [] ->
          %{}

        ids ->
          {:ok, runs} =
            Ankole.AutomationJobs.list_automation_job_runs(
              query: [filter: [id: [in: ids]], select: [:id, :status, :event]]
            )

          Map.new(runs, &{&1.id, &1})
      end

    Map.new(references, fn reference ->
      {reference, Enum.map(Map.get(receipts, reference, []), &delivery(&1, runs))}
    end)
  end

  defp delivery(receipt, runs) do
    run = runs[receipt.automation_job_run_id]

    %{
      source_event_id: receipt.source_event_id,
      received_at: receipt.received_at,
      automation_job_run_id: receipt.automation_job_run_id,
      run_status: run && run.status,
      coalesced:
        not is_nil(run) and
          {run.event["source"], run.event["id"]} != {receipt.source, receipt.source_event_id}
    }
  end

  def for_jobs(job_ids, references) do
    Binding
    |> Ash.Query.filter(automation_job_id in ^job_ids or config_ref in ^references)
    |> Ankole.Ash.read!()
  end

  def purge_in_tx(ids) do
    Binding
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "signal_bindings", :id})

    with {:ok, _} <-
           Ankole.Signals.BindingReceipt
           |> Ash.Query.filter(binding_id in ^ids)
           |> Ankole.Ash.destroy_where(:expire),
         {:ok, _} <- Binding |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.destroy_where(:remove),
         do: :ok
  end
end
