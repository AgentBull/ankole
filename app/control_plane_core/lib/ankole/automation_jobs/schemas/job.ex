defmodule Ankole.AutomationJobs.Schemas.Job do
  @moduledoc """
  Durable definition of one Agent-owned automation script.
  """

  use Ankole.Ash.Resource,
    extensions: [AshStateMachine],
    tenancy: :tenant,
    domain: Ankole.AutomationJobs.Domain

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
    timestamps(type: :utc_datetime_usec)
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

    create :create do
      primary?(true)
      transaction?(false)

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

    in_tx_update :cancel do
      accept([:cancelled_at])
      change(transition_state(:cancelled))
    end

    in_tx_update :finish_script_import do
      accept([])
      change(set_attribute(:legacy_directory_path, nil))
    end

    in_tx_update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    atomic_in_tx_update :stop_human_work do
      accept([:cancelled_at])
      change(transition_state(:cancelled))
    end
  end
end
