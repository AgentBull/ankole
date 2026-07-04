defmodule Ankole.Actors.ActorEvent do
  @moduledoc """
  Durable actor-facing event accepted by SignalsGateway and processed by ActorRuntime.

  Formerly `actor_inputs`. An actor event is a durable lifecycle row: it is NOT
  deleted after processing, and there is no consumption marker (the old
  `actor_input_consumptions` table is gone). Whether an event is still running or
  finished is derived from delivery rows + `ai_gateway_conversations.generation`
  lease + `ai_gateway_messages.status` — not from a separate state field here.
  `input_state` is constrained to only `open | dead_letter`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @states ~w(open dead_letter)

  schema "actor_events" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :binding_name, :string
    field :session_id, :string
    field :source_event_id, :string
    field :signal_channel_id, :string
    field :provider_thread_id, :string
    field :source_entry_id, :string
    field :type, :string
    field :available_at, :utc_datetime_usec
    # Per-session sequence for ordering currently open actor events.
    field :queue_sequence, :integer
    # Only open | dead_letter. Completion is derived, not stored here.
    field :input_state, :string, default: "open"
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
      :type,
      :available_at,
      :queue_sequence,
      :input_state,
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
      :type,
      :input_state,
      :sender_key
    ])
    |> normalize_uid(:agent_uid)
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
    |> JsonPayload.validate_map(:payload)
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

  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, &normalize_blank(&2, &1))
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  defp normalize_uid(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
