defmodule Ankole.Work.Owner do
  @moduledoc "Resolves each durable work kind to its domain and authorization contract."
  import Ecto.Query

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

  def unresolved_query(query, schema) do
    states = schema.__work_provenance__()[:review_states]
    from(w in query, where: w.status in ^states)
  end

  def reauthorizable_state?(%schema{} = work),
    do: work.status in schema.__work_provenance__()[:reauthorizable_states]

  def revoke_human_work_in_tx(repo, uid, version, now) do
    lock_revocation_parents_in_tx(repo, uid, version)

    Map.new(schemas(), fn schema ->
      opts = schema.__work_provenance__()
      {module, action} = opts[:revoke_action]

      tenants =
        repo.all(
          from(work in schema,
            where: work.human_uid == ^uid and work.human_access_version < ^version,
            distinct: true,
            select: work.tenant_id
          )
        )

      count =
        Enum.reduce(tenants, 0, fn tenant_id, count ->
          {stopped, _} =
            Ankole.Repo.with_tenant(tenant_id, fn ->
              apply(module, action, [repo, uid, version, now])
            end)

          count + stopped
        end)

      {to_string(opts[:cleanup_key]), count}
    end)
  end

  defp lock_revocation_parents_in_tx(repo, uid, version) do
    Enum.each(parent_schemas(), fn schema ->
      query =
        from(work in schema,
          where: work.human_uid == ^uid and work.human_access_version < ^version
        )

      query = unresolved_query(query, schema)
      ids = repo.all(from(work in query, select: work.id))

      repo.all(
        from(work in schema, where: work.id in ^ids, order_by: work.id, lock: "FOR UPDATE"),
        lock_identity: {schema.__schema__(:source), ids}
      )
    end)
  end
end
