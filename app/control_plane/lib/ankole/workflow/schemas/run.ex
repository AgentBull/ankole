defmodule Ankole.Workflow.Schemas.Run do
  @moduledoc """
  Durable state for one Workflow program execution.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Workflow,
    extensions: [AshStateMachine]

  use Ankole.Work.Provenance,
    owner_session?: true,
    source_signal?: true,
    reply_route?: true,
    kind: "workflow",
    cleanup_key: :workflow_calls,
    review_states: [:running, :cancelled],
    reauthorizable_states: [:running],
    revoke_action: {Ankole.Workflow.Lifecycle, :stop_human_work_in_tx}

  @type status :: :running | :completed | :failed | :cancelled

  @terminal_statuses [:completed, :failed, :cancelled]
  @memo_budget_bytes 6 * 1_024 * 1_024
  @model_profile ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @type t :: %__MODULE__{}

  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  postgres do
    table("workflow_runs")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "workflow_runs_agent_uid_fkey"},
      {:source_signal_id, "workflow_runs_source_signal_id_fkey"}
    ])

    unique_index_names([
      {[:agent_uid, :owner_session_id, :source_tool_call_id],
       "workflow_runs_source_tool_call_index"}
    ])

    check_constraints do
      check_constraint(:authorization_kind, "workflow_runs_work_authorization_check")
      check_constraint(:id, "workflow_runs_id_range")
      check_constraint(:owner_session_id, "workflow_runs_owner_session_present")
      check_constraint(:source_tool_call_id, "workflow_runs_source_tool_call_present")
      check_constraint(:reply_route, "workflow_runs_reply_route_object")
      check_constraint(:title, "workflow_runs_title_valid")
      check_constraint(:script, "workflow_runs_script_valid")
      check_constraint(:args, "workflow_runs_args_valid")
      check_constraint(:status, "workflow_runs_status_check")
      check_constraint(:concurrency, "workflow_runs_concurrency_range")
      check_constraint(:max_agent_calls, "workflow_runs_max_agent_calls_range")
      check_constraint(:memo_bytes, "workflow_runs_memo_bytes_range")
      check_constraint(:model_profile, "workflow_runs_model_profile_valid")
      check_constraint(:result_text, "workflow_runs_result_bounded")
      check_constraint(:error, "workflow_runs_error_object")
      check_constraint(:completed_at, "workflow_runs_lifecycle_check")
      check_constraint(:cleanup_completed_at, "workflow_runs_cleanup_lifecycle_check")
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
    attribute(:source_tool_call_id, :string, allow_nil?: false, public?: true)

    attribute(:title, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 200, length_count: :graphemes],
      public?: true
    )

    attribute(:script, :string,
      allow_nil?: false,
      constraints: [trim?: false, max_length: 262_144, length_count: :bytes],
      public?: true
    )

    attribute(:args, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      constraints: [max_bytes: 65_536],
      public?: true,
      default: %{}
    )

    attribute(:concurrency, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 32],
      public?: true
    )

    attribute(:max_agent_calls, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 1024],
      public?: true
    )

    attribute(:memo_bytes, :integer,
      allow_nil?: false,
      constraints: [min: 0, max: @memo_budget_bytes],
      public?: true,
      default: 0
    )

    attribute(:model_profile, :string, constraints: [match: @model_profile], public?: true)

    attribute(:result_text, :string,
      constraints: [trim?: false, allow_empty?: true, max_length: 1_048_576, length_count: :bytes],
      public?: true
    )

    attribute(:error, Ankole.Ash.Types.JSONMap, allow_nil?: false, public?: true, default: %{})
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    attribute(:cleanup_completed_at, :utc_datetime_usec, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    has_many :agent_calls, Ankole.Workflow.Schemas.AgentCall do
      destination_attribute(:run_id)
    end
  end

  calculations do
    calculate(
      :result_output_window,
      :binary,
      expr(
        fragment(
          "substring(convert_to(?, 'UTF8') from ? for ?)",
          result_text,
          ^arg(:from),
          ^arg(:bytes)
        )
      )
    ) do
      argument(:from, :integer, allow_nil?: false)
      argument(:bytes, :integer, allow_nil?: false)
    end

    calculate(:result_output_bytes, :integer, expr(fragment("octet_length(?)", result_text)))
  end

  aggregates do
    count :running_call_count, :agent_calls do
      filter(expr(status == :running))
    end
  end

  state_machine do
    state_attribute(:status)
    initial_states([:running])
    default_initial_state(:running)

    transitions do
      transition(:complete, from: [:running], to: :completed)
      transition(:fail, from: [:running], to: :failed)
      transition(:stop, from: [:running], to: :cancelled)
      transition(:stop_runs, from: [:running], to: :cancelled)
    end
  end

  actions do
    defaults([:read])

    read :list_page do
      pagination(offset?: true, max_page_size: 100, countable: false)
    end

    update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    create :create_run do
      primary?(true)

      accept([
        :authorization_kind,
        :human_uid,
        :human_access_version,
        :agent_uid,
        :owner_session_id,
        :reply_route,
        :source_signal_id,
        :source_tool_call_id,
        :title,
        :script,
        :args,
        :concurrency,
        :max_agent_calls,
        :memo_bytes,
        :model_profile,
        :error
      ])

      change(fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :script) do
          text when is_binary(text) ->
            if String.trim(text) == "",
              do: Ash.Changeset.add_error(changeset, field: :script, message: "can't be blank"),
              else: changeset

          _ ->
            changeset
        end
      end)
    end

    update :complete do
      require_attributes([:completed_at])
      accept([:result_text, :error, :completed_at])
      change(transition_state(:completed))
    end

    update :fail do
      require_attributes([:completed_at])
      accept([:result_text, :error, :completed_at])
      change(transition_state(:failed))
    end

    update :stop do
      require_attributes([:completed_at])
      accept([:result_text, :error, :completed_at])
      change(transition_state(:cancelled))
    end

    update :stop_runs do
      require_atomic?(true)
      accept([:error, :completed_at, :cleanup_completed_at])
      change(transition_state(:cancelled))
    end

    update :update_metadata do
      accept([:memo_bytes, :cleanup_completed_at])
    end
  end
end
