defmodule Ankole.AgentWorkers.ReconcileJob do
  @moduledoc """
  Reconciles one Agent's Worker.

  A step has four parts. It lists the Agent's instances without a database
  lock. It locks the Worker row, decides, and commits the intent of the
  action. It calls the platform outside any transaction. It locks the row
  again and records the result if the row did not change. A database lock
  never waits for a platform request, so a slow provider cannot block
  admission, heartbeats, or the connection pool.

  Generation allocation commits before any create. Later steps send that
  generation's saved credential again until the provider gives a definite
  answer: a rejection, or the disappearance of an observed instance. Every
  platform action is idempotent for one generation, so two jobs for the same
  Agent can repeat a call without harm. A decision uses only an observation
  that was made after the last lifecycle change of the row.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :agent_workers,
    max_attempts: 20,
    unique: [keys: [:agent_uid], period: :infinity, states: [:available, :scheduled, :retryable]]

  require Ash.Query

  alias Ankole.{Logging, Repo}
  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Decision
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Settings

  alias Ankole.AgentWorkers.Providers.Configuration
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerAdmission
  alias Ankole.AgentWorkers.WorkerBootstrap
  alias Ankole.AgentWorkers.WorkerRoute

  @max_steps 12

  def enqueue(agent, opts \\ [])

  def enqueue(%AgentWorker{} = worker, opts) do
    enqueue_args(%{agent_uid: worker.agent_uid, tenant_id: worker.tenant_id}, opts)
  end

  def enqueue(agent_uid, opts) when is_binary(agent_uid) do
    enqueue_args(%{agent_uid: agent_uid}, opts)
  end

  defp enqueue_args(%{agent_uid: agent_uid} = args, opts) do
    case args |> new(opts) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "agent_workers.reconcile_enqueue_failed",
          "Agent Worker reconciliation was not enqueued",
          %{agent_uid: agent_uid, reason: inspect(reason)}
        )

        :ok
    end
  end

  @impl true
  def backoff(%Oban.Job{attempt: attempt}), do: min(Integer.pow(2, attempt), 60)

  @impl true
  def run(%Oban.Job{args: %{"agent_uid" => uid}}) when is_binary(uid) do
    with :ok <- WorkerAdmission.expire_connection(uid), do: loop(uid, @max_steps, nil, nil)
  end

  def run(%Oban.Job{}), do: {:cancel, :missing_agent_uid}

  defp loop(_uid, 0, _previous, _prepared), do: :ok

  defp loop(uid, steps, previous, prepared) do
    case observe(uid) do
      {:ok, seen} ->
        {:ok, %{step: step, worker: worker}} =
          AgentWorkers.decide_reconcile_step(uid, seen, previous, prepared)

        notify_change(seen.worker, worker)

        run(step, uid, steps, previous, prepared)

      :done ->
        :ok

      {:error, reason} ->
        record_error(uid, reason)
        {:error, reason}

      {:error, reason, kind} ->
        record_error(uid, reason, kind)
        {:error, reason}
    end
  end

  defp observe(uid) do
    case AgentWorkers.get_agent_worker!(uid) do
      nil ->
        :done

      %AgentWorker{state: :deleting, provider_id: nil} = worker ->
        {:ok, %{worker: worker, provider: nil, kind: nil, objects: []}}

      worker ->
        with {:ok, provider} <- rejected_error(Providers.load(worker.provider_id)),
             {:ok, kind} <- rejected_error(ProviderKind.fetch(provider.kind)),
             {:ok, objects} <- kind.list_instances(provider, uid) do
          {:ok, %{worker: worker, provider: provider, kind: kind, objects: objects}}
        end
    end
  end

  defp rejected_error({:error, reason}), do: {:error, reason, "rejected"}
  defp rejected_error(result), do: result

  @doc false
  def decide_in_tx(%{agent_uid: uid, seen: seen, previous: previous, prepared: prepared}) do
    step = decide(uid, seen, previous, prepared)
    {:ok, %{step: step, worker: AgentWorkers.get_agent_worker!(uid)}}
  end

  defp decide(uid, seen, previous, prepared) do
    case AgentWorkers.lock_in_tx(Repo, uid) do
      nil ->
        :done

      %AgentWorker{state: :deleting, provider_id: nil} = worker ->
        {:ok, _deleted} = Ankole.Ash.destroy(worker, :remove)
        :done

      worker ->
        if lifecycle(worker) == lifecycle(seen.worker),
          do: decide_with(worker, seen, previous, prepared),
          else: :stale
    end
  end

  defp decide_with(worker, seen, previous, prepared) do
    now = Repo.now!()
    observed = record_observation(worker, seen.objects, now)
    facts = facts(observed, seen.provider, seen.kind, seen.objects, now)
    action = Decision.next(facts)

    cond do
      is_nil(worker.instance_ref) and not is_nil(observed.instance_ref) ->
        # Commit a discovered instance before any callback can give it
        # the launch credential.
        {:continue, :observe}

      action == :none ->
        :done

      match?({:wait, _}, action) ->
        {:wait, elem(action, 1), now}

      action == previous ->
        {:wait, worker.state_changed_at, now}

      action == :begin_create and prepared != prepare_key(seen.provider) ->
        {:prepare, seen.provider}

      true ->
        intend(action, facts)
    end
  end

  defp run(:done, _uid, _steps, _previous, _prepared), do: :ok
  defp run(:stale, uid, steps, previous, prepared), do: loop(uid, steps - 1, previous, prepared)

  defp run({:error, reason} = error, uid, _steps, _previous, _prepared) do
    record_error(uid, reason)
    error
  end

  defp run({:wait, since, now}, uid, _steps, _previous, _prepared), do: follow_up(uid, since, now)

  defp run({:continue, action}, uid, steps, _previous, prepared),
    do: loop(uid, steps - 1, action, prepared)

  defp run({:paused, route}, uid, steps, _previous, prepared) do
    if route, do: WorkerRoute.close_connection(uid, route, :worker_paused)
    loop(uid, steps - 1, :mark_paused, prepared)
  end

  # Image and storage preparation can take minutes and run without a lock.
  # Storage is prepared only while the row still waits to create; a deletion
  # that commits during the image step stops it.
  defp run({:prepare, provider}, uid, steps, previous, _prepared) do
    {:ok, kind} = ProviderKind.fetch(provider.kind)

    with :ok <- kind.prepare_image(provider, provider.runtime.image),
         :ok <- prepare_storage(kind, provider, uid) do
      loop(uid, steps - 1, previous, prepare_key(provider))
    else
      {:pending, reason} ->
        record_prepare_error(uid, provider.provider_id, reason, "pending")
        {:snooze, 15}

      {:error, reason} ->
        record_prepare_error(uid, provider.provider_id, reason, "transient")
        {:error, reason}
    end
  end

  defp run({:call, action, facts}, uid, steps, _previous, prepared) do
    result = call(action, facts)

    {:ok, %{recorded: recorded, worker: worker}} =
      AgentWorkers.record_reconcile_result(action, facts, result)

    notify_change(facts.worker, worker)

    case recorded do
      :ok ->
        loop(uid, steps - 1, action, prepared)

      {:error, reason} ->
        record_error(uid, reason)
        {:error, reason}

      {:error, reason, kind} ->
        record_error(uid, reason, kind)
        {:error, reason}
    end
  end

  defp facts(worker, provider, kind, objects, now) do
    agent = AgentWorkers.agent_status(worker.agent_uid)

    turn? =
      (worker.load["active_slots"] || 0) > 0 or
        worker.agent_uid in AgentWorkers.running_turn_agents([worker.agent_uid])

    settings =
      Map.merge(Settings.current(), %{
        idle_release_after_ms: Configuration.duration_ms(provider.settings["idleReleaseAfter"]),
        stop_grace_ms: provider.settings["stopGraceSeconds"] * 1000
      })

    %{
      worker: worker,
      agent: agent,
      turn_in_progress?: turn?,
      provider: provider,
      kind: kind,
      definition: %{
        kind.definition()
        | max_instance_lifetime: ProviderKind.instance_lifetime(kind, worker.instance_settings)
      },
      objects: objects,
      target: %{
        image: provider.runtime.image,
        protocol_version: provider.runtime.protocol_version,
        settings_digest: provider.settings_digest
      },
      observing_since: provider.runtime.observing_since,
      settings: settings,
      now: now
    }
  end

  defp notify_change(previous, current) do
    fields = [:state, :capacity, :incarnation_id, :transport_route, :last_error, :last_error_kind]

    if is_nil(current) or Map.take(previous, fields) != Map.take(current, fields),
      do: AgentWorkers.notify_changed(previous.agent_uid)
  end

  defp record_observation(worker, objects, now) do
    case Enum.find(
           objects,
           &(ProviderKind.current_instance?(worker, &1) and ProviderKind.instance_present?(&1))
         ) do
      nil ->
        worker

      object ->
        changes = [
          instance_seen_at: worker.instance_seen_at || now,
          instance_ref: worker.instance_ref || object.instance_ref
        ]

        changes =
          if worker.state in [:starting, :stale] and is_binary(object.reason) and
               object.reason != "",
             do: changes ++ AgentWorker.error_fields(object.reason, "transient"),
             else: changes

        write(worker, :observe, changes)
    end
  end

  # Intent: database changes that must be visible before the platform call.

  defp intend(:begin_create, facts) do
    worker = facts.worker

    generation =
      :crypto.strong_rand_bytes(7)
      |> Base.encode32(case: :lower, padding: false)
      |> binary_part(0, 10)

    with {:ok, credential} <- AgentWorkers.issue_credential(worker.agent_uid, generation) do
      write(worker, :begin_generation,
        generation: generation,
        create_sent_at: nil,
        last_error: nil,
        last_error_kind: nil,
        token_digest: credential.token_digest,
        token_ciphertext: credential.token_ciphertext,
        image: facts.target.image,
        protocol_version: facts.target.protocol_version,
        settings_digest: facts.target.settings_digest,
        instance_settings:
          Configuration.instance_settings(facts.definition.schema, facts.provider.settings)
      )

      {:continue, :begin_create}
    end
  end

  defp intend(:create, facts) do
    worker = facts.worker
    retry? = not is_nil(worker.create_sent_at)

    worker =
      if retry?,
        do: worker,
        else: write(worker, :observe, create_sent_at: facts.now)

    {:call, :create, facts |> Map.put(:worker, worker) |> Map.put(:create_retry?, retry?)}
  end

  defp intend(:mark_paused, facts) do
    write(facts.worker, :pause, [])
    {:paused, facts.worker.transport_route}
  end

  defp intend({:replace, reason, _mode} = action, facts),
    do: {:call, action, %{facts | worker: drain(facts.worker, reason)}}

  defp intend({:release, reason} = action, facts),
    do: {:call, action, %{facts | worker: drain(facts.worker, reason)}}

  defp intend(:resume, facts),
    do: {:call, :resume, %{facts | worker: write(facts.worker, :resume, [])}}

  defp intend({:delete_object, object} = action, facts),
    do: {:call, action, %{facts | worker: wait_for_deletion(facts.worker, object)}}

  defp intend(:delete_now, facts),
    do: {:call, :delete_now, %{facts | worker: wait_for_deletion(facts.worker, current(facts))}}

  defp intend(action, facts), do: {:call, action, facts}

  # Platform calls. None of them runs inside a database transaction.

  defp call(:create, facts) do
    worker = facts.worker

    with {:ok, token} <- AgentWorkers.credential(worker) do
      # Repeated creates use the launch decision committed with the generation.
      provider = %{
        facts.provider
        | settings_digest: worker.settings_digest,
          settings:
            Configuration.with_instance_settings(
              facts.definition.schema,
              facts.provider.settings,
              worker.instance_settings
            ),
          runtime:
            Map.merge(
              facts.provider.runtime,
              %{image: worker.image, protocol_version: worker.protocol_version}
            )
      }

      spec =
        WorkerBootstrap.agent_worker_spec(
          provider,
          worker.agent_uid,
          worker.generation,
          token,
          worker.storage_ref
        )

      spec = %{
        spec
        | instance_ref: worker.instance_ref,
          create_retry?: facts.create_retry?,
          create_sent_at: worker.create_sent_at
      }

      case facts.kind.create_instance(provider, spec) do
        {:rejected, reason} -> {:rejected, reason, settle_on_platform(facts)}
        other -> other
      end
    end
  end

  defp call({:delete_object, object}, facts),
    do: facts.kind.delete_instance(facts.provider, object, :now)

  defp call(:delete_storage, facts) do
    worker = facts.worker
    facts.kind.delete_storage(facts.provider, worker.agent_uid, worker.storage_ref)
  end

  defp call(:mark_absent, facts), do: settle_on_platform(facts)

  defp call({:replace, _reason, mode}, facts),
    do: facts.kind.delete_instance(facts.provider, current(facts), mode)

  defp call({:release, reason}, facts) do
    if Decision.pause_release?(facts.definition, reason),
      do: facts.kind.pause_instance(facts.provider, current(facts)),
      else: facts.kind.delete_instance(facts.provider, current(facts), :graceful)
  end

  defp call(:pause, facts), do: facts.kind.pause_instance(facts.provider, current(facts))

  defp call(:delete_now, facts),
    do: facts.kind.delete_instance(facts.provider, current(facts), :now)

  defp call(:resume, facts) do
    case facts.kind.resume_instance(facts.provider, current(facts)) do
      {:error, :gone} -> {:gone, settle_on_platform(facts)}
      other -> other
    end
  end

  # The generation ends. The storage reference must be read before the row
  # becomes absent: a later create sends the committed reference.
  defp settle_on_platform(facts) do
    with {:ok, ref, reason} <-
           facts.kind.current_storage_ref(facts.provider, facts.worker.agent_uid),
         :ok <- delete_replaced_cache(facts) do
      {:ok, ref, reason}
    end
  end

  # A rebuild can be caused by a broken cache. Other replacements keep it:
  # a cache whose own settings changed is replaced by storage preparation.
  defp delete_replaced_cache(facts) do
    if facts.worker.state != :deleting and facts.worker.drain_reason == "rebuild",
      do: facts.kind.delete_cache(facts.provider, facts.worker.agent_uid),
      else: :ok
  end

  # Result: recorded only while the row keeps the lifecycle state that the
  # call was based on. Another job may have moved the row; the next step
  # observes again.
  @doc false
  def record_in_tx(%{call: action, facts: facts, result: result}) do
    recorded = record(action, facts, result)
    {:ok, %{recorded: recorded, worker: AgentWorkers.get_agent_worker!(facts.worker.agent_uid)}}
  end

  defp record(action, facts, result) do
    case AgentWorkers.lock_in_tx(Repo, facts.worker.agent_uid) do
      nil ->
        :ok

      worker ->
        if lifecycle(worker) == lifecycle(facts.worker),
          do: apply_result(action, worker, result),
          else: unchanged_error(result)
    end
  end

  defp apply_result(:create, worker, {:ok, ref}) do
    changes = [instance_ref: ref || worker.instance_ref]

    changes =
      if is_nil(worker.instance_seen_at),
        do:
          changes ++
            AgentWorker.error_fields(
              "Waiting for provider to observe generation #{worker.generation}",
              "pending"
            ),
        else: changes

    write(worker, :observe, changes)

    :ok
  end

  defp apply_result(:create, worker, {:rejected, reason, {:ok, ref, text}}) do
    settle(worker, ref, text)
    {:error, reason, "rejected"}
  end

  defp apply_result(:create, _worker, {:rejected, reason, {:error, settle_reason}}),
    do: {:error, {:create_rejected, reason, settle_reason}, "rejected"}

  defp apply_result(:resume, worker, {:gone, {:ok, ref, text}}) do
    settle(worker, ref, text)
    :ok
  end

  defp apply_result(:resume, _worker, {:gone, {:error, _} = error}), do: error

  defp apply_result(:mark_absent, worker, {:ok, ref, text}) do
    settle(worker, ref, text)
    :ok
  end

  defp apply_result(:delete_storage, worker, {:ok, _ref}) do
    {:ok, _deleted} = Ankole.Ash.destroy(worker, :remove)
    :ok
  end

  defp apply_result(:delete_storage, worker, {:pending, ref}) do
    write(
      worker,
      :observe,
      [storage_ref: ref] ++ AgentWorker.error_fields("Waiting for storage deletion", "pending")
    )

    :ok
  end

  defp apply_result(_action, _worker, :ok), do: :ok
  defp apply_result(_action, _worker, {:error, _reason} = error), do: error

  defp unchanged_error({:error, _reason} = error), do: error
  defp unchanged_error(_result), do: :ok

  defp settle(worker, ref, reason) do
    write(worker, :settle,
      storage_ref: ref || worker.storage_ref,
      last_error: if(is_binary(reason), do: String.slice(reason, -4_000, 4_000)),
      last_error_kind: if(is_binary(reason), do: "transient")
    )
  end

  # The fields that a platform action depends on. Heartbeat, capacity and
  # load changes do not invalidate an observation or a call.
  defp lifecycle(worker),
    do:
      {worker.provider_id, worker.state, worker.generation, worker.instance_ref,
       worker.instance_seen_at, worker.storage_ref, worker.create_sent_at}

  defp current(facts),
    do: Enum.find(facts.objects, &ProviderKind.current_instance?(facts.worker, &1))

  defp wait_for_deletion(worker, object),
    do:
      write(worker, :observe,
        last_error:
          "Waiting for instance #{object.instance_ref || object.generation} to disappear",
        last_error_kind: "pending"
      )

  defp drain(worker, reason), do: write(worker, :drain, drain_reason: reason)

  defp write(worker, action, changes) do
    {:ok, updated} = Ankole.Ash.update(worker, action, Map.new(changes))
    updated
  end

  defp record_error(uid, reason, kind \\ "transient") do
    text = inspect(reason) |> String.slice(-4_000, 4_000)
    fields = Map.new(AgentWorker.error_fields(text, kind))

    case AgentWorker
         |> Ash.Query.filter(agent_uid == ^uid)
         |> Ankole.Ash.update_where(:record_error, fields) do
      {:ok, _workers} -> :ok
      {:error, error} -> raise error
    end

    AgentWorkers.notify_changed(uid)
    :ok
  end

  defp record_prepare_error(uid, provider_id, reason, kind) do
    {:ok, _worker} = AgentWorkers.record_prepare_error(uid, provider_id, inspect(reason), kind)
    :ok
  end

  @doc false
  def record_prepare_error_in_tx(%{agent_uid: uid, provider_id: provider_id} = input) do
    case AgentWorkers.lock_in_tx(Repo, uid) do
      %AgentWorker{state: :absent, provider_id: ^provider_id} = worker ->
        {:ok, write(worker, :observe, AgentWorker.error_fields(input.reason, input.kind))}

      _changed ->
        {:ok, nil}
    end
  end

  defp prepare_storage(kind, provider, uid) do
    case AgentWorkers.get_agent_worker!(uid) do
      %AgentWorker{state: :absent, provider_id: provider_id}
      when provider_id == provider.provider_id ->
        kind.prepare_storage(provider, uid)

      _changed ->
        :ok
    end
  end

  defp prepare_key(provider),
    do: {provider.provider_id, provider.runtime.image, provider.settings_digest}

  defp follow_up(uid, since, now) do
    if since && DateTime.diff(now, since, :millisecond) < 60_000,
      do: enqueue(uid, schedule_in: 2)

    :ok
  end
end
