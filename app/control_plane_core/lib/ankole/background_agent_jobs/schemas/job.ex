defmodule Ankole.BackgroundAgentJobs.Schemas.Job do
  @moduledoc """
  Durable BackgroundAgentJob work item.

  Jobs retain one optional workspace template and one runtime projection. The
  first executable admission records the projection, and later attempts use it
  to keep the same logical execution choices.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.BackgroundAgentJobs.Domain,
    extensions: [AshStateMachine]

  use Ankole.Work.Provenance,
    owner_session?: true,
    source_signal?: true,
    reply_route?: true,
    kind: "background_job",
    cleanup_key: "background_jobs",
    review_states: [:queued, :waiting_on_user, :stopped],
    reauthorizable_states: [:queued, :waiting_on_user],
    revoke_action: {Ankole.BackgroundAgentJobs.Lifecycle, :stop_human_work_in_tx}

  alias Ankole.AIAgent.Library.AgentPlugins.Contract
  alias Ankole.BackgroundAgentJobs.JobState
  @model_profile ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @doc "Returns statuses with no live execution."
  @spec terminal_statuses() :: [JobState.status()]
  defdelegate terminal_statuses(), to: JobState

  @doc "Returns statuses that occupy an agent running slot."
  @spec running_statuses() :: [JobState.status()]
  defdelegate running_statuses(), to: JobState

  postgres do
    table("background_agent_jobs")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "background_agent_jobs_agent_uid_fkey"},
      {:source_signal_id, "background_agent_jobs_source_signal_id_fkey"},
      {:continued_from_job_id, "background_agent_jobs_continued_from_job_id_fkey"},
      {:workspace_owner_job_id, "background_agent_jobs_workspace_owner_job_id_fkey"}
    ])

    unique_index_names([
      {[:agent_uid, :owner_session_id, :source_tool_call_id],
       "background_agent_jobs_source_tool_call_index"},
      {[:continued_from_job_id], "background_agent_jobs_continued_from_job_index"}
    ])

    check_constraints do
      check_constraint(:authorization_kind, "background_agent_jobs_work_authorization_check")
      check_constraint(:id, "background_agent_jobs_id_range")
      check_constraint(:continued_from_job_id, "background_agent_jobs_continued_from_not_self")
      check_constraint(:reply_route, "background_agent_jobs_reply_route_object")
      check_constraint(:attempts, "background_agent_jobs_attempts_nonnegative")

      check_constraint(
        :execution_failures,
        "background_agent_jobs_execution_failures_nonnegative"
      )

      check_constraint(
        :workspace_template_id,
        "background_agent_jobs_workspace_template_id_valid"
      )

      check_constraint(:model_profile, "background_agent_jobs_model_profile_valid")
      check_constraint(:runtime_projection, "background_agent_jobs_runtime_projection_object")
      check_constraint(:status, "background_agent_jobs_status_check")
      check_constraint(:result, "background_agent_jobs_result_object")
      check_constraint(:error, "background_agent_jobs_error_object")
      check_constraint(:metadata, "background_agent_jobs_metadata_object")
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
    attribute(:source_tool_call_id, :string, public?: true)
    attribute(:continued_from_job_id, :integer, public?: true)
    attribute(:workspace_owner_job_id, :integer, allow_nil?: false, public?: true)
    attribute(:runtime_thread_id, :string, public?: true)
    attribute(:title, :string, public?: true)
    attribute(:task, :string, public?: true, constraints: [trim?: false])

    attribute(:attempts, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true
    )

    attribute(:execution_failures, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true
    )

    attribute(:workspace_template_id, :string, public?: true)

    attribute(:model_profile, :string,
      default: "coding",
      allow_nil?: false,
      constraints: [match: @model_profile],
      public?: true
    )

    attribute(:runtime_projection, Ankole.Ash.Types.JSONMap, public?: true)
    attribute(:queued_at, :utc_datetime_usec, public?: true)
    attribute(:worker_wait_started_at, :utc_datetime_usec, public?: true)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)

    attribute(:result, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      constraints: [allow_datetime?: true],
      public?: true
    )

    attribute(:error, Ankole.Ash.Types.JSONMap,
      default: %{},
      allow_nil?: false,
      constraints: [allow_datetime?: true],
      public?: true
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true,
      constraints: [allow_datetime?: true]
    )

    timestamps(type: :utc_datetime_usec)
  end

  state_machine do
    state_attribute(:status)
    initial_states([:queued])
    default_initial_state(:queued)

    transitions do
      transition(:claim_attempt, from: :queued, to: :running)
      transition(:claim_continuation, from: [:queued, :waiting_on_user], to: :running)

      transition(:worker_report,
        from: :running,
        to: [:running, :waiting_on_user, :succeeded, :failed, :stopped]
      )

      transition(:requeue, from: :running, to: :queued)
      transition(:external_complete, from: [:queued, :running, :waiting_on_user], to: :succeeded)
      transition(:fail_admission, from: [:queued, :waiting_on_user], to: :failed)
      transition(:fail_turn, from: :running, to: :failed)
      transition(:stop, from: [:queued, :running, :waiting_on_user], to: :stopped)
      transition(:stop_human_work, from: [:queued, :waiting_on_user], to: :stopped)
    end
  end

  @create_fields [
    :authorization_kind,
    :human_uid,
    :human_access_version,
    :agent_uid,
    :owner_session_id,
    :source_signal_id,
    :source_tool_call_id,
    :continued_from_job_id,
    :workspace_owner_job_id,
    :runtime_thread_id,
    :title,
    :task,
    :reply_route,
    :attempts,
    :execution_failures,
    :workspace_template_id,
    :model_profile,
    :runtime_projection,
    :queued_at,
    :worker_wait_started_at,
    :started_at,
    :completed_at,
    :result,
    :error,
    :metadata
  ]

  validations do
    validate(match(:task, ~r/\S/u), message: "can't be blank", where: [changing(:task)])

    validate(match(:workspace_template_id, Contract.identifier_pattern()),
      message: "must be an Agent Plugin identifier",
      where: [changing(:workspace_template_id)]
    )
  end

  actions do
    defaults([:read])

    update :record_lessons_applied do
      accept([])
      require_atomic?(false)
      atomic_upgrade?(false)

      change(fn changeset, _context ->
        applied_at = DateTime.utc_now() |> DateTime.to_iso8601()

        Ash.Changeset.atomic_update(
          changeset,
          :metadata,
          expr(
            fragment(
              "? || jsonb_build_object('lessons_applied_at', ?::text)",
              metadata,
              ^applied_at
            )
          )
        )
      end)
    end

    atomic_in_tx_update :touch do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(atomic_update(:updated_at, expr(^arg(:at))))
    end

    atomic_in_tx_update :begin_worker_wait do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)

      change(
        atomic_update(
          :updated_at,
          expr(if(is_nil(worker_wait_started_at), do: ^arg(:at), else: updated_at))
        )
      )

      change(
        atomic_update(
          :worker_wait_started_at,
          expr(if(is_nil(worker_wait_started_at), do: ^arg(:at), else: worker_wait_started_at))
        )
      )
    end

    atomic_in_tx_update :clear_worker_wait do
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)

      change(
        atomic_update(
          :updated_at,
          expr(if(is_nil(worker_wait_started_at), do: updated_at, else: ^arg(:at)))
        )
      )

      change(atomic_update(:worker_wait_started_at, expr(nil)))
    end

    in_tx_update :record_applied_signal do
      accept([])
      argument(:signal_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

      change(
        atomic_update(
          :metadata,
          expr(
            fragment(
              "? || jsonb_build_object('applied_source_signal_id', ?::text)",
              metadata,
              ^arg(:signal_id)
            )
          )
        )
      )
    end

    in_tx_update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    create :create_job do
      accept([:id | @create_fields])
      transaction?(false)
      primary?(true)
      validate(present([:source_tool_call_id, :title, :task]))
    end

    for action <- [:claim_attempt, :claim_continuation] do
      in_tx_update action do
        accept([
          :attempts,
          :started_at,
          :completed_at,
          :metadata,
          :runtime_projection,
          :worker_wait_started_at
        ])

        change(transition_state(:running))
      end
    end

    in_tx_update :worker_report do
      accept([
        :runtime_thread_id,
        :result,
        :error,
        :metadata,
        :started_at,
        :completed_at,
        :worker_wait_started_at
      ])

      argument(:next_status, :atom, allow_nil?: false, constraints: [unsafe_to_atom?: false])
      change(Ankole.BackgroundAgentJobs.Changes.TransitionToArgument)
    end

    in_tx_update :requeue do
      accept([:execution_failures])
      change(transition_state(:queued))
    end

    in_tx_update :external_complete do
      accept([:result, :metadata, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:succeeded))
    end

    in_tx_update :fail_admission do
      accept([:error, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:failed))
    end

    in_tx_update :fail_turn do
      accept([:error, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:failed))
    end

    in_tx_update :stop do
      accept([:error, :metadata, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:stopped))
    end

    in_tx_update :stop_human_work do
      accept([:error, :completed_at, :worker_wait_started_at])
      change(transition_state(:stopped))
    end
  end

  # What a successor Job copies from its source. The whole continuation chain
  # resumes one Codex thread inside the Workspace of the first Job, which that
  # Job built from the template, so the chain keeps the template identity.
  @inherited_fields [
    :title,
    :runtime_thread_id,
    :workspace_owner_job_id,
    :workspace_template_id,
    :model_profile
  ]

  @doc "The source fields that `successor_attrs/2` copies."
  @spec inherited_fields() :: [atom()]
  def inherited_fields, do: @inherited_fields

  @doc """
  Builds the creation attributes of a successor Job from its source Job and
  the successor's own facts. The inherited fields and the continuation link
  replace any value in `attrs`; the source's legacy replay marker follows the
  source.
  """
  @spec successor_attrs(%__MODULE__{}, map()) :: map()
  def successor_attrs(%__MODULE__{} = source, attrs) when is_map(attrs) do
    inherited = Map.new(@inherited_fields, &{Atom.to_string(&1), Map.fetch!(source, &1)})

    attrs
    |> Map.merge(inherited)
    |> Map.put("continued_from_job_id", source.id)
    |> Map.put("metadata", successor_metadata(source, Map.get(attrs, "metadata", %{})))
  end

  defp successor_metadata(%__MODULE__{metadata: source_metadata}, metadata) do
    legacy_thread_replay? = (source_metadata || %{})["legacy_thread_replay"] == true

    if legacy_thread_replay?,
      do: Map.put(metadata, "legacy_thread_replay", true),
      else: Map.delete(metadata, "legacy_thread_replay")
  end
end
