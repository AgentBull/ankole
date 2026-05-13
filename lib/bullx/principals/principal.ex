defmodule BullX.Principals.Principal do
  @moduledoc """
  Durable BullX subject shared by Humans and Agents.

  The Principal row is the stable authorization, audit, ownership, and
  responsibility identity. Type-specific facts live in one-to-one extension
  tables.
  """

  use Ecto.Schema

  import BullX.Principals.Changeset
  import Ecto.Changeset

  alias BullX.Principals.{Agent, ExternalIdentity, HumanUser}

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "principals" do
    field :uid, :string
    field :type, Ecto.Enum, values: [:human, :agent]
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :display_name, :string
    field :bio, :string
    field :avatar_url, :string

    has_one :human_user, HumanUser
    has_one :agent, Agent
    has_many :external_identities, ExternalIdentity

    timestamps()
  end

  def changeset(principal, attrs) do
    principal
    |> cast(attrs, [:uid, :type, :status, :display_name, :bio, :avatar_url])
    |> normalize_blank([:uid, :display_name, :bio, :avatar_url])
    |> normalize_uid()
    |> validate_required([:uid, :type, :status])
    |> unique_constraint(:uid)
    |> check_constraint(:uid, name: :principals_uid_lowercase)
  end

  defp normalize_uid(changeset) do
    update_change(changeset, :uid, &String.downcase/1)
  end
end
