defmodule Ankole.AutomationJobs.Schemas.Run do
  @moduledoc """
  Durable execution ledger for one automation job trigger.
  """

  use Ankole.Ash.Resource,
    extensions: [AshStateMachine, AshJsonApi.Resource],
    tenancy: :tenant,
    domain: Ankole.AutomationJobs

  @type t :: %__MODULE__{}

  postgres do
    table("automation_job_runs")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:automation_job_id, "automation_job_runs_automation_job_id_fkey"}])

    check_constraints do
      check_constraint(:id, "automation_job_runs_id_range")
      check_constraint(:status, "automation_job_runs_status_check")
      check_constraint(:attempts, "automation_job_runs_attempts_nonnegative")
      check_constraint(:event, "automation_job_runs_event_object")
      check_constraint(:stdout, "automation_job_runs_logs_bounded")
      check_constraint(:status, "automation_job_runs_lifecycle_check")
    end
  end

  attributes do
    attribute(:id, :integer,
      primary_key?: true,
      allow_nil?: false,
      generated?: true,
      public?: true
    )

    attribute(:automation_job_id, :integer, allow_nil?: false, public?: true)
    attribute(:event, Ankole.Ash.Types.JSONMap, allow_nil?: false, public?: true)

    attribute(:attempts, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true
    )

    attribute(:attempt_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:worker_wait_started_at, :utc_datetime_usec, public?: true)
    attribute(:finished_at, :utc_datetime_usec, public?: true)
    attribute(:exit_code, :integer, public?: true)

    attribute(:error, :string,
      constraints: [trim?: false, max_length: 65_536, length_count: :bytes],
      public?: true
    )

    attribute(:stdout, :string,
      default: "",
      constraints: [trim?: false, allow_empty?: true, max_length: 65_536, length_count: :bytes],
      public?: true
    )

    attribute(:stderr, :string,
      default: "",
      constraints: [trim?: false, allow_empty?: true, max_length: 65_536, length_count: :bytes],
      public?: true
    )

    attribute(:stdout_truncated, :boolean, default: false, allow_nil?: false, public?: true)
    attribute(:stderr_truncated, :boolean, default: false, allow_nil?: false, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    belongs_to :job, Ankole.AutomationJobs.Schemas.Job do
      source_attribute(:automation_job_id)
      attribute_type(:integer)
      define_attribute?(false)
    end
  end

  # The definition facts of the Console activity projection, read in the
  # same query as the run.
  calculations do
    calculate(:job_agent_uid, :string, expr(job.agent_uid))
    calculate(:job_label, :string, expr(job.label))
    calculate(:job_owner_session_id, :string, expr(job.owner_session_id))
    calculate(:job_status, :atom, expr(job.status))
  end

  json_api do
    type("automation_job_run")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :automation_job_id,
      :status,
      :attempts,
      :started_at,
      :finished_at,
      :exit_code,
      :error,
      :stdout,
      :stdout_truncated,
      :stderr,
      :stderr_truncated
    ])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:queued, :failed])
    default_initial_state(:queued)

    transitions do
      transition(:start, from: :queued, to: :running)
      transition(:settle, from: [:queued, :running], to: :failed)
      transition(:settle, from: :running, to: :succeeded)
      transition(:retry, from: :running, to: :queued)
      transition(:stop_human_work, from: :queued, to: :cancelled)
    end
  end

  actions do
    defaults([:read])

    read :across_tenants do
      multitenancy(:allow_global)
    end

    # The Console run history of one job of one Agent, the newest run first.
    read :console_list do
      argument(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
      argument(:automation_job_id, :integer, allow_nil?: false)

      filter(
        expr(automation_job_id == ^arg(:automation_job_id) and job.agent_uid == ^arg(:agent_uid))
      )

      prepare(build(sort: [inserted_at: :desc, id: :desc]))
      pagination(keyset?: true, default_limit: 20, max_page_size: 100, countable: false)
    end

    action :start_attempt, :term do
      argument(:run_id, :integer, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)
      argument(:ready_timeout_ms, :integer, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.AutomationJobs.start_attempt_in_tx(args.run_id, args.now, args.ready_timeout_ms)
        |> Ankole.Errors.wrap()
      end)
    end

    action :finish_attempt, :term do
      argument(:run_id, :integer, allow_nil?: false)
      argument(:attempt_id, :term, allow_nil?: false)
      argument(:result, :term, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.AutomationJobs.finish_attempt_in_tx(
          args.run_id,
          args.attempt_id,
          args.result,
          args.now
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :infrastructure_failure, :term do
      argument(:run_id, :integer, allow_nil?: false)
      argument(:attempt_id, :term, allow_nil?: false)
      argument(:error, :term, allow_nil?: false)

      argument(:disposition, :atom,
        allow_nil?: false,
        constraints: [one_of: [:retry, :exhausted]]
      )

      argument(:now, :utc_datetime_usec, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.AutomationJobs.infrastructure_failure_in_tx(
          args.run_id,
          args.attempt_id,
          args.error,
          args.disposition,
          args.now
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :emit_event, :term do
      argument(:agent_uid, :term, allow_nil?: false)
      argument(:run_id, :integer, allow_nil?: false)
      argument(:attempt_id, :term, allow_nil?: false)
      argument(:payload, :term)
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.AutomationJobs.emit_event_in_tx(
          args.agent_uid,
          args.run_id,
          args.attempt_id,
          args.payload,
          args.now
        )
        |> Ankole.Errors.wrap()
      end)
    end

    create :enqueue do
      primary?(true)
      accept([:automation_job_id, :event])
    end

    create :record_failed do
      accept([:automation_job_id, :event, :finished_at, :error])
      change(transition_state(:failed))
    end

    update :wait_for_worker do
      accept([:worker_wait_started_at])
    end

    update :start do
      accept([:attempt_id, :started_at, :finished_at, :error])
      change(atomic_update(:attempts, expr(attempts + 1)))
      change(transition_state(:running))
    end

    update :settle do
      argument(:status, :atom, allow_nil?: false, constraints: [one_of: [:failed, :succeeded]])
      change(transition_state(arg(:status)))

      accept([
        :attempt_id,
        :finished_at,
        :exit_code,
        :error,
        :stdout,
        :stderr,
        :stdout_truncated,
        :stderr_truncated
      ])
    end

    update :retry do
      accept([:attempt_id, :error])
      change(transition_state(:queued))
    end

    update :record_error do
      accept([:error])
    end

    update :stop_human_work do
      require_atomic?(true)
      accept([:attempt_id, :finished_at, :error])
      change(transition_state(:cancelled))
    end
  end
end
