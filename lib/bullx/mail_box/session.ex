defmodule BullX.MailBox.Session do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.MailBox.Entry
  alias BullX.Principals.Agent

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "mailbox_sessions" do
    belongs_to :agent, Agent, foreign_key: :agent_uid, references: :uid, type: :string

    field :session_key, :string
    field :last_entry_at, :utc_datetime_usec
    field :lease_holder, :string
    field :lease_expires_at, :utc_datetime_usec

    has_many :entries, Entry, foreign_key: :mailbox_session_id

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) when is_map(attrs) do
    session
    |> cast(attrs, [
      :agent_uid,
      :session_key,
      :last_entry_at,
      :lease_holder,
      :lease_expires_at
    ])
    |> validate_required([:agent_uid, :session_key, :last_entry_at])
    |> validate_non_empty(:session_key)
    |> foreign_key_constraint(:agent_uid)
    |> unique_constraint([:agent_uid, :session_key])
    |> check_constraint(:session_key, name: :mailbox_sessions_session_key_present)
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
