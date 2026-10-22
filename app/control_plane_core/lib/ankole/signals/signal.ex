defmodule Ankole.Signals.Signal do
  @moduledoc """
  Durable stimulus accepted by Signals and consumed by Sessions.

  The state machine owns queue admission, retry, completion, and dead-lettering.
  Timestamps record when those transitions occurred; they do not define state.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Signals.Domain,
    extensions: [AshStateMachine]

  use Ankole.Work.Provenance,
    kind: "signal",
    cleanup_key: "signals",
    review_states: [:queued, :running, :dead_letter],
    reauthorizable_states: [:queued, :running],
    revoke_action: {Ankole.Sessions.Queue, :stop_human_work_in_tx}

  alias Ankole.Conversations.ExternalMessageRef
  alias Ankole.Repo

  @turn_outcomes ~w(loop_finished iteration_exhausted silent)
  @type t :: %__MODULE__{}

  postgres do
    table("signals")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(source_identity: "signals_signal_idempotency_index")

    foreign_key_names([
      {:agent_uid, "signals_agent_uid_fkey"},
      {:message_id, "signals_message_id_fkey"},
      {:ambient_asked_message_id, "signals_ambient_asked_message_id_fkey"},
      {:conversation_id, "signals_conversation_id_fkey"}
    ])

    unique_index_names([
      {[:tenant_id, :agent_uid, :session_id, :queue_sequence], "signals_queue_sequence_index"}
    ])

    check_constraints do
      check_constraint(:authorization_kind, "signals_work_authorization_check")
      check_constraint(:status, "signals_status_check")
      check_constraint(:status, "signals_lifecycle_check")
      check_constraint(:attempt_count, "signals_attempt_count_non_negative")
      check_constraint(:provider_capacity_attempt_count, "signals_capacity_attempt_count_check")
      check_constraint(:final_response_id, "signals_completion_anchor_check")
      check_constraint(:turn_outcome, "signals_turn_outcome_check")
      check_constraint(:producer, "signals_producer_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0,
      public?: true
    )

    ash_attributes()

    attribute(:producer, Ankole.Ash.Types.State,
      constraints: [one_of: [:kernel, :external]],
      default: :external,
      allow_nil?: false,
      public?: true
    )

    attribute(:source, :string, allow_nil?: false, public?: true)
    attribute(:subject, :string, public?: true)
    attribute(:reply_binding_name, :string, public?: true)
    attribute(:session_id, :string, allow_nil?: false, public?: true)
    attribute(:source_event_id, :string, allow_nil?: false, public?: true)
    attribute(:provider_thread_id, :string, public?: true)
    attribute(:provider_message_id, :string, public?: true)
    attribute(:type, :string, allow_nil?: false, public?: true)
    attribute(:final_response_id, :string, public?: true)
    attribute(:turn_outcome, :string, public?: true)
    attribute(:sender_key, :string, public?: true)
    attribute(:message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:conversation_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:ambient_asked_message_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:available_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:last_attempt_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    attribute(:dead_letter_at, :utc_datetime_usec, public?: true)

    attribute(:attempt_count, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0],
      public?: true
    )

    attribute(:provider_capacity_attempt_count, :integer,
      constraints: [min: 0],
      default: 0,
      allow_nil?: false,
      public?: true
    )

    attribute(:queue_sequence, :integer, allow_nil?: false, public?: true)
    attribute(:data, Ankole.Ash.Types.JSONValue, default: %{}, public?: true)
    attribute(:extensions, Ankole.Ash.Types.JSONMap, default: %{}, public?: true)
    attribute(:dead_letter_reason, Ankole.Ash.Types.JSONMap, public?: true)
    timestamps(type: :utc_datetime_usec)
  end

  relationships do
    has_one :preview, Ankole.Conversations.Delivery.PreviewState do
      source_attribute(:id)
      destination_attribute(:signal_id)
      public?(false)
    end
  end

  identities do
    identity(:source_identity, [:agent_uid, :source, :source_event_id])
  end

  state_machine do
    state_attribute(:status)
    initial_states([:queued])
    default_initial_state(:queued)

    transitions do
      transition(:admit, from: [:queued, :running], to: :running)
      transition(:retry_triage, from: :queued, to: :queued)
      transition(:start_attempt, from: [:queued, :running], to: :running)
      transition(:defer, from: [:queued, :running], to: :queued)
      transition(:reset_attempts, from: [:queued, :running], to: :queued)
      transition(:complete, from: [:queued, :running, :completed], to: :completed)
      transition(:dead_letter, from: [:queued, :running, :dead_letter], to: :dead_letter)
      transition(:revoke_unstarted, from: :queued, to: :dead_letter)
    end
  end

  validations do
    validate(attribute_in(:turn_outcome, [nil | @turn_outcomes]))
  end

  actions do
    defaults([:read])

    create :accept do
      primary?(true)
      transaction?(false)
      upsert?(true)
      upsert_identity(:source_identity)
      upsert_fields([:source_event_id])

      accept([
        :producer,
        :authorization_kind,
        :human_uid,
        :human_access_version,
        :agent_uid,
        :source,
        :subject,
        :reply_binding_name,
        :session_id,
        :source_event_id,
        :conversation_id,
        :provider_thread_id,
        :provider_message_id,
        :ambient_asked_message_id,
        :type,
        :available_at,
        :queue_sequence,
        :sender_key,
        :data,
        :extensions,
        :occurred_at,
        :message_id
      ])
    end

    in_tx_update :admit do
      require_attributes([:last_attempt_at])
      accept([:last_attempt_at, :data])
      change(atomic_update(:attempt_count, expr(attempt_count + 1)))
      change(transition_state(:running))
    end

    in_tx_update :retry_triage do
      accept([:available_at])
      change(atomic_update(:attempt_count, expr(attempt_count + 1)))
      change(transition_state(:queued))
    end

    in_tx_update :refund_attempt do
      accept([])
      validate(attribute_in(:status, [:queued, :running]))

      change(
        atomic_update(
          :attempt_count,
          expr(
            if(attempt_count > provider_capacity_attempt_count,
              do: attempt_count - 1,
              else: attempt_count
            )
          )
        )
      )
    end

    in_tx_update :start_attempt do
      require_attributes([:last_attempt_at])
      accept([:last_attempt_at])
      change(transition_state(:running))
    end

    in_tx_update :defer do
      accept([:available_at])
      argument(:provider_capacity?, :boolean, default: false, allow_nil?: false)

      change(
        atomic_update(
          :provider_capacity_attempt_count,
          expr(provider_capacity_attempt_count + 1)
        ),
        where: [argument_equals(:provider_capacity?, true)]
      )

      change(transition_state(:queued))
    end

    atomic_in_tx_update :reset_attempts do
      accept([:available_at])
      change(set_attribute(:attempt_count, 0))
      change(set_attribute(:provider_capacity_attempt_count, 0))
      change(set_attribute(:last_attempt_at, nil))
      change(transition_state(:queued))
    end

    in_tx_update :complete do
      require_attributes([:completed_at])
      accept([:completed_at, :final_response_id, :turn_outcome, :data])
      change(transition_state(:completed))
    end

    in_tx_update :dead_letter do
      require_attributes([:dead_letter_at, :dead_letter_reason])
      accept([:dead_letter_at, :dead_letter_reason])
      change(transition_state(:dead_letter))
    end

    in_tx_update :revise_input do
      accept([:data, :occurred_at, :provider_message_id, :available_at])
    end

    in_tx_update :update_metadata do
      accept([
        :data,
        :extensions,
        :queue_sequence,
        :provider_thread_id,
        :provider_message_id,
        :ambient_asked_message_id,
        :message_id,
        :occurred_at
      ])
    end

    in_tx_update :reauthorize do
      accept([:authorization_kind, :human_uid, :human_access_version])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(false)
    end

    atomic_in_tx_update :revoke_unstarted do
      require_attributes([:dead_letter_at, :dead_letter_reason])
      accept([:dead_letter_at, :dead_letter_reason])
      change(transition_state(:dead_letter))
    end
  end

  @doc "Checks private intake provenance, independent of CloudEvent facts."
  @spec produced_by_kernel?(term()) :: boolean()
  def produced_by_kernel?(%__MODULE__{producer: :kernel}), do: true
  def produced_by_kernel?(_signal), do: false

  @doc "Returns the CloudEvent encoded from the canonical signal facts."
  def envelope(%__MODULE__{} = signal) do
    envelope = %{
      "specversion" => "1.0",
      "id" => signal.source_event_id,
      "source" => signal.source,
      "type" => signal.type,
      "time" => DateTime.to_iso8601(signal.occurred_at),
      "data" => signal.data
    }

    envelope =
      if is_nil(signal.subject), do: envelope, else: Map.put(envelope, "subject", signal.subject)

    reserved = ~w(specversion id source type subject time data data_base64)
    Map.merge(Map.drop(signal.extensions || %{}, reserved), envelope)
  end

  @doc "Returns the provider entry that a reply anchors to."
  def reply_anchor_provider_message_id(
        %__MODULE__{ambient_asked_message_id: id, conversation_id: conversation_id} = event
      )
      when is_binary(id) and is_binary(conversation_id) do
    case Repo.get_by(ExternalMessageRef, message_id: id, conversation_id: conversation_id) do
      %ExternalMessageRef{provider_message_id: provider_id} -> provider_id
      _ -> event.provider_message_id
    end
  end

  def reply_anchor_provider_message_id(%__MODULE__{} = event), do: event.provider_message_id

  def scheduled_delivery_snapshot(%__MODULE__{producer: :kernel, type: "cron.fire", data: data})
      when is_map(data),
      do: get_in(data, ["wake_payload", "delivery"])

  def scheduled_delivery_snapshot(%__MODULE__{producer: :kernel, type: type, data: data})
      when is_map(data) and
             type in [
               "background_agent_job.completed",
               "background_agent_job.failed",
               "workflow.run.completed",
               "workflow.run.failed"
             ],
      do: get_in(data, ["reply_route", "delivery"])

  def scheduled_delivery_snapshot(%__MODULE__{}), do: nil

  def input_provider_message_ids(%__MODULE__{} = event) do
    source_ids(event, fn -> input_entry_ids(event.data) end)
  end

  def provider_message_ids(%__MODULE__{} = event) do
    source_ids(event, fn -> input_entry_ids(event.data) end)
  end

  defp source_ids(
         %__MODULE__{conversation_id: conversation_id, provider_message_id: provider_id} = event,
         data_ids
       )
       when is_binary(conversation_id) and is_binary(provider_id) do
    ids = if is_binary(event.message_id), do: data_ids.(), else: []
    entry_ids(event, [provider_id | ids])
  end

  defp source_ids(_event, _data_ids), do: []

  defp entry_ids(
         %__MODULE__{type: "input.revised", data: %{"revision" => %{"kind" => "remove"}}},
         _ids
       ),
       do: []

  defp entry_ids(_event, ids),
    do: ids |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

  defp input_entry_ids(data) when is_map(data), do: message_entry_ids(data["entries"])
  defp input_entry_ids(_data), do: []

  defp message_entry_ids(entries) when is_list(entries) do
    Enum.flat_map(entries, fn
      %{"provider_message_id" => id} when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp message_entry_ids(_entries), do: []

  @doc false
  @spec put_retry_metadata(map(), String.t(), String.t(), map()) :: map()
  def put_retry_metadata(payload, retry_signal_id, reason, extra)
      when is_map(payload) do
    entry =
      payload
      |> get_in(["data", "entry"])
      |> case do
        %{} = entry -> entry
        _value -> %{}
      end
      |> Map.merge(extra)
      |> Map.put("retry_of_signal_id", retry_signal_id)
      |> Map.put("retry_reason", reason)

    data =
      payload
      |> Map.get("data", %{})
      |> Map.put("entry", entry)

    Map.put(payload, "data", data)
  end

  def put_retry_metadata(_payload, retry_signal_id, reason, extra) do
    put_retry_metadata(
      %{"data" => %{"entry" => %{}}},
      retry_signal_id,
      reason,
      extra
    )
  end
end
