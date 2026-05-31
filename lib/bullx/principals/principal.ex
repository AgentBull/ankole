defmodule BullX.Principals.Principal do
  @moduledoc """
  Durable BullX subject shared by Humans and Agents.

  This is the row that gives BullX one of its defining properties: humans and
  AI Agents are the *same kind of entity* in the authorization and audit
  model. Current common subject facts live here: uid, type, status, display
  name, and avatar. Type-specific facts live in extension tables, such as a
  human's profile fields, channel/login identities, and an Agent's profile.
  AuthZ grants and AIAgent conversation rows reference Principals uniformly,
  which keeps current ACL checks from splitting into separate "agent" and
  "user" code paths.

  Future Budget, Approval, Work, outbound identity, and ownership records
  should also reference Principals when those surfaces are designed. They are
  not Principal table fields in the current branch.

  The Principal row is the stable current authorization and audit identity.
  Future ownership and responsibility records should point at this identity
  rather than introducing separate subject models. Type-specific facts live in
  one-to-one extension tables.
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
    field :avatar_url, :string

    has_one :human_user, HumanUser, foreign_key: :principal_uid, references: :uid
    has_one :agent, Agent, foreign_key: :uid, references: :uid
    has_many :external_identities, ExternalIdentity, foreign_key: :principal_uid, references: :uid

    timestamps()
  end

  def changeset(principal, attrs) do
    principal
    |> cast(attrs, [:uid, :type, :status, :display_name, :avatar_url])
    |> normalize_blank([:uid, :display_name, :avatar_url])
    |> normalize_uid()
    |> validate_required([:uid, :type, :status])
    |> unique_constraint(:uid)
    |> check_constraint(:uid, name: :principals_uid_lowercase)
  end

  defp normalize_uid(changeset) do
    update_change(changeset, :uid, &String.downcase/1)
  end
end
