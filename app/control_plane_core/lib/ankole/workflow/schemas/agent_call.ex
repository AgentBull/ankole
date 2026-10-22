defmodule Ankole.Workflow.Schemas.AgentCall do
  @moduledoc """
  Durable queue and replay-memo entry for one Workflow Agent call.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Workflow,
    extensions: [AshStateMachine]

  @type status :: :queued | :running | :sleeping | :succeeded | :failed | :cancelled

  @terminal_statuses [:succeeded, :failed, :cancelled]
  @model_profile ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @type t :: %__MODULE__{}

  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  postgres do
    table("workflow_agent_calls")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:run_id, "workflow_agent_calls_run_id_fkey"},
      {:agent_uid, "workflow_agent_calls_agent_uid_fkey"}
    ])

    unique_index_names([
      {[:run_id, :call_seq], "workflow_agent_calls_run_sequence_index"}
    ])

    check_constraints do
      check_constraint(:id, "workflow_agent_calls_id_range")
      check_constraint(:call_seq, "workflow_agent_calls_sequence_nonnegative")
      check_constraint(:arguments, "workflow_agent_calls_arguments_valid")
      check_constraint(:label, "workflow_agent_calls_label_valid")
      check_constraint(:model_profile, "workflow_agent_calls_model_profile_valid")
      check_constraint(:status, "workflow_agent_calls_status_check")
      check_constraint(:attempts, "workflow_agent_calls_attempts_nonnegative")
      check_constraint(:wake_count, "workflow_agent_calls_wake_count_nonnegative")
      check_constraint(:sleep_note, "workflow_agent_calls_sleep_note_valid")
      check_constraint(:wake_at, "workflow_agent_calls_wake_contract")
      check_constraint(:result, "workflow_agent_calls_result_valid")
      check_constraint(:error, "workflow_agent_calls_error_object")
    end
  end

  attributes do
    attribute(:id, :integer,
      primary_key?: true,
      allow_nil?: false,
      generated?: true,
      public?: true
    )

    attribute(:run_id, :integer, allow_nil?: false, public?: true)
    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)
    attribute(:call_seq, :integer, allow_nil?: false, constraints: [min: 0], public?: true)

    attribute(:arguments, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      constraints: [max_bytes: 8192],
      public?: true
    )

    attribute(:label, :string,
      constraints: [max_length: 200, length_count: :graphemes],
      public?: true
    )

    attribute(:model_profile, :string, constraints: [match: @model_profile], public?: true)

    attribute(:attempts, :integer,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true,
      default: 0
    )

    attribute(:sleep_note, :string,
      constraints: [max_length: 200, length_count: :graphemes],
      public?: true
    )

    attribute(:wake_kind, :atom, public?: true, constraints: [one_of: [:sleep, :agent_capacity]])
    attribute(:wake_at, :utc_datetime_usec, public?: true)
    attribute(:progress_at, :utc_datetime_usec, public?: true)

    attribute(:wake_count, :integer,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true,
      default: 0
    )

    attribute(:attention, :boolean, public?: true, default: false)
    attribute(:result, Ankole.Ash.Types.JSONMap, constraints: [max_bytes: 32768], public?: true)
    attribute(:error, Ankole.Ash.Types.JSONMap, allow_nil?: false, public?: true, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    belongs_to :run, Ankole.Workflow.Schemas.Run do
      source_attribute(:run_id)
      attribute_type(:integer)
      define_attribute?(false)
    end
  end

  state_machine do
    state_attribute(:status)
    initial_states([:queued])
    default_initial_state(:queued)

    transitions do
      transition(:claim, from: [:queued, :sleeping], to: :running)
      transition(:defer_capacity, from: [:queued, :sleeping], to: :queued)
      transition(:sleep, from: [:running], to: :sleeping)
      transition(:requeue_stale, from: [:running], to: :queued)
      transition(:complete, from: [:running], to: :succeeded)
      transition(:fail, from: [:queued, :running, :sleeping], to: :failed)
      transition(:cancel, from: [:queued, :running, :sleeping], to: :cancelled)
      transition(:cancel_live_calls, from: [:queued, :running, :sleeping], to: :cancelled)
    end
  end

  actions do
    defaults([:read])

    action :send_task_message, :term do
      argument(:run_id, :integer, allow_nil?: false)
      argument(:call_seq, :integer, allow_nil?: false)
      argument(:agent_uid, :term, allow_nil?: false)
      argument(:message, :term, allow_nil?: false)
      argument(:source_tool_call_id, :term, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Workflow.Mail.send_task_message_in_tx(
          args.run_id,
          args.call_seq,
          args.agent_uid,
          args.message,
          args.source_tool_call_id
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :defer_task_event, :term do
      argument(:signal, :term, allow_nil?: false)
      argument(:available_at, :utc_datetime_usec, allow_nil?: false)
      argument(:reason, :atom, allow_nil?: false, constraints: [one_of: [:agent_capacity]])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Workflow.Mail.defer_task_event_in_tx(
          args.signal,
          args.available_at,
          args.reason
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :release_capacity, :term do
      argument(:agent_uid, :term, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Workflow.Mail.release_capacity_in_tx(args.agent_uid)
        |> Ankole.Errors.wrap()
      end)
    end

    create :create_call do
      primary?(true)

      accept([
        :run_id,
        :agent_uid,
        :call_seq,
        :arguments,
        :label,
        :model_profile,
        :attempts,
        :sleep_note,
        :wake_kind,
        :wake_at,
        :progress_at,
        :wake_count,
        :attention,
        :result,
        :error
      ])
    end

    update :claim do
      accept([:attempts, :attention, :error, :wake_kind, :wake_at, :progress_at])
      change(set_attribute(:wake_kind, nil))
      change(set_attribute(:wake_at, nil))
      change(transition_state(:running))
    end

    update :defer_capacity do
      accept([:wake_kind, :wake_at])
      change(transition_state(:queued))
    end

    update :sleep do
      accept([:wake_kind, :attempts, :sleep_note, :wake_at, :wake_count, :attention, :error])
      change(transition_state(:sleeping))
    end

    update :requeue_stale do
      accept([:wake_kind, :wake_at, :result, :error])
      change(set_attribute(:wake_kind, nil))
      change(set_attribute(:wake_at, nil))
      change(transition_state(:queued))
    end

    update :complete do
      accept([:result, :error])
      change(set_attribute(:wake_kind, nil))
      change(set_attribute(:wake_at, nil))
      change(transition_state(:succeeded))
    end

    update :fail do
      accept([:wake_kind, :wake_at, :result, :error])
      change(set_attribute(:wake_kind, nil))
      change(set_attribute(:wake_at, nil))
      change(transition_state(:failed))
    end

    update :cancel do
      accept([:result, :error])
      change(set_attribute(:wake_kind, nil))
      change(set_attribute(:wake_at, nil))
      change(transition_state(:cancelled))
    end

    update :cancel_live_calls do
      require_atomic?(true)
      accept([:error, :result])
      change(transition_state(:cancelled))
      change(set_attribute(:wake_kind, nil))
      change(set_attribute(:wake_at, nil))
    end

    update :update_metadata do
      accept([:progress_at])
    end
  end
end
