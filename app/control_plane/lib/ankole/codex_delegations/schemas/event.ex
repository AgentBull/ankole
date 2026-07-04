defmodule Ankole.CodexDelegations.Schemas.Event do
  @moduledoc """
  Durable Codex delegation trajectory event.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.CodexDelegations.Schemas.Delegation
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]
  @directions ~w(client_to_server server_to_client server_request client_response process queue audit tool)

  schema "codex_delegation_events" do
    belongs_to(:delegation, Delegation, type: :binary_id)

    belongs_to(:agent, Principal,
      foreign_key: :agent_uid,
      references: :uid,
      type: :string
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
    |> normalize_uid(:agent_uid)
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
    |> JsonPayload.validate_map(:payload, allow_datetime: true)
    |> JsonPayload.validate_map(:redaction, allow_datetime: true)
    |> foreign_key_constraint(:delegation_id)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:delegation_id, :seq],
      name: :codex_delegation_events_delegation_seq_index
    )
    |> check_constraint(:direction, name: :codex_delegation_events_direction_check)
    |> check_constraint(:payload, name: :codex_delegation_events_payload_object)
    |> check_constraint(:redaction, name: :codex_delegation_events_redaction_object)
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
