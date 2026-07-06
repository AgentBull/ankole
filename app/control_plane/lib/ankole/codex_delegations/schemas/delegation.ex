defmodule Ankole.CodexDelegations.Schemas.Delegation do
  @moduledoc """
  Durable Codex delegation task header.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @statuses ~w(queued running waiting_on_user succeeded failed stopped)

  schema "codex_delegations" do
    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:session_id, :string)
    field(:actor_event_id, Ecto.UUID)
    field(:tool_call_id, :string)
    field(:codex_thread_id, :string)
    field(:workdir, :string)
    field(:status, :string)
    field(:queued_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:result, :map, default: %{})
    field(:error, :map, default: %{})
    field(:metadata, :map, default: %{})

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(delegation, attrs) do
    delegation
    |> cast(attrs, [
      :agent_uid,
      :session_id,
      :actor_event_id,
      :tool_call_id,
      :codex_thread_id,
      :workdir,
      :status,
      :queued_at,
      :started_at,
      :completed_at,
      :result,
      :error,
      :metadata
    ])
    |> normalize_blank([
      :agent_uid,
      :session_id,
      :tool_call_id,
      :codex_thread_id,
      :workdir,
      :status
    ])
    |> validate_required([:agent_uid, :session_id, :status, :result, :error, :metadata])
    |> validate_inclusion(:status, @statuses)
    |> JsonPayload.validate_map(:result, allow_datetime: true)
    |> JsonPayload.validate_map(:error, allow_datetime: true)
    |> JsonPayload.validate_map(:metadata, allow_datetime: true)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:actor_event_id)
    |> check_constraint(:status, name: :codex_delegations_status_check)
    |> check_constraint(:result, name: :codex_delegations_result_object)
    |> check_constraint(:error, name: :codex_delegations_error_object)
    |> check_constraint(:metadata, name: :codex_delegations_metadata_object)
  end
end
