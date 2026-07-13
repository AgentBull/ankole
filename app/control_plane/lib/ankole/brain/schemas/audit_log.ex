defmodule Ankole.Brain.Schemas.AuditLog do
  @moduledoc "Append-only structured snapshots for knowledge mutation recovery and attribution."

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.Principal

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "brain_audit_log" do
    belongs_to :owner, Principal,
      foreign_key: :owner_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :store_key, :string
    field :actor_kind, Ecto.Enum, values: [:human, :agent, :dreaming]

    belongs_to :actor, Principal,
      foreign_key: :actor_uid,
      references: :uid,
      type: Ankole.Ecto.PrincipalKey

    field :action, :string
    field :entry_id, Ecto.UUID
    field :block_id, Ecto.UUID
    field :relation_id, Ecto.UUID
    field :before, :map
    field :after, :map
    field :metadata, :map, default: %{}
    timestamps(updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :owner_uid,
      :store_key,
      :actor_kind,
      :actor_uid,
      :action,
      :entry_id,
      :block_id,
      :relation_id,
      :before,
      :after,
      :metadata
    ])
    |> normalize_blank([:owner_uid, :store_key, :actor_uid, :action])
    |> validate_required([:owner_uid, :store_key, :action, :metadata])
    |> validate_optional_map(:before)
    |> validate_optional_map(:after)
    |> JSONPayload.validate_map(:metadata)
    |> foreign_key_constraint(:owner_uid)
    |> foreign_key_constraint(:actor_uid)
    |> check_constraint(:store_key, name: :brain_audit_log_store_key_check)
    |> check_constraint(:action, name: :brain_audit_log_action_present)
    |> check_constraint(:before, name: :brain_audit_log_before_object)
    |> check_constraint(:after, name: :brain_audit_log_after_object)
    |> check_constraint(:metadata, name: :brain_audit_log_metadata_object)
  end

  defp validate_optional_map(changeset, field) do
    case get_change(changeset, field, :unchanged) do
      value when value in [:unchanged, nil] -> changeset
      _value -> JSONPayload.validate_map(changeset, field, allow_datetime: true)
    end
  end
end
