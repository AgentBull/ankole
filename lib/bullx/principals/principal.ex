defmodule BullX.Principals.Principal do
  @moduledoc """
  Durable BullX subject shared by Humans and Agents.

  This is the row that gives BullX one of its defining properties: humans and
  AI Agents are the *same kind of entity* in the authorization and audit
  model. An Agent's permissions, Budget, outbound channel identity, and
  ownership relations are stored on a Principal row exactly like a human's
  are; type-specific facts (a human's external identities, an Agent's
  profile and toolsets) live in one-to-one extension tables. ACL checks,
  Budget charges, ApprovalRequest assignees, and Conversation participants
  all reference Principals uniformly, which is what lets an Agent ask a
  human for approval, hand off Work to another Agent, or be granted access
  to a channel — without those flows needing separate "agent" and "user"
  code paths.

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
