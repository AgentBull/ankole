defmodule Ankole.BackgroundAgentJobs.Schemas.Job do
  @moduledoc """
  Durable BackgroundAgentJob work item.

  Jobs retain one optional workspace template and one runtime projection. The
  first executable admission records the projection, and later attempts use it
  to keep the same logical execution choices.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.BackgroundAgentJobs,
    extensions: [AshStateMachine, AshJsonApi.Resource]

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
  alias Ankole.Signals.Signal

  @model_id [min: Ankole.ModelIntegerID.minimum(), max: Ankole.ModelIntegerID.maximum()]
  @model_profile ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @live_statuses [:queued, :running, :waiting_on_user]

  @doc "Returns statuses with no live execution."
  @spec terminal_statuses() :: [JobState.status()]
  defdelegate terminal_statuses(), to: JobState

  @doc "Returns statuses with live execution or pending input."
  @spec live_statuses() :: [JobState.status()]
  def live_statuses, do: @live_statuses

  @doc "Returns statuses that occupy an agent running slot."
  @spec running_statuses() :: [JobState.status()]
  defdelegate running_statuses(), to: JobState

  json_api do
    type("background_agent_job")
    derive_filter?(false)
    derive_sort?(false)

    # The primary key names the record in the result of a generic action.
    default_fields([
      :id,
      :agent_uid,
      :owner_session_id,
      :source_signal_id,
      :source_tool_call_id,
      :continued_from_job_id,
      :workspace_owner_job_id,
      :runtime_thread_id,
      :title,
      :task,
      :status,
      :attempts,
      :execution_failures,
      :workspace_template_id,
      :model_profile,
      :reply_route,
      :result,
      :error,
      :metadata,
      :duration_seconds,
      :queued_at,
      :started_at,
      :completed_at,
      :inserted_at,
      :updated_at
    ])
  end

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

    timestamps(type: :utc_datetime_usec, public?: true)
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

  calculations do
    calculate(
      :skill_lesson_reflection?,
      :boolean,
      expr(fragment("coalesce(? ->> 'skill_lesson_reflection', 'false') = 'true'", metadata))
    )

    calculate(:task_excerpt, :string, expr(fragment("left(?, 600)", task)))

    # The seconds from the start (or the queue time) to the completion, or to
    # now for a Job that is not complete.
    calculate(
      :duration_seconds,
      :integer,
      expr(
        fragment(
          "GREATEST(COALESCE(floor(EXTRACT(EPOCH FROM (COALESCE(?, now()) - COALESCE(?, ?))))::bigint, 0), 0)",
          completed_at,
          started_at,
          queued_at
        )
      ),
      public?: true
    )

    calculate(:error_code, :string, expr(fragment("left(?->>'code', 200)", error)))

    calculate(
      :error_summary,
      :string,
      expr(fragment("left(COALESCE(?->>'summary', ?->>'message'), 1000)", error, error))
    )

    calculate(
      :result_output_window,
      :binary,
      expr(
        fragment(
          "substring(convert_to(?->>'output_text', 'UTF8') from ? for ?)",
          result,
          ^arg(:from),
          ^arg(:bytes)
        )
      )
    ) do
      argument(:from, :integer, allow_nil?: false)
      argument(:bytes, :integer, allow_nil?: false)
    end

    calculate(
      :result_output_bytes,
      :integer,
      expr(fragment("octet_length(?->>'output_text')", result))
    )

    calculate(
      :result_fields,
      Ankole.Ash.Types.JSONMap,
      expr(fragment("coalesce(? - 'output_text', '{}'::jsonb)", result))
    )
  end

  actions do
    defaults([:read])

    read :console_list do
      argument(:agent_uid, :string)
      argument(:status, :atom)
      argument(:search, :string, constraints: [max_length: 200])
      argument(:live_only, :boolean, default: false)
      pagination(keyset?: true, default_limit: 50, max_page_size: 100, required?: false)

      prepare(fn query, _context ->
        Ankole.BackgroundAgentJobs.Queries.prepare_console_list(query)
      end)
    end

    read :list_for_agent do
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:status_group, :atom, allow_nil?: false, constraints: [one_of: [:live, :stop]])
      pagination(keyset?: true, default_limit: 32, max_page_size: 32, required?: false)

      prepare(fn query, _context ->
        Ankole.BackgroundAgentJobs.Queries.prepare_agent_list(query)
      end)
    end

    read :ambient_candidates do
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:owner_session_id, :string, allow_nil?: false)
      argument(:conversation_id, :string, allow_nil?: false)
      argument(:binding_name, :string, allow_nil?: false)

      filter(
        expr(
          agent_uid == ^arg(:agent_uid) and owner_session_id == ^arg(:owner_session_id) and
            status in @live_statuses and not skill_lesson_reflection? and
            fragment("?->>'conversation_id'", reply_route) == ^arg(:conversation_id) and
            fragment("?->>'binding_name'", reply_route) == ^arg(:binding_name)
        )
      )

      prepare(build(sort: [updated_at: :desc, id: :desc]))
    end

    read :live_for_owner_sessions do
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:owner_session_ids, {:array, :string}, allow_nil?: false)

      filter(
        expr(
          agent_uid == ^arg(:agent_uid) and owner_session_id in ^arg(:owner_session_ids) and
            status in @live_statuses
        )
      )

      prepare(build(sort: [id: :asc]))
    end

    update :record_lessons_applied do
      accept([])

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

    update :touch do
      require_atomic?(true)
      accept([])
      argument(:at, :utc_datetime_usec, allow_nil?: false)
      change(atomic_update(:updated_at, expr(^arg(:at))))
    end

    update :begin_worker_wait do
      require_atomic?(true)
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

    update :clear_worker_wait do
      require_atomic?(true)
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

    update :record_applied_signal do
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

    update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    create :create_job do
      accept([:id | @create_fields])
      primary?(true)
      validate(present([:source_tool_call_id, :title, :task]))
    end

    for action <- [:claim_attempt, :claim_continuation] do
      update action do
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

    update :worker_report do
      accept([
        :runtime_thread_id,
        :result,
        :error,
        :metadata,
        :started_at,
        :completed_at,
        :worker_wait_started_at
      ])

      argument(:next_status, :atom, constraints: [unsafe_to_atom?: false])

      change(
        {Ankole.BackgroundAgentJobs.Changes.TransitionToArgument,
         missing: :background_agent_job_status_missing}
      )
    end

    update :requeue do
      accept([:execution_failures])
      change(transition_state(:queued))
    end

    update :external_complete do
      accept([:result, :metadata, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:succeeded))
    end

    update :fail_admission do
      accept([:error, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:failed))
    end

    update :fail_turn do
      accept([:error, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:failed))
    end

    update :stop do
      accept([:error, :metadata, :started_at, :completed_at, :worker_wait_started_at])
      change(transition_state(:stopped))
    end

    update :stop_human_work do
      accept([:error, :completed_at, :worker_wait_started_at])
      change(transition_state(:stopped))
    end

    # The operations below own their transaction. Each one takes its locks in
    # the work lock order and runs the composition function that other domains
    # call inside their own operation.
    action :start, :term do
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Dispatch.create_with_dispatch_in_tx(
            Ankole.Repo,
            input.arguments.attrs
          )
        )
      end)
    end

    action :respawn, :term do
      argument(:source_job_id, :integer, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Dispatch.respawn_with_dispatch_in_tx(
            Ankole.Repo,
            input.arguments.source_job_id,
            input.arguments.attrs
          )
        )
      end)
    end

    action :request_stop, :term do
      argument(:job_id, :integer, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Control.request_stop_in_tx(
            Ankole.Repo,
            input.arguments.job_id,
            input.arguments.attrs
          )
        )
      end)
    end

    action :console_cancel, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, :integer, allow_nil?: false, constraints: @model_id)
      after_commit({Ankole.BackgroundAgentJobs.Control, :stop_console_turn})

      run(fn input, context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Control.console_cancel_in_tx(
            Ankole.Repo,
            input.arguments.id,
            context.actor
          )
        )
      end)
    end

    action :console_complete, :struct do
      constraints(instance_of: __MODULE__)
      argument(:id, :integer, allow_nil?: false, constraints: @model_id)

      argument(:result_summary, :string,
        allow_nil?: false,
        constraints: [max_length: 16_384, trim?: false]
      )

      after_commit({Ankole.BackgroundAgentJobs.Control, :stop_console_turn})

      run(fn input, context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Control.console_complete_in_tx(
            Ankole.Repo,
            input.arguments.id,
            input.arguments.result_summary,
            context.actor
          )
        )
      end)
    end

    action :request_complete, :term do
      argument(:job_id, :integer, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Control.request_complete_in_tx(
            Ankole.Repo,
            input.arguments.job_id,
            input.arguments.attrs
          )
        )
      end)
    end

    action :send_message, :term do
      argument(:job_id, :integer, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Control.send_message_in_tx(
            Ankole.Repo,
            input.arguments.job_id,
            input.arguments.attrs
          )
        )
      end)
    end

    action :commit_status, :term do
      argument(:job_id, :integer, allow_nil?: false)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:attrs, :map, allow_nil?: false)
      argument(:options, :term, allow_nil?: false, default: [])
      after_commit({Ankole.BackgroundAgentJobs.Lifecycle, :publish_status_commit})

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Lifecycle.commit_status_in_tx(
            Ankole.Repo,
            input.arguments.job_id,
            input.arguments.agent_uid,
            input.arguments.attrs,
            input.arguments.options
          )
        )
      end)
    end

    action :complete_signal, :term do
      argument(:signal, :struct, allow_nil?: false, constraints: [instance_of: Signal])

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.Dispatch.complete_signal_in_tx(
            Ankole.Repo,
            input.arguments.signal
          )
        )
      end)
    end

    action :resolve_worker_timeout, :term do
      argument(:signal, :struct, allow_nil?: false, constraints: [instance_of: Signal])
      argument(:job, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.WorkerWait.resolve_timeout_in_tx(
            Ankole.Repo,
            input.arguments.signal,
            input.arguments.job,
            input.arguments.now
          )
        )
      end)
    end

    action :inspect_stall, :term do
      argument(:job_id, :integer, allow_nil?: false)
      argument(:now, :utc_datetime_usec, allow_nil?: false)

      run(fn input, _context ->
        Ankole.Errors.wrap(
          Ankole.BackgroundAgentJobs.TurnWatchdog.inspect_stall_in_tx(
            Ankole.Repo,
            input.arguments.job_id,
            input.arguments.now
          )
        )
      end)
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
