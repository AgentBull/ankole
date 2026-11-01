defmodule Ankole.Work.Owner do
  @moduledoc """
  Resolves each durable work kind to its domain and authorization contract.

  Each work resource declares its contract with `use Ankole.Work.Provenance`.
  This registry reads and locks work rows through Ash. A read across tenants
  uses the `:work_across_tenants` action that the contract declares.
  """

  require Ash.Query

  defp parent_schemas do
    [
      Ankole.AutomationJobs.Schemas.Job,
      Ankole.Schedule.Schemas.CronSchedule,
      Ankole.BackgroundAgentJobs.Schemas.Job,
      Ankole.Workflow.Schemas.Run
    ]
  end

  defp schemas,
    do: parent_schemas() ++ [Ankole.Schedule.Schemas.ScheduledEvent, Ankole.Signals.Signal]

  def entries do
    Enum.map(schemas(), fn schema -> {schema.__work_provenance__()[:kind], schema} end)
  end

  def schema(kind), do: entries() |> List.keyfind(kind, 0) |> then(&if(&1, do: elem(&1, 1)))

  @doc "Keeps the work rows that a reviewer can resolve."
  def unresolved_query(query, schema) do
    states = schema.__work_provenance__()[:review_states]
    Ash.Query.filter(query, status in ^states)
  end

  def reauthorizable_state?(%schema{} = work),
    do: work.status in schema.__work_provenance__()[:reauthorizable_states]

  @doc "Reads one work row of the selected tenant, or gives `nil`."
  def get(schema, id),
    do: schema |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  @doc "Locks one work row of the selected tenant for update, or gives `nil`."
  def lock(schema, id) do
    schema
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {schema.__schema__(:source), id})
  end

  def revoke_human_work_in_tx(uid, version, now) do
    lock_revocation_parents_in_tx(uid, version)

    Map.new(schemas(), fn schema ->
      opts = schema.__work_provenance__()
      {module, action} = opts[:revoke_action]

      {count, _} = apply(module, action, [uid, version, now])

      {to_string(opts[:cleanup_key]), count}
    end)
  end

  defp lock_revocation_parents_in_tx(uid, version) do
    Enum.each(parent_schemas(), fn schema ->
      ids =
        schema
        |> human_work_query(uid, version)
        |> unresolved_query(schema)
        |> Ash.Query.select([:id])
        |> Ankole.Ash.read!()
        |> Enum.map(& &1.id)

      schema
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read!(lock_identity: {schema.__schema__(:source), ids})
    end)
  end

  defp human_work_query(schema, uid, version) do
    schema
    |> Ash.Query.filter(human_uid == ^uid and human_access_version < ^version)
  end
end
