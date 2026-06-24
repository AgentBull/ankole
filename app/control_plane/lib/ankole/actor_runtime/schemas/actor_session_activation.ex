defmodule Ankole.ActorRuntime.Schemas.ActorSessionActivation do
  @moduledoc """
  Live activation and lease projection for one actor session.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(starting active draining stopped failed)

  schema "actor_session_activations" do
    field :activation_uid, :string

    belongs_to :agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string

    field :session_id, :string
    field :actor_epoch, :integer
    field :status, :string
    field :controller_node, :string
    field :lease_id, :string
    field :lease_expires_at, :utc_datetime_usec
    field :last_actor_heartbeat_at, :utc_datetime_usec
    field :assigned_worker_id, :string
    field :assigned_worker_instance_id, :string
    field :current_llm_turn_id, Ecto.UUID
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
      :assigned_worker_instance_id,
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
      :assigned_worker_instance_id,
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
