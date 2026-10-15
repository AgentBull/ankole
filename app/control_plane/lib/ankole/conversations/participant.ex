defmodule Ankole.Conversations.Participant do
  @moduledoc "A Principal's membership of one shared conversation."
  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true
  import Ecto.Changeset

  @primary_key false
  schema "conversation_participants" do
    field :conversation_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :principal_uid, Ankole.Ecto.PrincipalKey, primary_key: true
    field :role, Ecto.Enum, values: [:owner, :member, :agent]
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:conversation_id, :principal_uid, :role])
    |> validate_required([:conversation_id, :principal_uid, :role])
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:principal_uid)
    |> unique_constraint([:tenant_id, :conversation_id, :principal_uid],
      name: :conversation_participants_pkey
    )
    |> check_constraint(:role, name: :conversation_participants_role_check)
  end
end
