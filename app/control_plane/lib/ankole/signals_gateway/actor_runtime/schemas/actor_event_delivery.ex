defmodule Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery do
  @moduledoc """
  Runtime projection of an actor event delivery attempt.

  Delivery rows fence the gap between a queued actor event and worker acceptance.
  They are intentionally lighter than AI-gateway message rows and can be
  superseded or deleted after the durable commit path finishes. One worker
  execution processes exactly one `actor_event_id`.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  # Delivery lifecycle. `created/sent/accepted` are the "live" set (a worker may
  # still act on the event); `send_failed/superseded` are terminal and ignorable.
  @states ~w(created sent send_failed accepted superseded)
  @live_states ~w(created sent accepted)
  @worker_applied_states ~w(sent accepted)
  @send_outcomes ~w(sent_or_queued unknown_route backpressure timeout socket_closed)

  schema "actor_event_deliveries" do
    belongs_to :actor_event, ActorEvent, type: :binary_id

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :session_id, :string
    # Per-session event sequence copied from actor_events.
    field :queue_sequence, :integer
    field :attempt_no, :integer
    field :actor_lane_message_id, :string
    field :correlation_id, :string
    # These fields copy the activation fence onto each delivery row. Static
    # fields must match the active attempt. A terminal Worker revision is the
    # highest input revision that it applied, so it can be lower than the
    # activation revision.
    field :activation_uid, :string
    field :actor_epoch, :integer
    field :actor_event_id_fence, Ecto.UUID
    field :revision, :integer
    field :worker_id, :string
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

  @doc """
  Builds a changeset for actor event delivery rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :actor_event_id,
      :agent_uid,
      :session_id,
      :queue_sequence,
      :attempt_no,
      :actor_lane_message_id,
      :correlation_id,
      :activation_uid,
      :actor_epoch,
      :actor_event_id_fence,
      :revision,
      :worker_id,
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
      :actor_lane_message_id,
      :correlation_id,
      :activation_uid,
      :worker_id,
      :transport_route,
      :state,
      :send_outcome
    ])
    |> validate_required([
      :actor_event_id,
      :agent_uid,
      :session_id,
      :queue_sequence,
      :attempt_no,
      :actor_lane_message_id,
      :activation_uid,
      :actor_epoch,
      :actor_event_id_fence,
      :revision,
      :state,
      :error
    ])
    |> validate_number(:queue_sequence, greater_than: 0)
    |> validate_number(:attempt_no, greater_than: 0)
    |> validate_number(:actor_epoch, greater_than: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:send_outcome, @send_outcomes, allow_nil: true)
    |> JSONPayload.validate_map(:error, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:actor_event_id, :attempt_no],
      name: :actor_event_deliveries_event_attempt_index
    )
    # Partial index (in the migration) enforces at most one *live* delivery per
    # actor event. This is the DB-level guarantee that one queued event maps to at
    # most one in-flight worker turn, so two workers never answer the same event.
    |> unique_constraint([:actor_event_id], name: :actor_event_deliveries_live_event_index)
  end

  @doc """
  Delivery states that count as "live": a worker may still be acting on the event,
  so the runtime treats them as the fence that blocks re-sending an actor event.
  """
  @spec live_states() :: [String.t()]
  def live_states, do: @live_states

  @doc """
  Returns true when a dispatched delivery belongs to the Worker-applied input
  prefix for a terminal Turn revision.
  """
  @spec applied_by_worker?(struct(), non_neg_integer()) :: boolean()
  def applied_by_worker?(%__MODULE__{state: state, revision: revision}, worker_revision)
      when is_integer(worker_revision) and worker_revision >= 0 do
    state in @worker_applied_states and revision <= worker_revision
  end
end
