defmodule Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation do
  @moduledoc """
  Live activation and lease projection for one actor session.

  Activations give worker replies a durable fence: actor key, activation uid,
  actor epoch, actor event id, and revision must all match before a worker
  update is accepted.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  # `starting/active/draining` are the "live" statuses (the activation owns the
  # session); `stopped/failed` are terminal. Only one live activation may exist
  # per actor key at a time (enforced by a partial unique index, see changeset).
  @statuses ~w(starting active draining stopped failed)

  schema "actor_session_activations" do
    field :activation_uid, :string

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :session_id, :string
    # Monotonic generation counter for this actor key. A new activation after a
    # lease failure gets a higher epoch; the epoch is the cheap fence that makes a
    # late reply from the previous activation fail by simple inequality.
    field :actor_epoch, :integer
    field :status, :string
    field :controller_node, :string
    # Lease: the activation is only valid while now < lease_expires_at. The
    # watchdog fails an expired in-flight activation so its actor event can be
    # retried, but normally stops a warm activation whose current event is nil.
    field :lease_id, :string
    field :lease_expires_at, :utc_datetime_usec
    field :last_actor_heartbeat_at, :utc_datetime_usec
    field :assigned_worker_id, :string
    field :current_actor_event_id, Ecto.UUID
    # Bumped on every in-place steer/nudge of the live turn. Non-terminal
    # progress stays exact; terminal writes tolerate newer revisions because
    # active steer updates the same worker run before it completes.
    field :revision, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec
    field :stop_reason, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for actor session activation rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(activation, attrs) do
    activation
    |> cast(attrs, [
      :activation_uid,
      :agent_uid,
      :session_id,
      :actor_epoch,
      :status,
      :controller_node,
      :lease_id,
      :lease_expires_at,
      :last_actor_heartbeat_at,
      :assigned_worker_id,
      :current_actor_event_id,
      :revision,
      :started_at,
      :stopped_at,
      :stop_reason,
      :metadata
    ])
    |> normalize_blank([
      :activation_uid,
      :agent_uid,
      :session_id,
      :status,
      :controller_node,
      :lease_id,
      :assigned_worker_id,
      :stop_reason
    ])
    |> validate_required([
      :activation_uid,
      :agent_uid,
      :session_id,
      :actor_epoch,
      :status,
      :lease_id,
      :lease_expires_at,
      :revision,
      :started_at,
      :metadata
    ])
    |> validate_number(:actor_epoch, greater_than: 0)
    |> validate_number(:revision, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> JSONPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:activation_uid], name: :actor_session_activations_activation_uid_index)
    # Partial index (in the migration) over live statuses enforces a single live
    # activation per actor key. Creating a new epoch therefore requires failing
    # the old activation first, which is what serializes session ownership.
    |> unique_constraint([:agent_uid, :session_id],
      name: :actor_session_activations_live_actor_index
    )
  end
end
