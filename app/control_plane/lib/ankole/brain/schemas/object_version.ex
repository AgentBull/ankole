defmodule Ankole.Brain.Schemas.ObjectVersion do
  @moduledoc "One immutable body snapshot taken in the transaction that updates its object."
  use Ankole.Ash.Resource,
    authorizers: [Ankole.AuthZ.Authorizer],
    tenancy: :tenant,
    domain: Ankole.Brain,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_list, resource: "site_console:brain", action: "read")
  end

  json_api do
    type("brain_object_version")
    derive_filter?(false)
    derive_sort?(false)
    default_fields([:author, :body, :meta, :tags, :snapshot_at])
  end

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
    attribute(:author, Ankole.Ash.Types.ActorRef, public?: true)

    attribute(:body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false, public?: true, default: %{})

    attribute(:tags, {:array, :string},
      allow_nil?: false,
      public?: true,
      default: [],
      constraints: [items: [trim?: false, allow_empty?: true]]
    )

    attribute(:snapshot_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )
  end

  actions do
    defaults([:read])

    # The Console version history of one Object; the slug can be an alias.
    read :console_list do
      pagination(keyset?: true, default_limit: 100, max_page_size: 100, countable: false)

      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      prepare(__MODULE__.Preparations)
    end

    create :snapshot do
      accept([:object_id, :author, :body, :meta, :tags])
    end
  end

  @type t :: %__MODULE__{}
end
