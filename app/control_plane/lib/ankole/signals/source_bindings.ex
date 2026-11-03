defmodule Ankole.Signals.SourceBindings do
  @moduledoc "The default Binding managed by a built-in source's create and edit flow."
  require Ash.Query
  alias Ankole.Signals.Binding

  def reference(%{schedule: _, id: id}), do: "schedule://#{id}"
  def reference(%{kind: "cron_fire", cron_schedule_id: id}), do: "schedule://#{id}"
  def reference(%{kind: "check_back_later", id: id}), do: "scheduled-event://#{id}"
  def reference(%{event_format: _, id: id}), do: "webhook-endpoint://#{id}"

  def job_id(source) do
    reference = if is_binary(source), do: source, else: reference(source)

    case default(reference) do
      nil -> nil
      binding -> binding.automation_job_id
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
      [additional_job_id | Enum.map(bindings, & &1.automation_job_id)]
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

  defp default(reference),
    do:
      Binding
      |> Ash.Query.filter(config_ref == ^reference and name == ^("source:" <> reference))
      |> Ankole.Ash.read_one!()
end
