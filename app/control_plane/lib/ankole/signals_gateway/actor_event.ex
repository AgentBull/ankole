defmodule Ankole.SignalsGateway.ActorEvent do
  @moduledoc """
  Durable actor-facing event accepted by SignalsGateway and processed by ActorRuntime.

  An actor event is a durable lifecycle row in the session queue. Normal
  completion is recorded as a timestamp rather than as a state enum, and
  `input_state` is constrained to only `open | dead_letter`.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @states ~w(open dead_letter)
  @turn_outcomes ~w(loop_finished iteration_exhausted)

  @type t :: %__MODULE__{}

  schema "actor_events" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :binding_name, :string
    field :session_id, :string
    field :source_event_id, :string
    field :signal_channel_id, :string
    field :provider_thread_id, :string
    field :source_entry_id, :string
    # Ambient attribution: when the recognizer accepts an asked_by message,
    # replies anchor to that entry instead of the batch tail source_entry_id.
    field :ambient_asked_source_entry_id, :string
    field :reply_preview_source_entry_id, :string
    field :reply_preview_checkpoint, :map
    field :reply_preview_sequence_high_water, :integer, default: 0
    field :reply_preview_cleanup_at, :utc_datetime_usec
    field :type, :string
    field :available_at, :utc_datetime_usec
    # Per-session sequence for ordering currently open actor events.
    field :queue_sequence, :integer
    # Only open | dead_letter. Normal completion is recorded separately.
    field :input_state, :string, default: "open"
    field :completed_at, :utc_datetime_usec
    field :final_response_id, :string
    field :turn_outcome, :string
    field :sender_key, :string
    field :payload, :map
    field :dead_letter_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Builds a changeset for actor event rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(input, attrs) do
    input
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :session_id,
      :source_event_id,
      :signal_channel_id,
      :provider_thread_id,
      :source_entry_id,
      :ambient_asked_source_entry_id,
      :reply_preview_source_entry_id,
      :reply_preview_checkpoint,
      :reply_preview_sequence_high_water,
      :reply_preview_cleanup_at,
      :type,
      :available_at,
      :queue_sequence,
      :input_state,
      :completed_at,
      :final_response_id,
      :turn_outcome,
      :sender_key,
      :payload,
      :dead_letter_at
    ])
    |> normalize_blank([
      :agent_uid,
      :binding_name,
      :session_id,
      :source_event_id,
      :signal_channel_id,
      :provider_thread_id,
      :source_entry_id,
      :ambient_asked_source_entry_id,
      :reply_preview_source_entry_id,
      :type,
      :input_state,
      :final_response_id,
      :turn_outcome,
      :sender_key
    ])
    |> validate_required([
      :agent_uid,
      :binding_name,
      :session_id,
      :source_event_id,
      :type,
      :available_at,
      :queue_sequence,
      :input_state,
      :payload
    ])
    |> validate_inclusion(:input_state, @states)
    |> validate_inclusion(:turn_outcome, @turn_outcomes, allow_nil: true)
    |> validate_number(:reply_preview_sequence_high_water, greater_than_or_equal_to: 0)
    |> JSONPayload.validate_map(:payload)
    |> JSONPayload.validate_map(:reply_preview_checkpoint)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :binding_name, :source_event_id],
      name: :actor_events_signal_idempotency_index
    )
    |> unique_constraint([:agent_uid, :session_id, :queue_sequence],
      name: :actor_events_queue_sequence_index
    )
    |> check_constraint(:payload, name: :actor_events_payload_object)
    |> check_constraint(:reply_preview_checkpoint,
      name: :actor_events_reply_preview_checkpoint_object
    )
    |> check_constraint(:reply_preview_sequence_high_water,
      name: :actor_events_reply_preview_sequence_non_negative
    )
    |> check_constraint(:input_state, name: :actor_events_input_state_check)
    |> check_constraint(:turn_outcome, name: :actor_events_turn_outcome_check)
    |> check_constraint(:final_response_id, name: :actor_events_completion_anchor_check)
  end

  @doc """
  Returns the entry a provider-visible reply for this event anchors to.
  """
  @spec reply_anchor_source_entry_id(t()) :: String.t() | nil
  def reply_anchor_source_entry_id(%__MODULE__{} = event) do
    event.ambient_asked_source_entry_id || event.source_entry_id
  end

  @doc false
  @spec source_entry_ids(t()) :: [String.t()]
  def source_entry_ids(%__MODULE__{} = event) do
    [event.source_entry_id | payload_source_entry_ids(event.payload)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp payload_source_entry_ids(%{"data" => data}) when is_map(data) do
    [Map.get(data, "entries"), get_in(data, ["channel_context", "messages"])]
    |> Enum.flat_map(&source_entry_ids_from_messages/1)
  end

  defp payload_source_entry_ids(_payload), do: []

  defp source_entry_ids_from_messages(entries) when is_list(entries) do
    Enum.map(entries, fn
      %{"source_entry_id" => source_entry_id} -> source_entry_id
      _entry -> nil
    end)
  end

  defp source_entry_ids_from_messages(_entries), do: []
end
