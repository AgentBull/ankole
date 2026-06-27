defmodule Ankole.Actors.ActorInput do
  @moduledoc """
  Durable actor input accepted by SignalsGateway and consumed by ActorRuntime.

  Actor input is the retryable work queue for one agent session. It stays open
  until a committed AI-agent turn consumes it, even if worker delivery attempts
  fail and are superseded.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @states ~w(open dead_letter)

  schema "actor_inputs" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :binding_name, :string
    field :session_id, :string
    field :ingress_event_id, :string
    field :signal_channel_id, :string
    field :provider_thread_id, :string
    field :provider_entry_id, :string
    field :type, :string
    field :available_at, :utc_datetime_usec
    field :broker_sequence, :integer
    field :input_state, :string, default: "open"
    field :sender_key, :string
    field :payload, :map
    field :dead_letter_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(input, attrs) do
    input
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :session_id,
      :ingress_event_id,
      :signal_channel_id,
      :provider_thread_id,
      :provider_entry_id,
      :type,
      :available_at,
      :broker_sequence,
      :input_state,
      :sender_key,
      :payload,
      :dead_letter_at
    ])
    |> normalize_blank([
      :agent_uid,
      :binding_name,
      :session_id,
      :ingress_event_id,
      :signal_channel_id,
      :provider_thread_id,
      :provider_entry_id,
      :type,
      :input_state,
      :sender_key
    ])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :agent_uid,
      :binding_name,
      :session_id,
      :ingress_event_id,
      :type,
      :available_at,
      :broker_sequence,
      :input_state,
      :payload
    ])
    |> validate_inclusion(:input_state, @states)
    |> JsonPayload.validate_map(:payload)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :binding_name, :ingress_event_id],
      name: :actor_inputs_signal_idempotency_index
    )
    |> unique_constraint([:agent_uid, :session_id, :broker_sequence],
      name: :actor_inputs_actor_sequence_index
    )
    |> check_constraint(:payload, name: :actor_inputs_payload_object)
    |> check_constraint(:input_state, name: :actor_inputs_input_state_check)
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
