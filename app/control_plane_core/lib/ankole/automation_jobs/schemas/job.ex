defmodule Ankole.AutomationJobs.Schemas.Job do
  @moduledoc """
  Durable definition of one Agent-owned automation script.
  """

  use Ankole.Ash.Resource,
    extensions: [AshStateMachine, AshJsonApi.Resource],
    tenancy: :tenant,
    domain: Ankole.AutomationJobs

  use Ankole.Work.Provenance,
    owner_session?: true,
    source_signal?: true,
    reply_route?: true,
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
      {:agent_uid, "automation_jobs_agent_uid_fkey"},
      {:source_signal_id, "automation_jobs_source_signal_id_fkey"}
    ])

    check_constraints do
      check_constraint(:authorization_kind, "automation_jobs_work_authorization_check")
      check_constraint(:id, "automation_jobs_id_range")
      check_constraint(:status, "automation_jobs_status_check")
      check_constraint(:owner_session_id, "automation_jobs_owner_session_present")
      check_constraint(:drive_prefix, "automation_jobs_drive_prefix_present")
      check_constraint(:label, "automation_jobs_label_present")
      check_constraint(:reply_route, "automation_jobs_reply_route_object")
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
    attribute(:provider_message_id, :string, public?: true)

    attribute(:source_provenance, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      public?: true
    )

    attribute(:drive_prefix, :string, allow_nil?: false, public?: true)
    attribute(:legacy_directory_path, :string, constraints: [trim?: false], public?: true)

    attribute(:label, :string,
      allow_nil?: false,
      constraints: [max_length: 500, length_count: :graphemes],
      public?: true
    )

    attribute(:wake_on_failure, :boolean, default: false, allow_nil?: false, public?: true)
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
      :agent_uid,
      :owner_session_id,
      :source_signal_id,
      :provider_message_id,
      :source_provenance,
      :reply_route,
      :drive_prefix,
      :label,
      :wake_on_failure,
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

    # The Console list: the newest jobs first, of one Agent or of all Agents.
    read :console_list do
      argument(:agent, Ankole.Ash.Types.PrincipalKey)
      filter(expr(is_nil(^arg(:agent)) or agent_uid == ^arg(:agent)))
      prepare(build(sort: [inserted_at: :desc, id: :desc]))
      pagination(keyset?: true, default_limit: 100, max_page_size: 500, countable: false)
    end

    action :create_job, :term do
      argument(:attrs, :term, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Repo
        |> Ankole.AutomationJobs.create_job_in_tx(input.arguments.attrs)
        |> Ankole.Errors.wrap()
      end)
    end

    action :cancel_job, :term do
      argument(:agent_uid, :term, allow_nil?: false)
      argument(:owner_session_id, :term, allow_nil?: false)
      argument(:job_id, :integer, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.AutomationJobs.cancel_job_in_tx(
          args.agent_uid,
          args.owner_session_id,
          args.job_id,
          args.now
        )
        |> Ankole.Errors.wrap()
      end)
    end

    create :create do
      primary?(true)

      accept([
        :authorization_kind,
        :human_uid,
        :human_access_version,
        :agent_uid,
        :owner_session_id,
        :source_signal_id,
        :provider_message_id,
        :source_provenance,
        :reply_route,
        :drive_prefix,
        :label,
        :wake_on_failure
      ])

      validate(
        fn changeset, _context ->
          case Ankole.Files.normalize_path(Ash.Changeset.get_attribute(changeset, :drive_prefix)) do
            {:ok, _prefix} -> :ok
            {:error, _reason} -> {:error, field: :drive_prefix, message: "must be a drive path"}
          end
        end,
        where: [changing(:drive_prefix)],
        only_when_valid?: true
      )
    end

    update :cancel do
      accept([:cancelled_at])
      change(transition_state(:cancelled))
    end

    update :finish_script_import do
      accept([])
      change(set_attribute(:legacy_directory_path, nil))
    end

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
