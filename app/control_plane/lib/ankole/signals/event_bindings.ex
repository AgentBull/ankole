defmodule Ankole.Signals.EventBindings do
  @moduledoc "Page-owned event subscriptions use the same Binding rows as schedules and webhooks."
  require Ash.Query
  alias Ankole.{AutomationJobs, Repo, Pod, AuthZ}
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.{Binding, Coalesce, SourceBindings, Target}

  def list(actor, reference, job_id \\ nil, routine_id \\ nil)

  def list(actor, reference, nil, nil) when is_binary(reference) do
    with {:ok, _} <- Pod.Access.principal(actor),
         :ok <- source_access(actor, reference, :read) do
      Binding
      |> Ash.Query.filter(config_ref == ^reference)
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read()
    end
  end

  def list(actor, nil, job_id, nil) when is_integer(job_id) do
    with {:ok, _} <- Pod.Access.principal(actor),
         {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(job_id),
         :ok <- AutomationJobs.authorize_applet_job(actor, job, job.page_id, "node_view"),
         {:ok, bindings} <-
           Binding
           |> Ash.Query.filter(automation_job_id == ^job_id)
           |> Ash.Query.sort(id: :asc)
           |> Ankole.Ash.read() do
      readable_sources =
        bindings
        |> Enum.map(& &1.config_ref)
        |> Enum.uniq()
        |> Enum.filter(&(source_access(actor, &1, :read) == :ok))
        |> MapSet.new()

      {:ok, Enum.filter(bindings, &MapSet.member?(readable_sources, &1.config_ref))}
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  def list(actor, nil, nil, routine_id) when is_binary(routine_id) do
    with {:ok, _} <- Pod.Access.principal(actor),
         {:ok, routine} <- Ankole.Schedule.get_routine(routine_id),
         :ok <- routine_access(actor, routine, :read),
         {:ok, bindings} <-
           Binding
           |> Ash.Query.filter(
             agent_routine_id == ^routine_id and fragment("? NOT LIKE 'source:%'", name)
           )
           |> Ash.Query.sort(id: :asc)
           |> Ankole.Ash.read() do
      readable_sources =
        bindings
        |> Enum.map(& &1.config_ref)
        |> Enum.uniq()
        |> Enum.filter(&(source_access(actor, &1, :read) == :ok))
        |> MapSet.new()

      {:ok, Enum.filter(bindings, &MapSet.member?(readable_sources, &1.config_ref))}
    end
  end

  def list(_, _, _, _), do: {:error, :invalid_signal_source}

  def put(actor, attrs) do
    with {:ok, [prepared]} <- prepare_put_entries(actor, [attrs]),
         {:ok, [binding]} <-
           Repo.transact_top_level(fn -> put_prepared_in_tx(actor, [prepared]) end) do
      {:ok, binding}
    end
  end

  def put_many_in_tx(_actor, []), do: {:ok, []}

  def put_many_in_tx(actor, attrs_list) when is_list(attrs_list) do
    with {:ok, prepared} <- prepare_put_entries(actor, attrs_list) do
      put_prepared_in_tx(actor, prepared)
    end
  end

  defp prepare_put_entries(actor, attrs_list) do
    with {:ok, _} <- Pod.Access.principal(actor) do
      Enum.reduce_while(attrs_list, {:ok, []}, fn raw_attrs, {:ok, acc} ->
        attrs = Ankole.Attrs.normalize_external_attrs(raw_attrs)
        reference = attrs["config_ref"]

        with :ok <- source_access(actor, reference),
             {:ok, authorization} <- source_authorization(reference),
             {:ok, route} <- target(actor, attrs, authorization, nil) do
          {:cont,
           {:ok,
            [
              %{
                attrs: attrs,
                reference: reference,
                route: route,
                id: attrs["id"] || Ash.UUIDv7.generate()
              }
              | acc
            ]}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  defp put_prepared_in_tx(actor, entries) do
    ids = Enum.map(entries, & &1.id)

    previous_by_id =
      Binding
      |> Ash.Query.filter(id in ^ids)
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.id, &1})

    with :ok <- AuthZ.authorize_turn_in_tx(actor.turn_authority, lock: false),
         true <-
           Enum.all?(entries, fn entry ->
             previous = Map.get(previous_by_id, entry.id)
             is_nil(previous) or previous.config_ref == entry.reference
           end),
         :ok <-
           SourceBindings.lock_many_in_tx(
             Enum.map(entries, & &1.reference),
             Enum.flat_map(entries, fn entry ->
               [entry.route.automation_job_id, source_job_id(entry.reference)]
             end),
             Enum.flat_map(entries, fn entry ->
               previous = Map.get(previous_by_id, entry.id)

               [
                 entry.route[:agent_routine_id],
                 previous && previous.agent_routine_id,
                 source_routine_id(entry.reference)
               ]
             end)
           ),
         {:ok, created} <-
           Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
             previous = Map.get(previous_by_id, entry.id)

             with :ok <- source_access(actor, entry.reference),
                  {:ok, authorization} <- source_authorization(entry.reference),
                  :ok <- editable_binding(previous, entry.reference, entry.attrs),
                  :ok <-
                    AutomationJobs.authorize_bindable_in_tx(actor, entry.route.automation_job_id),
                  {:ok, route} <- target(actor, entry.attrs, authorization, previous),
                  {:ok, binding} <-
                    Ankole.Ash.create(
                      Binding,
                      :put,
                      Map.merge(route, %{
                        id: entry.id,
                        name: entry.attrs["name"] || "event:#{entry.id}",
                        adapter: "internal",
                        config_ref: entry.reference,
                        filters: entry.attrs["filters"] || %{},
                        watched_field_ids: entry.attrs["watched_field_ids"],
                        enabled: Map.get(entry.attrs, "enabled", true)
                      })
                    ),
                  :ok <- maybe_complete_detached_routines_in_tx(binding, previous) do
               {:cont, {:ok, [binding | acc]}}
             else
               error -> {:halt, error}
             end
           end),
         :ok <- AuthZ.authorize_turn_in_tx(actor.turn_authority) do
      {:ok, Enum.reverse(created)}
    else
      false -> {:error, :binding_source_changed}
      error -> error
    end
  end

  defp source_job_id("job://" <> id) do
    case Ankole.ModelIntegerID.parse(id) do
      {:ok, id} -> id
      _ -> nil
    end
  end

  defp source_job_id("schedule://" <> id) do
    case Ankole.Schedule.get_cron_schedule(id) do
      {:ok, source} -> source.owner_job_id
      _ -> nil
    end
  end

  defp source_job_id("webhook-endpoint://" <> id) do
    case Ankole.Signals.Webhooks.get_endpoint(id) do
      nil -> nil
      source -> source.owner_job_id
    end
  end

  defp source_job_id(_), do: nil

  defp source_routine_id("schedule://" <> id) do
    case Ankole.Schedule.get_cron_schedule(id) do
      {:ok, source} -> source.owner_routine_id
      _ -> nil
    end
  end

  defp source_routine_id(_), do: nil

  defp maybe_complete_detached_routines_in_tx(binding, previous) do
    now = DateTime.utc_now(:microsecond)

    candidates =
      [
        if(not binding.enabled, do: binding.agent_routine_id),
        if(previous && previous.agent_routine_id != binding.agent_routine_id,
          do: previous.agent_routine_id
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(candidates, :ok, fn routine_id, :ok ->
      case Ankole.Schedule.maybe_complete_routine_after_binding_disabled_in_tx(routine_id, now) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp editable_binding(previous, reference, attrs) do
    default_name = "source:" <> reference

    if (previous && previous.name == default_name) || attrs["name"] == default_name,
      do: {:error, :source_binding_managed_by_owner},
      else: :ok
  end

  defp target(actor, %{"automation_job_id" => id}, _authorization, _previous)
       when is_integer(id) do
    with {:ok, %{status: :active} = job} <- AutomationJobs.get_automation_job(id),
         :ok <- AutomationJobs.authorize_applet_job(actor, job, job.page_id, "node_contribute"),
         do:
           {:ok,
            %{
              routing_mode: :action,
              automation_job_id: id,
              agent_routine_id: nil,
              agent_uid: nil,
              target: %{},
              coalesce: nil
            }},
         else: (
           {:ok, nil} -> {:error, :not_found}
           {:ok, _} -> {:error, :automation_job_not_active}
           error -> error
         )
  end

  defp target(actor, %{"agent_routine_id" => routine_id} = attrs, authorization, previous)
       when is_binary(routine_id) do
    with {:ok, %{status: status} = routine} when status in [:active, :paused] <-
           Ankole.Schedule.get_routine(routine_id),
         :ok <- routine_access(actor, routine, :write),
         :ok <-
           if(AuthZ.allowed?(AuthZ.Actor.uid(actor), "agent:#{routine.agent_uid}", "chat"),
             do: :ok,
             else: {:error, :forbidden}
           ),
         :ok <- WorkAccess.check_execution_target(routine.agent_uid, WorkAccess.fields(routine)),
         :ok <- WorkAccess.check_execution_target(routine.agent_uid, authorization),
         {:ok, coalesce} <- resolve_coalesce(attrs, previous, Coalesce.default_routine_config()) do
      {:ok,
       %{
         routing_mode: :ai_colleague,
         automation_job_id: nil,
         agent_routine_id: routine.id,
         agent_uid: routine.agent_uid,
         target: %{"session_id" => Ankole.Sessions.Key.routine(routine.id)},
         coalesce: coalesce
       }}
    else
      {:ok, _terminal} -> {:error, :invalid_signal_target}
      {:error, _} = error -> error
    end
  end

  defp target(actor, %{"agent_uid" => uid, "target" => target} = attrs, authorization, previous) do
    with {:ok, _} <- Ankole.Principals.get_agent(uid),
         :ok <-
           if(AuthZ.allowed?(AuthZ.Actor.uid(actor), "agent:#{uid}", "chat"),
             do: :ok,
             else: {:error, :forbidden}
           ),
         :ok <- WorkAccess.check_execution_target(uid, authorization),
         true <- routable?(Target.parse(target)),
         {:ok, coalesce} <- resolve_coalesce(attrs, previous, nil),
         do:
           {:ok,
            %{
              routing_mode: :ai_colleague,
              automation_job_id: nil,
              agent_routine_id: nil,
              agent_uid: uid,
              target: target,
              coalesce: coalesce
            }},
         else: (
           false -> {:error, :invalid_signal_target}
           error -> error
         )
  end

  defp target(_, _, _, _), do: {:error, :invalid_signal_target}

  defp resolve_coalesce(attrs, previous, default_value) do
    if Map.has_key?(attrs, "coalesce") do
      Coalesce.normalize_config(attrs["coalesce"])
    else
      {:ok, (previous && previous.coalesce) || default_value}
    end
  end

  defp routine_access(actor, routine, :write), do: source_owner(actor, routine, :write)

  defp routine_access(actor, routine, :read) do
    case source_owner(actor, routine, :read) do
      :ok ->
        :ok

      _ ->
        uid = AuthZ.Actor.uid(actor)
        foreign_pas = MapSet.new(Ankole.Principals.foreign_personal_assistant_uids(uid))

        if not MapSet.member?(foreign_pas, routine.agent_uid) and
             Enum.any?(Ankole.Schedule.routine_room_ids(routine), fn room_id ->
               match?({:ok, _}, Ankole.Conversations.visible_native_conversation(actor, room_id))
             end) do
          :ok
        else
          {:error, :forbidden}
        end
    end
  end

  defp source_authorization("schedule://" <> id) do
    with {:ok, source} <- Ankole.Schedule.get_cron_schedule(id),
         do: {:ok, WorkAccess.fields(source)}
  end

  defp source_authorization("scheduled-event://" <> id) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, source} <- Ankole.Schedule.get_checkback(id),
         do: {:ok, WorkAccess.fields(source)}
  end

  defp source_authorization("webhook-endpoint://" <> id) do
    case Ankole.Signals.Webhooks.get_endpoint(id) do
      nil -> {:error, :not_found}
      source -> {:ok, WorkAccess.fields(source)}
    end
  end

  defp source_authorization("job://" <> id) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id) do
      {:ok, WorkAccess.fields(job)}
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp source_authorization("connector-trigger://" <> id) do
    with {:ok, trigger} <- Ankole.Connectors.Triggers.get(id),
         do: {:ok, Ankole.Connectors.Triggers.authorization(trigger)}
  end

  defp source_authorization("connector://" <> _), do: {:ok, WorkAccess.service()}
  defp source_authorization("base://" <> _), do: {:ok, WorkAccess.service()}
  defp source_authorization("applet://" <> _), do: {:ok, WorkAccess.service()}
  defp source_authorization(_), do: {:error, :invalid_signal_source}

  defp source_access(actor, reference, mode \\ :write)

  defp source_access(actor, "base://" <> id, mode) do
    with {:ok, _} <-
           Pod.Bases.table_access(actor, id, if(mode == :read, do: :read, else: :manage_schema)),
         do: :ok
  end

  defp source_access(actor, "applet://" <> id, mode) do
    with {:ok, _} <-
           Pod.authorize_applet(actor, id, if(mode == :read, do: "node_view", else: "node_edit")),
         do: :ok
  end

  defp source_access(actor, "schedule://" <> id, mode) do
    with {:ok, source} <- Ankole.Schedule.get_cron_schedule(id),
         do: source_owner(actor, source, mode)
  end

  defp source_access(actor, "scheduled-event://" <> id, mode) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, source} <- Ankole.Schedule.get_checkback(id),
         do: source_owner(actor, source, mode)
  end

  defp source_access(actor, "webhook-endpoint://" <> id, mode) do
    case Ankole.Signals.Webhooks.get_endpoint(id) do
      nil -> {:error, :not_found}
      source -> source_owner(actor, source, mode)
    end
  end

  defp source_access(actor, "job://" <> id, mode) do
    with {:ok, id} <- Ankole.ModelIntegerID.parse(id),
         {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id) do
      AutomationJobs.authorize_applet_job(
        actor,
        job,
        job.page_id,
        if(mode == :read, do: "node_view", else: "node_contribute")
      )
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  defp source_access(actor, "connector://" <> _ = reference, _mode),
    do: Ankole.Connectors.Triggers.source_access(actor, reference)

  defp source_access(actor, "connector-trigger://" <> _ = reference, _mode),
    do: Ankole.Connectors.Triggers.source_access(actor, reference)

  defp source_access(_, _, _), do: {:error, :invalid_signal_source}

  defp source_owner(actor, %{owner_job_id: id}, mode) when is_integer(id) do
    with {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id),
         do:
           AutomationJobs.authorize_applet_job(
             actor,
             job,
             job.page_id,
             cond do
               mode == :read -> "node_view"
               job.authorization_kind == "human" -> "node_contribute"
               true -> "node_edit"
             end
           ),
         else: (_ -> {:error, :not_found})
  end

  defp source_owner(actor, source, _mode) do
    uid = AuthZ.Actor.uid(actor)
    human_uid = Ankole.Principals.authority_uid(uid)
    agent_uid = Map.get(source, :agent_uid)

    foreign_pa? =
      is_binary(agent_uid) and
        agent_uid in Ankole.Principals.foreign_personal_assistant_uids(human_uid)

    if not foreign_pa? and
         (AuthZ.pod_admin?(uid) or agent_uid == uid or
            (Map.get(source, :authorization_kind) in [:human, "human"] and
               source.human_uid == human_uid)),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp routable?({:conversation, _}), do: true
  defp routable?({:session, key}), do: Ankole.Sessions.Key.routable?(key)
  defp routable?(_), do: false
end
