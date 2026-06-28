defmodule Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment do
  @moduledoc """
  Sticky placement hint from an actor session to a worker.

  Assignment improves locality and avoids unnecessary worker churn. It is not
  durable truth for a turn; delivery and activation rows still fence each
  in-flight actor input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(assigned draining released)

  schema "actor_session_worker_assignments" do
    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

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
    |> normalize_uid(:agent_uid)
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
