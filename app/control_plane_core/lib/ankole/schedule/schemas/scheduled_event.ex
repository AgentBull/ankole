defmodule Ankole.Schedule.Schemas.ScheduledEvent do
  @moduledoc """
  Concrete fire attempt shared by one-shot checkbacks and cron schedules.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Schedule,
    extensions: [AshStateMachine, AshJsonApi.Resource]

  use Ankole.Work.Provenance,
    owner_session?: false,
    source_signal?: true,
    reply_route?: false,
    kind: "scheduled_event",
    cleanup_key: "scheduled_events",
    review_states: [:scheduled, :failed, :cancelled],
    reauthorizable_states: [:scheduled, :failed],
    revoke_action: {Ankole.Schedule.Checkbacks, :stop_human_work_in_tx}

  @type status :: :scheduled | :fired | :cancelled | :failed

  @kinds ~w(check_back_later cron_fire)

  @create_fields [
    :authorization_kind,
    :human_uid,
    :human_access_version,
    :agent_uid,
    :kind,
    :session_id,
    :binding_name,
    :due_at,
    :timezone,
    :requested_at,
    :idempotency_key,
    :cron_schedule_id,
    :automation_job_id,
    :cron_fire_slot_at,
    :tool_call_id,
    :source_signal_id,
    :conversation_id,
    :provider_thread_id,
    :provider_message_id,
    :source_provenance,
    :wake_payload,
    :origin_ai_message_id,
    :last_fire_error
  ]

  @type t :: %__MODULE__{}

  postgres do
    table("scheduled_events")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(idempotency: "scheduled_events_idempotency_index")

    unique_index_names([
      {[:cron_schedule_id, :cron_fire_slot_at], "scheduled_events_cron_slot_index"}
    ])

    foreign_key_names([
      {:agent_uid, "scheduled_events_agent_uid_fkey"},
      {:cron_schedule_id, "scheduled_events_cron_schedule_id_fkey"},
      {:automation_job_id, "scheduled_events_automation_job_id_fkey"},
      {:automation_job_run_id, "scheduled_events_automation_job_run_id_fkey"},
      {:source_signal_id, "scheduled_events_source_signal_id_fkey"},
      {:conversation_id, "scheduled_events_conversation_id_fkey"},
      {:signal_id, "scheduled_events_signal_id_fkey"},
      {:origin_ai_message_id, "scheduled_events_origin_ai_message_id_fkey"}
    ])

    check_constraints do
      check_constraint(:authorization_kind, "scheduled_events_work_authorization_check")
      check_constraint(:kind, "scheduled_events_kind_check")
      check_constraint(:status, "scheduled_events_status_check")
      check_constraint(:timezone, "scheduled_events_timezone_present")
      check_constraint(:idempotency_key, "scheduled_events_idempotency_key_present")
      check_constraint(:source_provenance, "scheduled_events_source_provenance_object")
      check_constraint(:wake_payload, "scheduled_events_wake_payload_object")
      check_constraint(:last_fire_error, "scheduled_events_last_fire_error_object")
    end
  end

  attributes do
    attribute(:id, :integer,
      primary_key?: true,
      allow_nil?: false,
      generated?: true,
      public?: true
    )

    ash_attributes()
    attribute(:kind, :string, allow_nil?: false, public?: true)
    attribute(:session_id, :string, allow_nil?: false, public?: true)
    attribute(:binding_name, :string, public?: true)
    attribute(:due_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:timezone, :string, allow_nil?: false, public?: true)
    attribute(:requested_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:idempotency_key, :string, allow_nil?: false, public?: true)
    attribute(:cron_schedule_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:automation_job_id, :integer, public?: true)
    attribute(:automation_job_run_id, :integer, public?: true)
    attribute(:cron_fire_slot_at, :utc_datetime_usec, public?: true)
    attribute(:tool_call_id, :string, public?: true)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:provider_thread_id, :string, public?: true)
    attribute(:provider_message_id, :string, public?: true)

    attribute(:source_provenance, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    attribute(:wake_payload, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    attribute(:signal_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:origin_ai_message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:fired_at, :utc_datetime_usec, public?: true)
    attribute(:cancelled_at, :utc_datetime_usec, public?: true)

    attribute(:last_fire_error, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    timestamps(type: :utc_datetime_usec, public?: true)
  end

  identities do
    identity(:idempotency, [:kind, :agent_uid, :session_id, :idempotency_key], all_tenants?: true)
  end

  json_api do
    type("scheduled_event")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :id,
      :kind,
      :status,
      :agent_uid,
      :session_id,
      :binding_name,
      :due_at,
      :timezone,
      :requested_at,
      :idempotency_key,
      :cron_schedule_id,
      :automation_job_id,
      :automation_job_run_id,
      :cron_fire_slot_at,
      :tool_call_id,
      :origin_ai_message_id,
      :source_signal_id,
      :conversation_id,
      :provider_thread_id,
      :provider_message_id,
      :source_provenance,
      :wake_payload,
      :signal_id,
      :fired_at,
      :cancelled_at,
      :last_fire_error,
      :inserted_at,
      :updated_at
    ])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:scheduled, :cancelled])
    default_initial_state(:scheduled)

    transitions do
      transition(:fire, from: :scheduled, to: :fired)
      transition(:cancel, from: :scheduled, to: :cancelled)
      transition(:fail, from: :scheduled, to: :failed)
      transition(:reschedule, from: :scheduled, to: :scheduled)
      transition(:record_error, from: :scheduled, to: :scheduled)
    end
  end

  validations do
    validate(one_of(:kind, @kinds), on: [:create])
    validate(Ankole.TimeZone, on: [:create], only_when_valid?: true)
  end

  actions do
    defaults([:read])

    # The Console list of checkbacks: the latest due time first, of one Agent
    # or of all Agents.
    read :console_checkbacks do
      argument(:agent, Ankole.Ash.Types.PrincipalKey)

      filter(
        expr(kind == "check_back_later" and (is_nil(^arg(:agent)) or agent_uid == ^arg(:agent)))
      )

      prepare(build(sort: [due_at: :desc, inserted_at: :desc, id: :desc]))
      pagination(keyset?: true, default_limit: 100, max_page_size: 500, countable: false)
    end

    # The recent fires of one cron schedule of one Agent.
    read :console_cron_runs do
      argument(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
      argument(:cron_schedule_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      filter(expr(cron_schedule_id == ^arg(:cron_schedule_id) and agent_uid == ^arg(:agent_uid)))

      prepare(build(sort: [due_at: :desc, inserted_at: :desc, id: :desc]))
      pagination(keyset?: true, default_limit: 25, max_page_size: 100, countable: false)
    end

    action :console_cancel_checkback, :struct do
      constraints(instance_of: __MODULE__)
      argument(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)

      argument(:id, :integer,
        allow_nil?: false,
        constraints: [min: Ankole.ModelIntegerID.minimum(), max: Ankole.ModelIntegerID.maximum()]
      )

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Checkbacks.console_cancel_in_tx(input.arguments)
        |> Ankole.Errors.wrap()
      end)
    end

    action :create_check_back_later, :term do
      argument(:attrs, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Checkbacks.create_check_back_later_in_tx(args.attrs, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :update_checkback, :term do
      argument(:scheduled_event_id, :integer, allow_nil?: false)
      argument(:attrs, :term, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Checkbacks.update_checkback_in_tx(
          args.scheduled_event_id,
          args.attrs,
          args.opts
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :cancel_checkback, :term do
      argument(:scheduled_event_id, :integer, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Checkbacks.cancel_checkback_in_tx(args.scheduled_event_id, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :fire_due_event, :term do
      argument(:scheduled_event_id, :integer, allow_nil?: false)
      argument(:opts, :term, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Fire.fire_due_event_in_tx(args.scheduled_event_id, args.opts)
        |> Ankole.Errors.wrap()
      end)
    end

    action :record_fire_error, :term do
      allow_nil?(true)
      argument(:scheduled_event_id, :integer, allow_nil?: false)
      argument(:reason, :term)
      argument(:terminal, :boolean, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Schedule.Fire.record_fire_error_in_tx(
          args.scheduled_event_id,
          args.reason,
          args.terminal
        )
        |> Ankole.Errors.wrap()
      end)
    end

    update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    create :create_event do
      primary?(true)
      accept(@create_fields)
    end

    create :record_cancelled do
      accept(@create_fields)
      argument(:cancelled_at, :utc_datetime_usec, allow_nil?: false)
      change(transition_state(:cancelled))
      change(set_attribute(:cancelled_at, arg(:cancelled_at)))
    end

    create :schedule_event do
      accept(@create_fields)
      upsert?(true)
      upsert_identity(:idempotency)
      upsert_fields([:idempotency_key])
    end

    update :fire do
      accept([:signal_id, :automation_job_run_id, :fired_at, :last_fire_error])
      change(transition_state(:fired))
    end

    update :cancel do
      accept([:cancelled_at, :last_fire_error])
      change(transition_state(:cancelled))
    end

    update :fail do
      accept([:last_fire_error])
      change(transition_state(:failed))
    end

    update :reschedule do
      accept([
        :wake_payload,
        :due_at,
        :timezone,
        :automation_job_id,
        :binding_name,
        :conversation_id,
        :provider_thread_id,
        :provider_message_id,
        :last_fire_error
      ])

      change(transition_state(:scheduled))
      validate(Ankole.TimeZone, where: [changing(:timezone)], only_when_valid?: true)
    end

    update :record_error do
      accept([:last_fire_error])
      change(transition_state(:scheduled))
    end
  end
end
