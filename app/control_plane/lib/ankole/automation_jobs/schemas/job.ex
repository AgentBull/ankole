defmodule Ankole.AutomationJobs.Schemas.Job do
  @moduledoc """
  Durable Page-owned Applet Action, its execution policy and authorization.
  """

  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension, AshStateMachine, AshJsonApi.Resource],
    tenancy: :tenant,
    domain: Ankole.AutomationJobs

  authz do
    scope(:site_console)
    allow(:console_list, resource: "site_console:automation_jobs", action: "read")
    allow(:read, resource: "site_console:automation_jobs", action: "read")
  end

  use Ankole.Work.Provenance,
    agent?: false,
    owner_session?: false,
    source_signal?: true,
    reply_route?: false,
    kind: "automation_job",
    cleanup_key: "automation_runs",
    review_states: [:active, :cancelled],
    reauthorizable_states: [:active],
    revoke_action: {Ankole.AutomationJobs, :stop_human_work_in_tx}

  @type t :: %__MODULE__{}

  postgres do
    table("automation_jobs")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:source_signal_id, "automation_jobs_source_signal_id_fkey"}
    ])

    check_constraints do
      check_constraint(:authorization_kind, "automation_jobs_work_authorization_check")
      check_constraint(:id, "automation_jobs_id_range")
      check_constraint(:status, "automation_jobs_status_check")
      check_constraint(:label, "automation_jobs_label_present")
      check_constraint(:source_provenance, "automation_jobs_source_provenance_object")
      check_constraint(:status, "automation_jobs_terminal_time_check")
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

    attribute(:source_provenance, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false, public?: true)
    attribute(:action_key, :string, allow_nil?: false, public?: true)
    attribute(:config, Ankole.Ash.Types.JSONMap, default: %{}, allow_nil?: false, public?: true)
    attribute(:idempotent, :boolean, default: false, allow_nil?: false, public?: true)

    attribute(:concurrency_mode, :atom,
      default: :parallel,
      allow_nil?: false,
      constraints: [one_of: [:parallel, :serial_fifo, :serial_coalesce]],
      public?: true
    )

    attribute(:max_slices, :integer,
      default: 1000,
      allow_nil?: false,
      constraints: [min: 1, max: 100_000],
      public?: true
    )

    attribute(:unavailable_reason, :string, public?: true)

    attribute(:label, :string,
      allow_nil?: false,
      constraints: [max_length: 500, length_count: :graphemes],
      public?: true
    )

    attribute(:cancelled_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec, public?: true)
  end

  relationships do
    has_many :runs, Ankole.AutomationJobs.Schemas.Run do
      destination_attribute(:automation_job_id)
    end
  end

  json_api do
    type("automation_job")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :id,
      :authorization_kind,
      :human_uid,
      :page_id,
      :action_key,
      :config,
      :idempotent,
      :concurrency_mode,
      :max_slices,
      :unavailable_reason,
      :source_signal_id,
      :source_provenance,
      :label,
      :status,
      :cancelled_at,
      :inserted_at,
      :updated_at
    ])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:active])
    default_initial_state(:active)

    transitions do
      transition(:cancel, from: :active, to: :cancelled)
      transition(:stop_human_work, from: :active, to: :cancelled)
    end
  end

  actions do
    defaults([:read])

    # Console lists the tenant’s Page-owned Jobs, newest first.
    read :console_list do
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
      pagination(keyset?: true, default_limit: 100, max_page_size: 500, countable: false)
    end

    create :create do
      primary?(true)

      accept([
        :authorization_kind,
        :human_uid,
        :human_access_version,
        :page_id,
        :action_key,
        :config,
        :idempotent,
        :concurrency_mode,
        :max_slices,
        :source_signal_id,
        :source_provenance,
        :label
      ])
    end

    update :cancel do
      accept([:cancelled_at])
      change(transition_state(:cancelled))
    end

    update :publish_policy do
      accept([:idempotent, :concurrency_mode, :max_slices, :unavailable_reason])
    end

    update :configure do
      accept([:config, :label])
    end

    destroy(:remove)

    update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    update :stop_human_work do
      require_atomic?(true)
      accept([:cancelled_at])
      change(transition_state(:cancelled))
    end
  end
end
