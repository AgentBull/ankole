defmodule Ankole.AutomationJobs.Schemas.Run do
  @moduledoc """
  Durable execution ledger for one automation job trigger.
  """

  use Ankole.Ash.Resource,
    extensions: [AshStateMachine],
    tenancy: :tenant,
    domain: Ankole.AutomationJobs.Domain

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

    create :enqueue do
      primary?(true)
      transaction?(false)
      accept([:automation_job_id, :event])
      change(Ankole.Ash.RequireTransaction)
    end

    create :record_failed do
      transaction?(false)
      accept([:automation_job_id, :event, :finished_at, :error])
      change(Ankole.Ash.RequireTransaction)
      change(transition_state(:failed))
    end

    in_tx_update :wait_for_worker do
      accept([:worker_wait_started_at])
    end

    in_tx_update :start do
      accept([:attempt_id, :started_at, :finished_at, :error])
      change(atomic_update(:attempts, expr(attempts + 1)))
      change(transition_state(:running))
    end

    in_tx_update :settle do
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

    in_tx_update :retry do
      accept([:attempt_id, :error])
      change(transition_state(:queued))
    end

    in_tx_update :record_error do
      accept([:error])
    end

    atomic_in_tx_update :stop_human_work do
      accept([:attempt_id, :finished_at, :error])
      change(transition_state(:cancelled))
    end
  end
end
