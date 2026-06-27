defmodule Ankole.ActorRuntime.Schemas.ActorSessionActivation do
  @moduledoc """
  Live activation and lease projection for one actor session.

  Activations give worker replies a durable fence: actor key, activation uid,
  actor epoch, turn id, and revision must all match before a proposal can commit.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
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
      type: :string

    field :session_id, :string
    # Monotonic generation counter for this actor key. A new activation after a
    # lease failure gets a higher epoch; the epoch is the cheap fence that makes a
    # late reply from the previous activation fail by simple inequality.
    field :actor_epoch, :integer
    field :status, :string
    field :controller_node, :string
    # Lease: the activation is only valid while now < lease_expires_at. The
    # watchdog fails expired activations so the actor input can be retried. The
    # lease_id labels the generation lease the AI-agent turn holds.
    field :lease_id, :string
    field :lease_expires_at, :utc_datetime_usec
    field :last_actor_heartbeat_at, :utc_datetime_usec
    field :assigned_worker_id, :string
    field :current_llm_turn_id, Ecto.UUID
    # Bumped on every in-place steer/nudge of the live turn. A worker reply must
    # echo the current revision, so a reply built before a steer is rejected.
    field :revision, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec
    field :stop_reason, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc false
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
      :current_llm_turn_id,
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
    |> normalize_uid(:agent_uid)
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
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:activation_uid], name: :actor_session_activations_activation_uid_index)
    # Partial index (in the migration) over live statuses enforces a single live
    # activation per actor key. Creating a new epoch therefore requires failing
    # the old activation first, which is what serializes session ownership.
    |> unique_constraint([:agent_uid, :session_id],
      name: :actor_session_activations_live_actor_index
    )
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
