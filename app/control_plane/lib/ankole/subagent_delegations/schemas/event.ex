defmodule Ankole.SubagentDelegations.Schemas.Event do
  @moduledoc """
  Durable subagent delegation trajectory event.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.Principals.Principal
  alias Ankole.Ecto.JSONPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @directions ~w(client_to_server server_to_client server_request client_response process queue audit tool)

  schema "subagent_delegation_events" do
    belongs_to(:delegation, Delegation, type: :binary_id)

    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey
    )

    field(:seq, :integer)
    field(:direction, :string)
    field(:event_type, :string)
    field(:payload, :map)
    field(:redaction, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    timestamps()
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :delegation_id,
      :agent_uid,
      :seq,
      :direction,
      :event_type,
      :payload,
      :redaction,
      :occurred_at
    ])
    |> normalize_blank([:agent_uid, :direction, :event_type])
    |> validate_required([
      :delegation_id,
      :agent_uid,
      :seq,
      :direction,
      :event_type,
      :payload,
      :redaction,
      :occurred_at
    ])
    |> validate_number(:seq, greater_than_or_equal_to: 0)
    |> validate_inclusion(:direction, @directions)
    |> JSONPayload.validate_map(:payload, allow_datetime: true)
    |> JSONPayload.validate_map(:redaction, allow_datetime: true)
    |> foreign_key_constraint(:delegation_id)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:delegation_id, :seq],
      name: :subagent_delegation_events_delegation_seq_index
    )
    |> check_constraint(:direction, name: :subagent_delegation_events_direction_check)
    |> check_constraint(:payload, name: :subagent_delegation_events_payload_object)
    |> check_constraint(:redaction, name: :subagent_delegation_events_redaction_object)
  end
end
