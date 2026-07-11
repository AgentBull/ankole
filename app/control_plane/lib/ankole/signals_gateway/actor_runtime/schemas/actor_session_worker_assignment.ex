defmodule Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment do
  @moduledoc """
  Sticky placement hint from an actor session to a worker.

  Assignment improves locality and avoids unnecessary worker churn. It is not
  durable truth for a turn; delivery and activation rows still fence each
  in-flight actor event.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(assigned draining released)

  schema "actor_session_worker_assignments" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :session_id, :string
    field :worker_id, :string
    field :transport_route, :string
    field :status, :string
    field :workspace_mount, :string
    field :assigned_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps()
  end

  @doc """
  Builds a changeset for actor session worker assignment rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [
      :agent_uid,
      :session_id,
      :worker_id,
      :transport_route,
      :status,
      :workspace_mount,
      :assigned_at,
      :last_used_at,
      :metadata
    ])
    |> normalize_blank([
      :agent_uid,
      :session_id,
      :worker_id,
      :transport_route,
      :status,
      :workspace_mount
    ])
    |> validate_required([
      :agent_uid,
      :session_id,
      :worker_id,
      :status,
      :assigned_at,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    # Partial index (in the migration) keeps one live assignment per actor key, so
    # the sticky placement hint cannot fork into two workers for one session.
    |> unique_constraint([:agent_uid, :session_id],
      name: :actor_session_worker_assignments_live_actor_index
    )
  end
end
