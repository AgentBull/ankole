defmodule Ankole.Signals.Dispatch do
  @moduledoc "Routes source events through Bindings to durable Actions and Session intake."
  require Ash.Query
  alias Ankole.{AutomationJobs, Repo}
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.{Binding, BindingFilters, BindingReceipt, Intake, Target, Signal}

  def applet(context, page, actor, caller, "call", args),
    do: Ankole.Signals.AppletDispatch.dispatch(context, page, actor, caller, :wait_result, args)

  def applet(context, page, actor, caller, "emit", [%{"targetJobId" => _} = request]),
    do:
      Ankole.Signals.AppletDispatch.dispatch(context, page, actor, caller, :wait_accepted, [
        request
      ])

  def applet(context, page, actor, caller, "emit", args),
    do:
      Ankole.Signals.AppletDispatch.dispatch(context, page, actor, caller, :fire_and_forget, args)

  def applet(_context, page, actor, _caller, "run", [id]),
    do: AutomationJobs.get_applet_run(actor, page.id, id)

  def applet(_, _, _, _, _, _), do: {:error, :invalid_request}

  def emit(reference, signal, opts \\ []) do
    with true <- Keyword.get(opts, :response_mode, :fire_and_forget) == :fire_and_forget,
         {:ok, source_work} <- source_work(Keyword.get(opts, :attempt_authority)),
         {:ok, plan} <- prepare(reference, signal, opts) do
      result =
        Repo.transact_top_level(
          fn ->
            with {:ok, plan} <- lock_in_tx(plan, source_work),
                 :ok <- Ankole.AuthZ.authorize_turn_in_tx(Keyword.get(opts, :attempt_authority)),
                 do: deliver_in_tx(plan)
          end,
          after_commit: fn result -> Ankole.Signals.publish_committed(result.signals) end
        )

      retries = Keyword.get(opts, :retries, 3)

      if result == {:error, :binding_changed} and retries > 0,
        do: emit(reference, signal, Keyword.put(opts, :retries, retries - 1)),
        else: result
    else
      false -> {:error, :invalid_response_mode}
      error -> error
    end
  end

  defp source_work(nil), do: {:ok, []}

  defp source_work({%Ankole.AutomationJobs.AttemptRef{job_id: id}, _uid}) do
    with {:ok, job} when not is_nil(job) <- AutomationJobs.get_automation_job(id),
         do: {:ok, [job]},
         else: (_ -> {:error, :automation_job_attempt_not_active})
  end

  def prepare(reference, signal, opts \\ []) do
    signal =
      signal
      |> Ankole.JSON.plain()
      |> Map.put_new("id", Ash.UUIDv7.generate())
      |> Map.put_new("signal_id", Ash.UUIDv7.generate())
      |> Map.put_new("time", DateTime.to_iso8601(DateTime.utc_now()))
      |> Map.put_new("data", %{})

    signal = Map.put(signal, "source", source(reference))

    bindings =
      Binding
      |> Ash.Query.filter(config_ref == ^reference and enabled and is_nil(unavailable_reason))
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read!()

    with {:ok, deliveries} <- select_bindings(bindings, signal),
         {:ok, jobs} <- prepare_jobs(deliveries),
         {:ok, deliveries} <- prepare_keys(deliveries, jobs) do
      {:ok,
       %{reference: reference, signal: signal, deliveries: deliveries, jobs: jobs, opts: opts}}
    end
  end

  defp source("connector://" <> _ = source), do: source
  defp source("connector-trigger://" <> _ = source), do: source
  defp source("schedule://" <> id), do: "ankole:schedule:#{id}"
  defp source("scheduled-event://" <> id), do: "ankole:schedule:#{id}"
  defp source("webhook-endpoint://" <> id), do: "ankole:webhook:#{id}"
  defp source("base://" <> id), do: "ankole:base:#{id}"
  defp source("applet://" <> id), do: "ankole:applet:#{id}"
  defp source("job://" <> id), do: "ankole:job:#{id}"

  defp select_bindings(bindings, signal) do
    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, selected} ->
      event = filter_changes(binding, signal)

      case event && BindingFilters.match_event?(binding.filters, event, binding) do
        :match ->
          if binding.routing_mode == :action or Target.parse(binding.target) != :error,
            do: {:cont, {:ok, [%{binding: binding, signal: event} | selected]}},
            else: {:halt, {:error, :invalid_signal_target}}

        no_match when no_match in [nil, :no_match] ->
          {:cont, {:ok, selected}}

        error ->
          {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp filter_changes(%{watched_field_ids: fields}, %{"data" => %{"changes" => changes}} = event)
       when is_list(fields) and fields != [] do
    changes =
      Enum.filter(changes, fn change ->
        change["op"] == "delete" or Enum.any?(change["fields"] || [], &(&1 in fields))
      end)

    if changes != [], do: put_in(event, ["data", "changes"], changes)
  end

  defp filter_changes(_, event), do: event

  defp prepare_jobs(deliveries) do
    ids =
      deliveries
      |> Enum.map(& &1.binding.automation_job_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        {:ok, %{}}

      ids ->
        with {:ok, jobs} <- AutomationJobs.list_automation_jobs(query: [filter: [id: [in: ids]]]) do
          if length(jobs) == length(ids),
            do: {:ok, Map.new(jobs, &{&1.id, &1})},
            else: {:error, :binding_changed}
        end
    end
  end

  defp prepare_keys(deliveries, jobs) do
    Enum.reduce_while(deliveries, {:ok, []}, fn
      %{binding: %{automation_job_id: nil}} = delivery, {:ok, prepared} ->
        {:cont, {:ok, [delivery | prepared]}}

      delivery, {:ok, prepared} ->
        case concurrency_key(jobs[delivery.binding.automation_job_id], delivery.signal) do
          {:ok, key} ->
            {:cont, {:ok, [Map.put(delivery, :concurrency_key, key) | prepared]}}

          error ->
            {:halt, error}
        end
    end)
    |> reverse_ok()
  end

  defp concurrency_key(%{status: :active} = job, signal),
    do: AutomationJobs.prepare_applet_job(job, signal)

  defp concurrency_key(_, _), do: {:ok, "default"}

  def lock_in_tx(plan, source_work \\ []) do
    Repo.require_transaction()
    jobs = Map.values(plan.jobs)

    jobs =
      Enum.uniq_by(
        jobs ++ Enum.filter(source_work, &match?(%Ankole.AutomationJobs.Schemas.Job{}, &1)),
        & &1.id
      )

    authorization = Keyword.get(plan.opts, :authorization, WorkAccess.service())

    with :ok <- WorkAccess.lock_authorizers_in_tx([authorization | jobs ++ source_work]),
         :ok <- WorkAccess.check_in_tx(authorization),
         :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()) do
      locked_jobs =
        Map.new(Enum.sort_by(jobs, & &1.id), &{&1.id, AutomationJobs.lock_job_in_tx(&1.id)})

      ids = Enum.map(plan.deliveries, & &1.binding.id)

      bindings =
        Binding
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock("FOR KEY SHARE")
        |> Ankole.Ash.read!(lock_identity: {"signal_bindings", ids})

      if bindings == Enum.map(plan.deliveries, & &1.binding) and
           Enum.all?(jobs, &(locked_jobs[&1.id] == &1)) do
        {:ok, plan}
      else
        {:error, :binding_changed}
      end
    end
  end

  def deliver_in_tx(plan) do
    deliveries = Enum.filter(plan.deliveries, &active_delivery?(plan, &1.binding))

    with {:ok, deliveries} <- reserve_receipts(deliveries),
         {:ok, action_receipts} <- deliver_actions(plan, deliveries),
         {:ok, agent_receipts, signals} <- deliver_agents(plan, deliveries) do
      receipts = action_receipts ++ agent_receipts

      {:ok,
       %{
         signal_id:
           case receipts do
             [receipt | _] -> receipt.signal_id
             [] -> plan.signal["signal_id"]
           end,
         receipts: receipts,
         signals: signals
       }}
    end
  end

  defp active_delivery?(plan, %{routing_mode: :action, automation_job_id: id}) do
    job = plan.jobs[id]
    job.status == :active and WorkAccess.check_in_tx(job) == :ok
  end

  defp active_delivery?(_plan, _binding), do: true

  defp reserve_receipts(deliveries) do
    Enum.reduce_while(deliveries, {:ok, []}, fn %{binding: binding, signal: signal} = delivery,
                                                {:ok, reserved} ->
      case Ankole.Ash.insert_if_absent(BindingReceipt, :receive_event, %{
             binding_id: binding.id,
             source: signal["source"],
             source_event_id: signal["id"],
             signal_id: signal["signal_id"]
           }) do
        {:ok, receipt, status} ->
          {:cont, {:ok, [Map.merge(delivery, %{receipt: receipt, status: status}) | reserved]}}

        error ->
          {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp deliver_actions(plan, deliveries) do
    deliveries
    |> Enum.filter(&(&1.binding.routing_mode == :action))
    |> Enum.reduce_while({:ok, []}, fn delivery, {:ok, receipts} ->
      result =
        if delivery.status == :existing,
          do: {:ok, delivery.receipt},
          else: deliver_action(plan, delivery)

      case result do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp deliver_agents(plan, deliveries) do
    {existing, fresh} =
      deliveries
      |> Enum.reject(&(&1.binding.routing_mode == :action))
      |> Enum.split_with(&(&1.status == :existing))

    with {:ok, attrs} <- agent_deliveries(plan, fresh),
         {:ok, signals} <- Intake.accept_all(attrs) do
      result =
        Enum.zip(fresh, signals)
        |> Enum.reduce_while({:ok, Enum.map(existing, & &1.receipt)}, fn {delivery, signal},
                                                                         {:ok, receipts} ->
          case Ankole.Ash.update(delivery.receipt, :deliver, %{delivered_signal_id: signal.id}) do
            {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
            error -> {:halt, error}
          end
        end)

      with {:ok, receipts} <- result do
        receipts = Enum.sort_by(receipts, & &1.binding_id)
        ids = Enum.map(existing, & &1.receipt.delivered_signal_id)
        delivered = Signal |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.read!()
        all = Map.new(delivered ++ signals, &{&1.id, &1})

        {:ok, receipts,
         Enum.map(receipts, &all[&1.delivered_signal_id]) |> Enum.reject(&is_nil/1)}
      end
    end
  end

  defp agent_deliveries(plan, deliveries) do
    Enum.reduce_while(deliveries, {:ok, []}, fn delivery, {:ok, attrs} ->
      case agent_attrs(plan, delivery.binding, delivery.signal) do
        {:ok, value} -> {:cont, {:ok, [value | attrs]}}
        error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp deliver_action(plan, delivery) do
    %{binding: binding, signal: signal, receipt: receipt, concurrency_key: key} = delivery
    job = plan.jobs[binding.automation_job_id]

    with {:ok, result} <-
           AutomationJobs.enqueue_locked_in_tx(job, signal,
             concurrency_key: key,
             signal_id: signal["signal_id"],
             binding_id: binding.id,
             causation_id: signal["causation_id"],
             correlation_id: signal["correlation_id"]
           ),
         do:
           Ankole.Ash.update(receipt, :deliver, %{
             automation_job_run_id: result.automation_job_run.id
           })
  end

  defp agent_attrs(plan, binding, signal) do
    source_id =
      if Enum.count(plan.deliveries, &(&1.binding.agent_uid == binding.agent_uid)) > 1,
        do: signal["id"] <> ":binding:#{binding.id}",
        else: signal["id"]

    with {:ok, target, route} <- agent_target(binding, plan.opts) do
      {:ok,
       %{
         producer: Keyword.get(plan.opts, :producer, :kernel),
         source: signal["source"],
         id: source_id,
         type: signal["type"],
         subject: signal["subject"],
         time: signal["time"],
         data: signal["data"],
         target: target,
         sender: nil,
         extensions:
           Map.drop(
             signal,
             ~w(specversion id signal_id source type subject time data causation_id correlation_id)
           ),
         authorization: Keyword.get(plan.opts, :authorization, WorkAccess.service()),
         reply_route: route || Keyword.get(plan.opts, :reply_route, %{})
       }}
    end
  end

  defp agent_target(binding, opts) do
    case Target.parse(binding.target) do
      {:conversation, id} ->
        route = Keyword.get(opts, :reply_route)

        resolved =
          if route in [nil, %{}],
            do: Ankole.Conversations.Route.conversation_reply_route(binding.agent_uid, id),
            else: {:ok, route}

        with {:ok, route} <- resolved,
             do: {:ok, %{agent_uid: binding.agent_uid, conversation_id: id}, route}

      {:session, id} ->
        with {:ok, owner} <- Ankole.Conversations.Route.long_lived_owner(binding.agent_uid, id),
             do:
               {:ok, %{agent_uid: binding.agent_uid, session_id: owner.session_id},
                owner.reply_route}
    end
  end

  def root_signal_id(delivered_id) do
    BindingReceipt
    |> Ash.Query.filter(delivered_signal_id == ^delivered_id)
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read_one!()
    |> case do
      nil -> delivered_id
      receipt -> receipt.signal_id
    end
  end

  def receipts(nil), do: []

  def receipts(signal_id),
    do: BindingReceipt |> Ash.Query.filter(signal_id == ^signal_id) |> Ankole.Ash.read!()

  def expire_receipts(now) do
    cutoff = DateTime.add(now, -7 * 86400, :second)
    expire_batch(cutoff, nil)
  end

  defp expire_batch(cutoff, cursor) do
    receipts =
      BindingReceipt
      |> Ash.Query.filter(received_at < ^cutoff)
      |> Ash.Query.sort(binding_id: :asc, source: :asc, source_event_id: :asc)
      |> after_receipt(cursor)
      |> Ash.Query.limit(1000)
      |> Ankole.Ash.read!()

    history = history_signal_ids(receipts)
    expired = Enum.reject(receipts, &MapSet.member?(history, &1.signal_id))

    with {:ok, _} <-
           Repo.transact_top_level(fn ->
             Ankole.Ash.destroy_where(expired, :expire, %{},
               resource: BindingReceipt,
               strategy: [:atomic_batches],
               batch_size: 1000
             )
           end) do
      if length(receipts) == 1000, do: expire_batch(cutoff, List.last(receipts)), else: :ok
    end
  end

  defp after_receipt(query, nil), do: query

  defp after_receipt(query, receipt) do
    Ash.Query.filter(
      query,
      binding_id > ^receipt.binding_id or
        (binding_id == ^receipt.binding_id and source > ^receipt.source) or
        (binding_id == ^receipt.binding_id and source == ^receipt.source and
           source_event_id > ^receipt.source_event_id)
    )
  end

  defp history_signal_ids([]), do: MapSet.new()

  defp history_signal_ids(receipts) do
    ids = receipts |> Enum.map(& &1.signal_id) |> Enum.uniq()

    [query: [filter: [signal_id: [in: ids]], select: [:signal_id]]]
    |> Ankole.Schedule.list_scheduled_events!()
    |> MapSet.new(& &1.signal_id)
  end
end
