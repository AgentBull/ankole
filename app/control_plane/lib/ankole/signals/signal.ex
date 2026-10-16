defmodule Ankole.Signals.Signal do
  @moduledoc """
  Durable stimulus accepted by Signals and consumed by Sessions.

  A signal is a durable lifecycle row in the session queue. Normal
  completion is recorded as a timestamp rather than as a state enum, and
  `input_state` is constrained to only `open | dead_letter`.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Conversations.ExternalMessageRef
  alias Ankole.Repo

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @states ~w(open dead_letter)
  @turn_outcomes ~w(loop_finished iteration_exhausted silent)

  @type t :: %__MODULE__{}

  schema "signals" do
    has_one :preview, PreviewState, foreign_key: :signal_id
    field(:producer, Ecto.Enum, values: [:kernel, :external], default: :external)
    field(:authorization_kind, :string, default: "review_required")
    field(:human_uid, Ankole.Ecto.PrincipalKey)
    field(:human_access_version, :integer)

    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:source, :string)
    field(:subject, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:reply_binding_name, :string)
    field(:message_id, Ankole.Ecto.UUIDv7)
    field(:session_id, :string)
    field(:source_event_id, :string)
    field(:conversation_id, Ankole.Ecto.UUIDv7)
    field(:provider_thread_id, :string)
    field(:provider_message_id, :string)
    # Ambient attribution: when the recognizer accepts an asked_by message,
    # replies anchor to that entry instead of the batch tail provider_message_id.
    field(:ambient_asked_message_id, Ankole.Ecto.UUIDv7)
    field(:type, :string)
    field(:available_at, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 0)
    field(:provider_capacity_attempt_count, :integer, default: 0)
    field(:last_attempt_at, :utc_datetime_usec)
    # Per-session sequence for ordering currently open signals.
    field(:queue_sequence, :integer)
    # Only open | dead_letter. Normal completion is recorded separately.
    field(:input_state, :string, default: "open")
    field(:completed_at, :utc_datetime_usec)
    field(:final_response_id, :string)
    field(:turn_outcome, :string)
    field(:sender_key, :string)
    field(:data, Ankole.Types.JSONValue, default: %{})
    field(:extensions, :map, default: %{})
    field(:dead_letter_at, :utc_datetime_usec)
    # Bounded, redacted copy of the failure that dead-lettered the event.
    field(:dead_letter_reason, :map)

    timestamps()
  end

  @doc "Checks private intake provenance, independent of CloudEvent facts."
  @spec produced_by_kernel?(term()) :: boolean()
  def produced_by_kernel?(%__MODULE__{producer: :kernel}), do: true
  def produced_by_kernel?(_signal), do: false

  @doc """
  Builds a changeset for signal rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(input, attrs) do
    input
    |> cast(attrs, [
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
      :attempt_count,
      :provider_capacity_attempt_count,
      :last_attempt_at,
      :queue_sequence,
      :input_state,
      :completed_at,
      :final_response_id,
      :turn_outcome,
      :sender_key,
      :data,
      :extensions,
      :occurred_at,
      :message_id,
      :dead_letter_at,
      :dead_letter_reason
    ])
    |> normalize_blank([
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
      :input_state,
      :final_response_id,
      :turn_outcome,
      :sender_key
    ])
    |> validate_required([
      :producer,
      :agent_uid,
      :source,
      :session_id,
      :source_event_id,
      :type,
      :available_at,
      :queue_sequence,
      :input_state,
      :occurred_at
    ])
    |> check_constraint(:producer, name: :signals_producer_check)
    |> validate_inclusion(:input_state, @states)
    |> validate_inclusion(:turn_outcome, @turn_outcomes, allow_nil: true)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:provider_capacity_attempt_count, greater_than_or_equal_to: 0)
    |> check_constraint(:provider_capacity_attempt_count,
      name: :signals_capacity_attempt_count_check
    )
    |> JSONPayload.validate_json(:data)
    |> JSONPayload.validate_map(:extensions)
    |> JSONPayload.validate_map(:dead_letter_reason)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:tenant_id, :agent_uid, :source, :source_event_id],
      name: :signals_signal_idempotency_index
    )
    |> unique_constraint([:tenant_id, :agent_uid, :session_id, :queue_sequence],
      name: :signals_queue_sequence_index
    )
    |> foreign_key_constraint(:message_id)
    |> foreign_key_constraint(:conversation_id, name: :signals_conversation_id_fkey)
    |> check_constraint(:input_state, name: :signals_input_state_check)
    |> check_constraint(:attempt_count, name: :signals_attempt_count_non_negative)
    |> check_constraint(:turn_outcome, name: :signals_turn_outcome_check)
    |> check_constraint(:final_response_id, name: :signals_completion_anchor_check)
  end

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

  def withdrawal_provider_message_ids(%__MODULE__{} = event) do
    source_ids(event, fn ->
      input_entry_ids(event.data) ++ resolved_reply_entry_ids(event.data)
    end)
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

  defp resolved_reply_entry_ids(%{
         "entry" => %{"reply_to" => %{"resolution" => "resolved", "provider_message_id" => id}}
       }),
       do: [id]

  defp resolved_reply_entry_ids(_data), do: []

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
