defmodule BullX.MailBox.AcceptanceKey do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.Principals.Agent

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "mailbox_acceptance_keys" do
    belongs_to :agent, Agent, foreign_key: :agent_uid, references: :uid, type: :string

    field :idempotency_key, :string
    field :entry_id, :binary_id
    field :accepted_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(key, attrs) when is_map(attrs) do
    key
    |> cast(attrs, [:agent_uid, :idempotency_key, :entry_id, :accepted_at])
    |> validate_required([:agent_uid, :idempotency_key, :entry_id, :accepted_at])
    |> validate_non_empty(:idempotency_key)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :idempotency_key])
    |> check_constraint(:idempotency_key, name: :mailbox_acceptance_keys_key_present)
  end

  defp validate_non_empty(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_binary(value) and String.trim(value) != "" do
        true -> []
        false -> [{field, "must be a non-empty string"}]
      end
    end)
  end
end
