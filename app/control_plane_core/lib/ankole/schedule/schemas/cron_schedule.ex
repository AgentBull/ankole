defmodule Ankole.Schedule.Schemas.CronSchedule do
  @moduledoc """
  Durable recurring schedule definition.

  `owner_session_id` is the management scope: the conversation that created
  the schedule lists and mutates it. Fires do not run there; they run in the
  derived execution session `Ankole.Schedule.Cron.execution_session_id/1`.
  """

  use Ankole.Ash.Resource,
    extensions: [AshStateMachine],
    tenancy: :tenant,
    domain: Ankole.Schedule

  use Ankole.Work.Provenance,
    owner_session?: true,
    kind: "cron",
    cleanup_key: "cron",
    review_states: [:active, :paused],
    reauthorizable_states: [:active, :paused],
    revoke_action: {Ankole.Schedule.Cron, :stop_human_work_in_tx}

  @type t :: %__MODULE__{}

  postgres do
    table("cron_schedules")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "cron_schedules_agent_uid_fkey"},
      {:automation_job_id, "cron_schedules_automation_job_id_fkey"}
    ])

    check_constraints do
      check_constraint(:authorization_kind, "cron_schedules_work_authorization_check")
      check_constraint(:status, "cron_schedules_status_check")
      check_constraint(:next_fire_at, "cron_schedules_live_deadline_check")
      check_constraint(:timezone, "cron_schedules_timezone_present")
      check_constraint(:name, "cron_schedules_name_present")
      check_constraint(:idempotency_key, "cron_schedules_idempotency_key_present")
      check_constraint(:schedule, "cron_schedules_schedule_object")
      check_constraint(:payload, "cron_schedules_payload_object")
      check_constraint(:delivery, "cron_schedules_delivery_object")
      check_constraint(:created_by, "cron_schedules_created_by_object")
    end

    identity_index_names(idempotency: "cron_schedules_idempotency_index")

    unique_index_names([
      {[:agent_uid, :owner_session_id, :name], "cron_schedules_agent_name_index"}
    ])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0,
      public?: true
    )

    ash_attributes()
    attribute(:binding_name, :string, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:schedule, Ankole.Ash.Types.JSONMap, default: %{}, allow_nil?: false, public?: true)
    attribute(:timezone, :string, allow_nil?: false, public?: true)
    attribute(:payload, Ankole.Ash.Types.JSONMap, default: %{}, allow_nil?: false, public?: true)
    attribute(:delivery, Ankole.Ash.Types.JSONMap, public?: true)
    attribute(:next_fire_at, :utc_datetime_usec, public?: true)
    attribute(:last_fire_at, :utc_datetime_usec, public?: true)
    attribute(:idempotency_key, :string, allow_nil?: false, public?: true)

    attribute(:created_by, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true
    )

    attribute(:automation_job_id, :integer, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  identities do
    identity(:idempotency, [:agent_uid, :owner_session_id, :idempotency_key], all_tenants?: true)
  end

  state_machine do
    state_attribute(:status)
    initial_states([:active, :paused])
    default_initial_state(:active)

    transitions do
      transition(:pause, from: :active, to: :paused)
      transition(:resume, from: :paused, to: :active)
      transition(:delete, from: [:active, :paused, :completed], to: :deleted)
      transition(:complete, from: [:active, :paused], to: :completed)
      transition(:stop_human_work, from: :active, to: :paused)
    end
  end

  actions do
    defaults([:read])

    action :create_cron_schedule, :term do
      argument(:attrs, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Cron.create_cron_schedule_in_tx(args.attrs, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :update_cron_schedule, :term do
      argument(:cron_schedule_id, :term, allow_nil?: false)
      argument(:attrs, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Cron.update_cron_schedule_in_tx(
          args.cron_schedule_id,
          args.attrs,
          args.opts
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :pause_cron_schedule, :term do
      argument(:cron_schedule_id, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Cron.pause_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :resume_cron_schedule, :term do
      argument(:cron_schedule_id, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Cron.resume_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :remove_cron_schedule, :term do
      argument(:cron_schedule_id, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Cron.remove_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :run_cron_schedule, :term do
      argument(:cron_schedule_id, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Cron.run_cron_schedule_in_tx(args.cron_schedule_id, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :fire_cron, :term do
      argument(:cron_schedule_id, :term, allow_nil?: false)
      argument(:now, :term, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Fire.fire_cron_in_tx(args.cron_schedule_id, args.now)
        |> Ankole.Errors.wrap()
      end)
    end

    action :record_fire_failure, :term do
      allow_nil?(true)
      argument(:cron_schedule_id, :term, allow_nil?: false)
      argument(:slot, :term, allow_nil?: false)
      argument(:reason, :term)
      argument(:now, :term, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Fire.record_fire_failure_in_tx(
          args.cron_schedule_id,
          args.slot,
          args.reason,
          args.now
        )
        |> Ankole.Errors.wrap()
      end)
    end

    create :create do
      primary?(true)
      upsert?(true)
      upsert_identity(:idempotency)
      upsert_fields([:idempotency_key])

      accept([
        :id,
        :authorization_kind,
        :human_uid,
        :human_access_version,
        :status,
        :agent_uid,
        :owner_session_id,
        :binding_name,
        :name,
        :schedule,
        :timezone,
        :payload,
        :delivery,
        :next_fire_at,
        :last_fire_at,
        :idempotency_key,
        :created_by,
        :automation_job_id
      ])

      validate(Ankole.TimeZone, where: [changing(:timezone)], only_when_valid?: true)
    end

    update :update_definition do
      validate(Ankole.TimeZone, where: [changing(:timezone)], only_when_valid?: true)

      accept([
        :binding_name,
        :name,
        :schedule,
        :timezone,
        :payload,
        :delivery,
        :automation_job_id
      ])
    end

    update :pause do
      accept([])
      change(transition_state(:paused))
      change(set_attribute(:next_fire_at, nil))
    end

    update :resume do
      accept([])
      change(transition_state(:active))
    end

    update :delete do
      accept([])
      change(transition_state(:deleted))
      change(set_attribute(:next_fire_at, nil))
    end

    update :complete do
      accept([])
      change(transition_state(:completed))
      change(set_attribute(:next_fire_at, nil))
    end

    update :schedule_fire do
      accept([:next_fire_at])
    end

    update :record_fire do
      accept([:last_fire_at])
    end

    update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    update :stop_human_work do
      require_atomic?(true)
      accept([])
      change(transition_state(:paused))
      change(set_attribute(:next_fire_at, nil))
    end
  end
end
