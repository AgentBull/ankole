defmodule Ankole.AutomationJobs.Applet do
  @moduledoc "Applet-backed Jobs, their current code, and per-attempt state capabilities."
  require Ash.Query
  alias Ankole.{AutomationJobs, Repo, Pod}
  alias Ankole.AuthZ.Actor
  alias Ankole.AutomationJobs.{AttemptRef, Queue}
  alias Ankole.AutomationJobs.Schemas.{Job, Run, State}
  alias Ankole.Principals.WorkAccess

  def create(actor, page_id, action_key, attrs) do
    kind = Ankole.Attrs.get(attrs, :authorization_kind, "human")
    permission = if kind == "service", do: "node_edit", else: "node_contribute"

    with {:ok, _} <- Pod.authorize_applet(actor, page_id, permission),
         {:ok, package} <- Pod.applet_action_package(page_id),
         {:ok, policy} <- policy(package, action_key) do
      authorization =
        if kind == "service",
          do: WorkAccess.service(),
          else: WorkAccess.from_sender(Actor.uid(actor))

      Repo.transact_top_level(fn ->
        with :ok <- WorkAccess.check_in_tx(authorization),
             :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority, lock: false),
             _ <- lock_page_jobs(page_id),
             {:ok, job} <-
               Ankole.Ash.create(
                 Job,
                 :create,
                 Map.merge(authorization, policy_attrs(policy))
                 |> Map.merge(%{
                   page_id: page_id,
                   action_key: action_key,
                   config: Ankole.Attrs.get(attrs, :config, %{}),
                   label: Ankole.Attrs.get(attrs, :label, action_key)
                 })
               ),
             :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
             {:ok, _} <- Pod.verify_applet_package_in_tx(package),
             do: {:ok, job}
      end)
    end
  end

  def authorize(actor, job, page_id, permission) do
    with true <- job.page_id == page_id,
         true <-
           job.authorization_kind != "human" or
             job.human_uid == Ankole.Principals.authority_uid(Actor.uid(actor)),
         {:ok, _} <- Pod.authorize_applet(actor, page_id, permission),
         do: :ok,
         else: (_ -> {:error, :forbidden})
  end

  def list(actor, page_id) do
    with {:ok, _} <- Pod.authorize_applet(actor, page_id, "node_view") do
      uid = Ankole.Principals.authority_uid(Actor.uid(actor))

      Job
      |> Ash.Query.filter(
        page_id == ^page_id and (authorization_kind != "human" or human_uid == ^uid)
      )
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read()
    end
  end

  def actions(actor, page_id) do
    with {:ok, _} <- Pod.authorize_applet(actor, page_id, "node_view"),
         {:ok, package} <- Pod.applet_action_package(page_id) do
      {:ok, package.actions |> Map.keys() |> Enum.sort()}
    else
      # An Applet published without server/main.js has no backend and therefore no Actions.
      {:error, :route_not_found} -> {:ok, []}
      {:error, %{"code" => "applet_busy"}} -> {:error, :applet_busy}
      error -> error
    end
  end

  def runs(actor, page_id, job_id) do
    with {:ok, %Job{} = job} <- AutomationJobs.get_automation_job(job_id),
         :ok <- authorize(actor, job, page_id, "node_view") do
      Run
      |> Ash.Query.filter(automation_job_id == ^job.id)
      |> Ash.Query.sort(id: :desc)
      |> Ash.Query.limit(100)
      |> Ankole.Ash.read()
    else
      {:ok, nil} -> {:error, :not_found}
      error -> error
    end
  end

  def configure(actor, page_id, id, attrs) do
    mutate(actor, page_id, id, fn job ->
      Ankole.Ash.update(
        job,
        :configure,
        Map.take(Ankole.Attrs.normalize_external_attrs(attrs), ~w(config label))
      )
    end)
  end

  def delete(actor, page_id, id) do
    Repo.transact_top_level(fn ->
      with :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority, lock: false),
           {:ok, %Job{} = job} <- AutomationJobs.get_automation_job(id),
           :ok <-
             authorize(
               actor,
               job,
               page_id,
               if(job.authorization_kind == "human", do: "node_contribute", else: "node_edit")
             ),
           :ok <- Ankole.AutomationJobs.JobSources.purge_in_tx([id]),
           :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
           do: {:ok, job},
           else: (
             {:ok, nil} -> {:error, :not_found}
             error -> error
           )
    end)
  end

  defp mutate(actor, page_id, id, fun) do
    Repo.transact_top_level(fn ->
      with :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority, lock: false),
           %Job{} = job <- AutomationJobs.lock_job_in_tx(id),
           :ok <-
             authorize(
               actor,
               job,
               page_id,
               if(job.authorization_kind == "human", do: "node_contribute", else: "node_edit")
             ),
           {:ok, result} <- fun.(job),
           :ok <- Ankole.AuthZ.authorize_turn_in_tx(actor.turn_authority),
           do: {:ok, result},
           else: (
             nil -> {:error, :not_found}
             error -> error
           )
    end)
  end

  def publish_run(id) do
    case Run |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!() do
      nil ->
        :ok

      run ->
        Phoenix.PubSub.broadcast(
          Ankole.PubSub,
          "pod-room:run:#{id}",
          {:room_event, "changed", Ankole.Pod.Serialization.json_value(run)}
        )
    end
  end

  def run(actor, page_id, run_id) do
    with %Run{} = run <- Run |> Ash.Query.filter(id == ^run_id) |> Ankole.Ash.read_one!(),
         {:ok, %Job{} = job} <- AutomationJobs.get_automation_job(run.automation_job_id),
         :ok <- authorize(actor, job, page_id, "node_view"),
         do: {:ok, run},
         else: (
           nil -> {:error, :not_found}
           error -> error
         )
  end

  def prepare(%{concurrency_mode: :parallel}, _signal), do: {:ok, "default"}

  def prepare(job, signal) do
    context = %{actionKey: job.action_key, job: %{id: job.id, config: job.config}, signal: signal}

    with {:ok, package} <- Pod.applet_action_package(job.page_id, [context]),
         {:ok, _} <- policy(package, job.action_key) do
      {:ok, package.concurrency_keys[to_string(job.id)] || "default"}
    else
      {:error, reason}
      when reason in [
             :missing_action_key,
             :page_trashed,
             :applet_owner_required,
             :applet_owner_unavailable,
             :route_not_found
           ] ->
        {:ok, "default"}

      error ->
        error
    end
  end

  def start_attempt(run_id, expected_slice) do
    with %Run{} = snapshot <- Run |> Ash.Query.filter(id == ^run_id) |> Ankole.Ash.read_one!(),
         {:ok, %Job{} = job} <- AutomationJobs.get_automation_job(snapshot.automation_job_id) do
      package = Pod.applet_action_package(job.page_id)

      Repo.transact_top_level(fn -> admit(job, run_id, expected_slice, package) end,
        after_commit: fn _ -> publish_run(run_id) end
      )
    else
      _ -> {:error, :automation_job_run_not_found}
    end
  end

  defp admit(snapshot, run_id, expected_slice, package) do
    owner_uid =
      case package do
        {:ok, package} -> package.owner_uid
        _ -> nil
      end

    {:ok, _} =
      Ankole.Principals.lock_principals_in_tx(
        Enum.filter([snapshot.human_uid, owner_uid], &is_binary/1)
      )

    access = WorkAccess.check_in_tx(snapshot)
    job = AutomationJobs.lock_job_in_tx(snapshot.id)

    run =
      Run
      |> Ash.Query.filter(id == ^run_id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"automation_job_runs", run_id})

    cond do
      is_nil(job) or is_nil(run) or run.status != :queued -> {:ok, :noop}
      not Queue.startable?(job, run, expected_slice) -> {:ok, :noop}
      job.status != :active -> cancel(job, run, "automation job is #{job.status}")
      access == {:error, :human_access_revoked} -> cancel(job, run, "human_access_revoked")
      access != :ok -> fail(job, run, :work_authorization_review_required)
      true -> admit_package(job, run, package)
    end
  end

  defp admit_package(job, run, {:ok, package}) do
    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
         {:ok, _} <- Pod.verify_applet_package_in_tx(package),
         {:ok, policy} <- policy(package, job.action_key) do
      now = DateTime.utc_now(:microsecond)

      with {:ok, run} <-
             Ankole.Ash.update(run, :start, %{
               attempt_id: Ash.UUIDv7.generate(),
               started_at: now,
               finished_at: nil,
               error: nil,
               attempt_idempotent: policy["idempotent"],
               last_published_revision: package.revision,
               attempt_deadline_at:
                 DateTime.add(now, package.limits[:timeout_ms] + 10_000, :millisecond)
             }),
           do: {:ok, %{automation_job: job, run: run, package: package}}
    else
      {:error, :applet_revision_changed} = error -> error
      {:error, reason} -> fail(job, run, reason)
    end
  end

  defp admit_package(job, run, {:error, :applet_owner_required}),
    do: fail(job, run, :applet_owner_unavailable)

  defp admit_package(_job, _run, {:error, %{"code" => "applet_busy"}}),
    do: {:error, :applet_busy}

  defp admit_package(job, run, {:error, reason}), do: fail(job, run, reason)

  defp cancel(job, run, reason) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _} <-
           if(job.status == :active,
             do: Ankole.Ash.update(job, :cancel, %{cancelled_at: now}),
             else: {:ok, job}
           ),
         {:ok, _} <-
           Run
           |> Ash.Query.filter(automation_job_id == ^job.id and status == :queued)
           |> Ankole.Ash.update_where(:stop_human_work, %{
             attempt_id: nil,
             finished_at: now,
             error: reason
           }),
         :ok <- Queue.wake_next(job, run),
         do: {:ok, :noop}
  end

  defp fail(job, run, reason) do
    with {:ok, run} <-
           Ankole.Ash.update(run, :settle, %{
             status: :failed,
             finished_at: DateTime.utc_now(:microsecond),
             error: error_code(reason),
             attempt_id: nil
           }),
         :ok <- Queue.wake_next(job, run),
         do: {:ok, :noop}
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(reason), do: inspect(reason)

  def defer_capacity(%{automation_job: job, run: run}) do
    Repo.transact_top_level(
      fn ->
        with {:ok, _job, current} <- lock_attempt(job.id, run.id, run.attempt_id),
             do: Ankole.Ash.update(current, :defer_capacity, %{})
      end,
      after_commit: fn _ -> publish_run(run.id) end
    )
  end

  def execute(%{automation_job: job, run: run, package: package}) do
    {:ok, timezone} = Ankole.SystemConfig.timezone()

    context = %{
      "actionKey" => job.action_key,
      "canContinueSlice" => true,
      "job" => %{"id" => job.id, "config" => job.config},
      "run" => %{
        "id" => run.id,
        "attemptId" => run.attempt_id,
        "sliceCount" => run.slice_count,
        "progress" => run.progress
      },
      "signal" => run.event,
      "applet" => %{"pageId" => job.page_id, "revision" => package.revision},
      "timezone" => timezone,
      "read_only" => false
    }

    actor =
      if job.authorization_kind == "human" do
        {:ok, principal} = Ankole.Principals.get_principal(job.human_uid)
        Actor.new(principal, turn_authority: authority(context, principal.uid))
      end

    context = Map.put(context, "principal", if(actor, do: %{uid: job.human_uid, kind: "human"}))
    Pod.invoke_applet_action(package, context, actor)
  end

  def authority(%{"job" => %{"id" => job}, "run" => %{"id" => run, "attemptId" => attempt}}, uid),
    do: {%AttemptRef{job_id: job, run_id: run, attempt_id: attempt, principal_uid: uid}, uid}

  def authority(_, _), do: nil

  def state(context, operation, args) do
    with :ok <- state_keys(args),
         {:ok, job_id, run_id, attempt_id} <- attempt(context) do
      Repo.transact_top_level(fn ->
        with {:ok, _job, _run} <- lock_attempt(job_id, run_id, attempt_id),
             do: state_in_tx(job_id, operation, args)
      end)
    end
  end

  defp state_keys([scope, key | _]) when is_binary(scope) and is_binary(key) do
    if String.length(scope) in 1..255 and String.length(key) in 1..255,
      do: :ok,
      else: {:error, :invalid_state_key}
  end

  defp state_keys(_), do: {:error, :invalid_state_key}

  defp state_in_tx(job_id, "set", [scope, key, value]) do
    if byte_size(Torque.encode!(value)) <= 65536 do
      with {:ok, _} <-
             Ankole.Ash.create(State, :put, %{
               automation_job_id: job_id,
               scope_key: scope,
               state_key: key,
               value: value,
               updated_at: DateTime.utc_now(:microsecond)
             }),
           do: {:ok, nil}
    else
      {:error, :state_too_large}
    end
  end

  defp state_in_tx(job_id, "get", [scope, key]) do
    state =
      State
      |> Ash.Query.filter(
        automation_job_id == ^job_id and scope_key == ^scope and state_key == ^key
      )
      |> Ankole.Ash.read_one!()

    {:ok, state && state.value}
  end

  defp state_in_tx(job_id, "delete", [scope, key]) do
    with {:ok, _} <-
           State
           |> Ash.Query.filter(
             automation_job_id == ^job_id and scope_key == ^scope and state_key == ^key
           )
           |> Ankole.Ash.destroy_where(:remove),
         do: {:ok, nil}
  end

  defp state_in_tx(_, _, _), do: {:error, :invalid_request}

  def continue_slice(context, options, logs \\ [])

  def continue_slice(context, options, logs) when is_map(options) do
    delay = Map.get(options, "delaySeconds", 0)
    progress = Map.get(options, "progress", %{})

    with true <- is_integer(delay) and delay >= 0 and is_map(progress),
         {:ok, job_id, run_id, attempt_id} <- attempt(context) do
      Repo.transact_top_level(
        fn ->
          with {:ok, job, run} <- lock_attempt(job_id, run_id, attempt_id),
               true <- run.slice_count + 1 < job.max_slices,
               {:ok, run} <-
                 Ankole.Ash.update(
                   run,
                   :continue_slice,
                   Map.put(
                     Ankole.AutomationJobs.Lifecycle.append_logs(run, logs),
                     :progress,
                     progress
                   )
                 ),
               :ok <- Queue.insert(run, delay_seconds: delay),
               do: {:ok, %{continued: true, runId: run.id}},
               else: (
                 false -> {:error, :max_slices_exceeded}
                 error -> error
               )
        end,
        after_commit: fn _ -> publish_run(run_id) end
      )
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def continue_slice(_context, _options, _logs), do: {:error, :invalid_request}

  defp attempt(%{"job" => %{"id" => job}, "run" => %{"id" => run, "attemptId" => attempt}}),
    do: {:ok, job, run, attempt}

  defp attempt(_), do: {:error, :action_attempt_required}

  defp lock_attempt(job_id, run_id, attempt_id) do
    with %Job{} = job <- AutomationJobs.lock_job_in_tx(job_id),
         %Run{status: :running, attempt_id: ^attempt_id} = run <-
           Run
           |> Ash.Query.filter(id == ^run_id and automation_job_id == ^job_id)
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!(lock_identity: {"automation_job_runs", run_id}) do
      {:ok, job, run}
    else
      _ -> {:error, :automation_job_attempt_not_active}
    end
  end

  def sync_policies_in_tx(page_id, actions) do
    jobs = lock_page_jobs(page_id)

    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      attrs =
        case Map.fetch(actions, job.action_key) do
          {:ok, policy} -> Map.put(policy_attrs(policy), :unavailable_reason, nil)
          :error -> %{unavailable_reason: "missing_action_key"}
        end

      with {:ok, current} <- Ankole.Ash.update(job, :publish_policy, attrs),
           :ok <- Queue.policy_changed(job, current) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  def lock_page_jobs(page_id) do
    Ankole.AdvisoryLock.lock(Repo, "applet-jobs:" <> page_id)

    Job
    |> Ash.Query.filter(page_id == ^page_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "automation_jobs", :id})
  end

  def purge_pages(ids) do
    Repo.transact_top_level(fn -> with :ok <- purge_pages_in_tx(ids), do: {:ok, :ok} end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  def purge_pages_in_tx(ids) do
    :ok = Repo.require_transaction()
    Enum.each(Enum.sort(ids), &Ankole.AdvisoryLock.lock(Repo, "applet-jobs:" <> &1))

    ids =
      Job
      |> Ash.Query.filter(page_id in ^ids)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)

    Ankole.AutomationJobs.JobSources.purge_in_tx(ids)
  end

  defp policy(package, key) do
    case Map.fetch(package.actions, key) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, :missing_action_key}
    end
  end

  defp policy_attrs(policy),
    do: %{
      idempotent: policy["idempotent"],
      concurrency_mode: policy["concurrency"],
      max_slices: policy["maxSlices"]
    }
end
