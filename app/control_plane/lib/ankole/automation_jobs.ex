defmodule Ankole.AutomationJobs do
  @moduledoc """
  Owns Page Action Jobs, durable Runs, state and execution.

  Trigger domains keep their own claim and recurrence rules. Signals dispatches
  their events through Bindings and enqueues each destination job in the same
  transaction as the source claim and delivery receipts.

  Each top-level write operation owns its transaction and must be the top-level
  call. It gives `{:ok, value}` or `{:error, reason}`.
  """

  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.AutomationJobs.Schemas.Run

  @type enqueue_result :: %{
          required(:status) => :queued | :failed,
          required(:automation_job_run) => Run.t(),
          optional(:signal) => Ankole.Signals.Signal.t() | nil
        }

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/automation-jobs", Job do
        index(:console_list, name: "list_automation_jobs", derive_sort?: false)
      end

      base_route "/automation-jobs", Job do
        get(:read, name: "get_automation_job")
      end

      base_route "/automation-jobs/:automation_job_id/runs", Run do
        index(:console_list, name: "list_automation_job_runs", derive_sort?: false)
      end
    end
  end

  resources do
    resource(Ankole.AutomationJobs.Browser)

    resource Job do
      define(:get_automation_job, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_automation_jobs, action: :read)
    end

    resource Run do
      define(:list_automation_job_runs, action: :read)
    end

    resource(Ankole.AutomationJobs.Schemas.State)
  end

  defdelegate create_applet_job(actor, page_id, action_key, attrs),
    to: Ankole.AutomationJobs.Applet,
    as: :create

  defdelegate list_applet_jobs(actor, page_id), to: Ankole.AutomationJobs.Applet, as: :list
  defdelegate list_applet_actions(actor, page_id), to: Ankole.AutomationJobs.Applet, as: :actions

  defdelegate list_applet_runs(actor, page_id, job_id),
    to: Ankole.AutomationJobs.Applet,
    as: :runs

  defdelegate configure_applet_job(actor, page_id, id, attrs),
    to: Ankole.AutomationJobs.Applet,
    as: :configure

  defdelegate delete_applet_job(actor, page_id, id), to: Ankole.AutomationJobs.Applet, as: :delete
  defdelegate publish_run(id), to: Ankole.AutomationJobs.Applet
  defdelegate get_applet_run(actor, page_id, run_id), to: Ankole.AutomationJobs.Applet, as: :run

  defdelegate authorize_applet_job(actor, job, page_id, permission),
    to: Ankole.AutomationJobs.Applet,
    as: :authorize

  defdelegate prepare_applet_job(job, signal), to: Ankole.AutomationJobs.Applet, as: :prepare

  defdelegate start_applet_attempt(run_id, expected_slice),
    to: Ankole.AutomationJobs.Applet,
    as: :start_attempt

  defdelegate execute_applet_attempt(attempt), to: Ankole.AutomationJobs.Applet, as: :execute

  defdelegate defer_applet_attempt(attempt), to: Ankole.AutomationJobs.Applet, as: :defer_capacity

  defdelegate applet_attempt_authority(context, uid),
    to: Ankole.AutomationJobs.Applet,
    as: :authority

  defdelegate applet_state(context, operation, args), to: Ankole.AutomationJobs.Applet, as: :state

  defdelegate continue_applet_slice(context, options),
    to: Ankole.AutomationJobs.Applet,
    as: :continue_slice

  defdelegate sync_applet_policies_in_tx(page_id, actions),
    to: Ankole.AutomationJobs.Applet,
    as: :sync_policies_in_tx

  defdelegate purge_pages(ids), to: Ankole.AutomationJobs.Applet
  defdelegate purge_pages_in_tx(ids), to: Ankole.AutomationJobs.Applet

  defdelegate enqueue_locked_in_tx(job, event, opts),
    to: Ankole.AutomationJobs.Queue,
    as: :enqueue_in_tx

  defdelegate authorize_attempt_actor_in_tx(ref, ctx, opts \\ []),
    to: Ankole.AutomationJobs.AttemptAccess,
    as: :authorize_actor_in_tx

  defdelegate count_running_runs_for_human(uid, version), to: Ankole.AutomationJobs.Lifecycle
  defdelegate authorize_bindable_in_tx(actor, job_id), to: Ankole.AutomationJobs.Lifecycle
  defdelegate lock_job_in_tx(id), to: Ankole.AutomationJobs.Lifecycle
  defdelegate pending_run(id), to: Ankole.AutomationJobs.Lifecycle
  defdelegate finish_attempt(id, attempt, result, opts \\ []), to: Ankole.AutomationJobs.Lifecycle

  defdelegate infrastructure_failure(id, attempt, reason, disposition, opts \\ []),
    to: Ankole.AutomationJobs.Lifecycle

  defdelegate expire_attempts(opts \\ []), to: Ankole.AutomationJobs.Lifecycle
  defdelegate get_run_record(id), to: Ankole.AutomationJobs.Lifecycle
  defdelegate stop_human_work_in_tx(uid, version, now), to: Ankole.AutomationJobs.Lifecycle
end
