defmodule Ankole.Conversations.Delivery.Intent do
  @moduledoc """
  Durable protocol operation for an external Conversation.

  Pending rows have a bounded attempt budget. A timestamp fences an in-flight
  attempt. Sent rows reference the public Message recorded in the same commit.
  Failed and expired rows stop; unknown sends require explicit operator action.
  """

  use Ankole.Schema, tenancy: :tenant

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key false
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "deliveries" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey,
      primary_key: true

    field :binding_name, :string, primary_key: true
    field :outbound_key, :string, primary_key: true

    field :delivery_class, Ecto.Enum,
      values: [:generic, :durable_ai_reply],
      default: :generic

    # The provider-visible action this row represents. `reply_to_provider_message_id`
    # is the entry being replied to; `target_provider_message_id` is the entry an
    # edit/delete/reaction acts on; `created_provider_message_id` is filled in after a
    # successful post with the id the provider assigned to the new entry.
    field :operation, Ecto.Enum,
      values: [:post, :reply, :edit, :delete, :reaction_add, :reaction_remove, :divider, :card]

    field :status, Ecto.Enum,
      values: [:pending, :sent, :failed, :expired, :unknown],
      default: :pending

    field :conversation_id, Ecto.UUID
    field :provider_thread_id, :string
    field :reply_to_provider_message_id, :string
    field :target_provider_message_id, :string
    field :created_provider_message_id, :string
    field :created_message_id, Ecto.UUID
    field :target_message_id, Ecto.UUID
    field :reply_to_message_id, Ecto.UUID
    field :expires_at, :utc_datetime_usec
    # Back-references to where this side effect originated, for audit/recovery.
    field :source_signal_id, Ecto.UUID
    field :ai_message_id, Ecto.UUID
    field :payload, :map, default: %{}
    # Plain-text rendering used both as the search/mirror text and as the
    # fallback when a rich operation (card/divider) needs a text representation.
    field :fallback_visible_text, :string
    field :idempotency_key, :string
    field :attempt_count, :integer, default: 0
    # Hard automatic provider-call ceiling for every delivery class.
    field :max_attempts, :integer, default: 10
    field :last_error, :map, default: %{}
    # Set the moment dispatch tells the adapter to send. If the node restarts
    # while still in `:pending`, this timestamp is the signal that a provider
    # call may already be in flight, triggering reconcile-or-mark-unknown
    # recovery instead of a blind resend (see in_flight_recovery_action/2).
    field :platform_send_started_at, :utc_datetime_usec
    # When a `:failed` or recoverable `:unknown` row becomes eligible
    # for its next attempt. This is nil after exhaustion or a blocking failure.
    field :next_attempt_at, :utc_datetime_usec
    # Adapter-supplied breadcrumb carried across a reconcile (e.g. a provider
    # idempotency token) so recovery can confirm a prior send.
    field :recovery_state, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for signal gateway intent rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :agent_uid,
      :binding_name,
      :outbound_key,
      :delivery_class,
      :operation,
      :status,
      :conversation_id,
      :provider_thread_id,
      :reply_to_provider_message_id,
      :target_provider_message_id,
      :created_provider_message_id,
      :created_message_id,
      :target_message_id,
      :reply_to_message_id,
      :expires_at,
      :source_signal_id,
      :ai_message_id,
      :payload,
      :fallback_visible_text,
      :idempotency_key,
      :attempt_count,
      :max_attempts,
      :last_error,
      :platform_send_started_at,
      :next_attempt_at,
      :recovery_state
    ])
    |> normalize_blank([
      :agent_uid,
      :binding_name,
      :outbound_key,
      :delivery_class,
      :conversation_id,
      :provider_thread_id,
      :reply_to_provider_message_id,
      :target_provider_message_id,
      :created_provider_message_id,
      :fallback_visible_text,
      :idempotency_key
    ])
    |> validate_required([
      :agent_uid,
      :binding_name,
      :outbound_key,
      :delivery_class,
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
    |> JSONPayload.validate_map(:payload)
    |> JSONPayload.validate_map(:last_error, allow_datetime: true)
    |> JSONPayload.validate_map(:recovery_state, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :binding_name, :outbound_key],
      name: :deliveries_pkey
    )
    |> check_constraint(:payload, name: :deliveries_payload_object)
    |> check_constraint(:last_error, name: :deliveries_last_error_object)
    |> check_constraint(:recovery_state,
      name: :deliveries_recovery_state_object
    )
    |> check_constraint(:attempt_count,
      name: :deliveries_attempts_non_negative
    )
    |> check_constraint(:delivery_class,
      name: :deliveries_delivery_class_check
    )
  end
end
