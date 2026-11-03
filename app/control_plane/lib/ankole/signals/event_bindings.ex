defmodule Ankole.Signals.EventBindings do
  @moduledoc "Page-owned event subscriptions use the same Binding rows as schedules and webhooks."
  require Ash.Query
  alias Ankole.{AutomationJobs, Repo, Pod, AuthZ}
  alias Ankole.Signals.{Binding, SourceBindings, Target}

  def list(actor, reference) do
    with {:ok, _} <- Pod.Access.principal(actor),
         :ok <- source_access(actor, reference) do
      Binding
      |> Ash.Query.filter(config_ref == ^reference)
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read()
    end
  end

  def put(actor, attrs) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)
    reference = attrs["config_ref"]

    with {:ok, _} <- Pod.Access.principal(actor),
         :ok <- source_access(actor, reference),
         {:ok, route} <- target(actor, attrs) do
      Repo.transact_top_level(fn ->
        id = attrs["id"] || Ash.UUIDv7.generate()
        previous = Binding |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

        with true <- is_nil(previous) or previous.config_ref == reference,
             :ok <- SourceBindings.lock_in_tx(reference, route.automation_job_id),
             :ok <- source_access(actor, reference),
             {:ok, route} <- target(actor, attrs),
             do:
               Ankole.Ash.create(
                 Binding,
                 :put,
                 Map.merge(route, %{
                   id: id,
                   name: attrs["name"] || "event:#{id}",
                   adapter: "internal",
                   config_ref: reference,
                   filters: attrs["filters"] || %{},
                   watched_field_ids: attrs["watched_field_ids"],
                   enabled: Map.get(attrs, "enabled", true)
                 })
               ),
             else: (
               false -> {:error, :binding_source_changed}
               error -> error
             )
      end)
    end
  end

  defp target(actor, %{"automation_job_id" => id}) when is_integer(id) do
    with {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id),
         :ok <- AutomationJobs.authorize_applet_job(actor, job, job.page_id, "node_contribute"),
         do: {:ok, %{routing_mode: :action, automation_job_id: id, agent_uid: nil, target: %{}}},
         else: (
           {:ok, nil} -> {:error, :not_found}
           error -> error
         )
  end

  defp target(actor, %{"agent_uid" => uid, "target" => target}) do
    with {:ok, _} <- Ankole.Principals.get_agent(uid),
         :ok <-
           if(AuthZ.allowed?(AuthZ.Actor.uid(actor), "agent:#{uid}", "chat"),
             do: :ok,
             else: {:error, :forbidden}
           ),
         true <- routable?(Target.parse(target)),
         do:
           {:ok,
            %{routing_mode: :ai_colleague, automation_job_id: nil, agent_uid: uid, target: target}},
         else: (
           false -> {:error, :invalid_signal_target}
           error -> error
         )
  end

  defp target(_, _), do: {:error, :invalid_signal_target}

  defp source_access(actor, "base://" <> id) do
    with {:ok, _} <- Pod.Bases.table_access(actor, id, :manage_schema), do: :ok
  end

  defp source_access(actor, "applet://" <> id) do
    with {:ok, _} <- Pod.authorize_applet(actor, id, "node_edit"), do: :ok
  end

  defp source_access(actor, "schedule://" <> id) do
    with {:ok, source} <- Ankole.Schedule.get_cron_schedule(id), do: source_owner(actor, source)
  end

  defp source_access(actor, "scheduled-event://" <> id) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, source} <- Ankole.Schedule.get_checkback(id),
         do: source_owner(actor, source)
  end

  defp source_access(actor, "webhook-endpoint://" <> id) do
    case Ankole.Signals.Webhooks.get_endpoint(id) do
      nil -> {:error, :not_found}
      source -> source_owner(actor, source)
    end
  end

  defp source_access(actor, "job://" <> id) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id) do
      if job.executor_kind == :applet_function,
        do: AutomationJobs.authorize_applet_job(actor, job, job.page_id, "node_contribute"),
        else: source_owner(actor, job)
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp source_access(_, _), do: {:error, :invalid_signal_source}

  defp source_owner(actor, source) do
    uid = AuthZ.Actor.uid(actor)

    if AuthZ.pod_admin?(uid) or source.agent_uid == uid or
         (Map.get(source, :authorization_kind) in [:human, "human"] and source.human_uid == uid),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp routable?({:conversation, _}), do: true
  defp routable?({:session, key}), do: Ankole.Sessions.Key.routable?(key)
  defp routable?(_), do: false
end
