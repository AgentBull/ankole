defmodule Ankole.Brain.Schemas.ObjectVersion do
  @moduledoc "One immutable body snapshot taken in the transaction that updates its object."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain.Domain

  postgres do
    table("brain_object_versions")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:object_id, "brain_object_versions_object_id_fkey"}])

    check_constraints do
      check_constraint(:meta, "brain_object_versions_meta_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:author, Ankole.Ash.Types.ActorRef)
    attribute(:body, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
    attribute(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})

    attribute(:tags, {:array, :string},
      allow_nil?: false,
      default: [],
      constraints: [items: [trim?: false, allow_empty?: true]]
    )

    attribute(:snapshot_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  actions do
    defaults([:read])

    create :snapshot do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept([:object_id, :author, :body, :meta, :tags])
    end
  end

  @type t :: %__MODULE__{}
end
