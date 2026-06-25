defmodule Ankole.ActorRuntime.Schemas.ActorInputDelivery do
  @moduledoc """
  Runtime projection of an actor input delivery attempt.

  Delivery rows fence the gap between queued actor input and worker acceptance.
  They are intentionally lighter than AI-agent transcript rows and can be
  superseded or deleted after the durable commit path finishes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Actors.ActorInput
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  # Delivery lifecycle. `created/sent/accepted` are the "live" set (a worker may
  # still act on the turn); `send_failed/superseded` are terminal and ignorable.
  # The runtime treats the live set as the fence that blocks re-sending an input.
  @states ~w(created sent send_failed accepted superseded)
  # Transport-level outcome of the ZeroMQ send, kept separate from `state` so an
  # operator can tell *why* a send failed (route gone, backpressure, timeout, …).
  @send_outcomes ~w(sent_or_queued unknown_route backpressure timeout socket_closed)

  schema "actor_input_deliveries" do
    belongs_to :actor_input, ActorInput, type: :binary_id

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :session_id, :string
    field :broker_sequence, :integer
    # Monotonic per-input attempt counter. A retry of the same actor input gets a
    # higher attempt_no, which keeps the per-input unique index from colliding.
    field :attempt_no, :integer
    field :delivery_batch_id, Ecto.UUID
    field :actor_bus_message_id, :string
    field :correlation_id, :string
    # The fence quintet copied from the activation onto each delivery row:
    # activation_uid + actor_epoch + llm_turn_id + revision (+ actor_key). A worker
    # reply must echo all of these or it is rejected as stale (see
    # ActorRuntime.delivery_matches_turn_ref/2). Storing them redundantly here lets
    # stale-reply checks run as plain equality against the DB, with no in-memory
    # session state required.
    field :activation_uid, :string
    field :actor_epoch, :integer
    field :llm_turn_id, Ecto.UUID
    field :revision, :integer
    field :worker_id, :string
    field :worker_instance_id, :string
    field :transport_route, :string
    field :state, :string, default: "created"
    field :send_outcome, :string
    field :sent_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :superseded_at, :utc_datetime_usec
    field :error, :map, default: %{}

    timestamps()
  end

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :actor_input_id,
      :agent_uid,
      :session_id,
      :broker_sequence,
      :attempt_no,
      :delivery_batch_id,
      :actor_bus_message_id,
      :correlation_id,
      :activation_uid,
      :actor_epoch,
      :llm_turn_id,
      :revision,
      :worker_id,
      :worker_instance_id,
      :transport_route,
      :state,
      :send_outcome,
      :sent_at,
      :accepted_at,
      :failed_at,
      :superseded_at,
      :error
    ])
    |> normalize_blank([
      :agent_uid,
      :session_id,
      :actor_bus_message_id,
      :correlation_id,
      :activation_uid,
      :worker_id,
      :worker_instance_id,
      :transport_route,
      :state,
      :send_outcome
    ])
    |> normalize_uid(:agent_uid)
    |> validate_required([
      :actor_input_id,
      :agent_uid,
      :session_id,
      :broker_sequence,
      :attempt_no,
      :delivery_batch_id,
      :actor_bus_message_id,
      :activation_uid,
      :actor_epoch,
      :llm_turn_id,
      :revision,
      :state,
      :error
    ])
    |> validate_number(:broker_sequence, greater_than: 0)
    |> validate_number(:attempt_no, greater_than: 0)
    |> validate_number(:actor_epoch, greater_than: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:send_outcome, @send_outcomes, allow_nil: true)
    |> JsonPayload.validate_map(:error, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:actor_input_id, :attempt_no],
      name: :actor_input_deliveries_actor_input_attempt_index
    )
    # Partial index (in the migration) enforces at most one *live* delivery per
    # actor input. This is the DB-level guarantee that one queued input maps to at
    # most one in-flight worker turn, so two workers never answer the same input.
    |> unique_constraint([:actor_input_id], name: :actor_input_deliveries_live_actor_input_index)
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
