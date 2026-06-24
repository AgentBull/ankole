defmodule Ankole.SignalsGateway.OutboxEntry do
  @moduledoc """
  Durable provider-visible side-effect intent committed by an actor.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "signal_gateway_outbox" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string,
      primary_key: true

    field :binding_name, :string, primary_key: true
    field :outbound_key, :string, primary_key: true

    field :operation, Ecto.Enum,
      values: [:post, :reply, :edit, :delete, :reaction_add, :reaction_remove, :divider, :card]

    field :status, Ecto.Enum,
      values: [:created, :unsupported, :sending, :succeeded, :failed, :unknown_after_send],
      default: :created

    field :signal_channel_id, :string
    field :provider_thread_id, :string
    field :source_provider_entry_id, :string
    field :target_provider_entry_id, :string
    field :provider_entry_id, :string
    field :source_actor_input_id, Ecto.UUID
    field :llm_turn_id, Ecto.UUID
    field :assistant_message_id, Ecto.UUID
    field :payload, :map, default: %{}
    field :fallback_visible_text, :string
    field :idempotency_key, :string
    field :attempt_count, :integer, default: 0
    field :max_attempts, :integer, default: 10
    field :last_attempted_at, :utc_datetime_usec
    field :last_error, :map, default: %{}
    field :platform_send_started_at, :utc_datetime_usec
    field :next_attempt_at, :utc_datetime_usec
    field :recovery_state, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :outbound_key,
      :operation,
      :status,
      :signal_channel_id,
      :provider_thread_id,
      :source_provider_entry_id,
      :target_provider_entry_id,
      :provider_entry_id,
      :source_actor_input_id,
      :llm_turn_id,
      :assistant_message_id,
      :payload,
      :fallback_visible_text,
      :idempotency_key,
      :attempt_count,
      :max_attempts,
      :last_attempted_at,
      :last_error,
      :platform_send_started_at,
      :next_attempt_at,
      :recovery_state
    ])
    |> normalize_blank([
      :agent_uid,
      :binding_name,
      :outbound_key,
      :signal_channel_id,
      :provider_thread_id,
      :source_provider_entry_id,
      :target_provider_entry_id,
      :provider_entry_id,
      :fallback_visible_text,
      :idempotency_key
    ])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :agent_uid,
      :binding_name,
      :outbound_key,
      :operation,
      :status,
      :payload,
      :attempt_count,
      :max_attempts,
      :last_error,
      :recovery_state
    ])
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> JsonPayload.validate_map(:payload)
    |> JsonPayload.validate_map(:last_error, allow_datetime: true)
    |> JsonPayload.validate_map(:recovery_state, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :binding_name, :outbound_key],
      name: :signal_gateway_outbox_pkey
    )
    |> check_constraint(:payload, name: :signal_gateway_outbox_payload_object)
    |> check_constraint(:last_error, name: :signal_gateway_outbox_last_error_object)
    |> check_constraint(:recovery_state, name: :signal_gateway_outbox_recovery_state_object)
    |> check_constraint(:attempt_count, name: :signal_gateway_outbox_attempts_non_negative)
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
