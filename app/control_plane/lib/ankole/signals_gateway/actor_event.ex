defmodule Ankole.SignalsGateway.ActorEvent do
  @moduledoc """
  Durable actor-facing event accepted by SignalsGateway and processed by ActorRuntime.

  An actor event is a durable lifecycle row while it remains relevant to the
  session queue. Normal completion is recorded as a timestamp rather than as a
  state enum, and stale system events may be physically deleted by reset or
  retry cleanup paths. `input_state` is constrained to only `open | dead_letter`.
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
    field :reply_preview_source_entry_id, :string
    field :type, :string
    field :available_at, :utc_datetime_usec
    # Per-session sequence for ordering currently open actor events.
    field :queue_sequence, :integer
    # Only open | dead_letter. Normal completion is recorded separately.
    field :input_state, :string, default: "open"
    field :completed_at, :utc_datetime_usec
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
      :reply_preview_source_entry_id,
      :type,
      :available_at,
      :queue_sequence,
      :input_state,
      :completed_at,
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
      :reply_preview_source_entry_id,
      :type,
      :input_state,
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
    |> JSONPayload.validate_map(:payload)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :binding_name, :source_event_id],
      name: :actor_events_signal_idempotency_index
    )
    |> unique_constraint([:agent_uid, :session_id, :queue_sequence],
      name: :actor_events_queue_sequence_index
    )
    |> check_constraint(:payload, name: :actor_events_payload_object)
    |> check_constraint(:input_state, name: :actor_events_input_state_check)
  end
end
