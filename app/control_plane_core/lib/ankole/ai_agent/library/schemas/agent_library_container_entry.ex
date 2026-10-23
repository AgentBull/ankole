defmodule Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry do
  @moduledoc "Agent-owned runtime document; active paths retain their partial unique identity."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIAgent

  postgres do
    table("agent_library_container_entries")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(active_path: "agent_library_container_entries_active_path_index")
    identity_wheres_to_sql(active_path: "deleted_at IS NULL")
    foreign_key_names(agent_uid: "agent_library_container_entries_agent_uid_fkey")

    check_constraints do
      check_constraint(:path, "agent_library_container_entries_path_present")
      check_constraint(:source_kind, "agent_library_container_entries_source_kind_check")
      check_constraint(:metadata, "agent_library_container_entries_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false, public?: true)
    attribute(:path, :string, allow_nil?: false, public?: true)

    attribute(:source_kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:soul, :mission, :design, :confidentiality_policy]]
    )

    attribute(:content, :string, public?: true, constraints: [trim?: false, allow_empty?: true])
    attribute(:content_hash, :string, public?: true)

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true,
      constraints: [allow_datetime?: true]
    )

    attribute(:deleted_at, :utc_datetime_usec, public?: true)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  identities do
    identity(:active_path, [:agent_uid, :path],
      all_tenants?: true,
      where: expr(is_nil(deleted_at))
    )
  end

  actions do
    defaults([:read])

    create :put do
      accept([:agent_uid, :path, :source_kind, :content, :metadata])
      upsert?(true)
      upsert_identity(:active_path)
      upsert_fields([:source_kind, :content, :content_hash, :metadata, :deleted_at, :updated_at])
      change(Ankole.AIAgent.Library.Changes.PrepareDocument, only_when_valid?: true)
    end

    action :replace_document, :term do
      argument(:agent_uid, :term, allow_nil?: false)
      argument(:kind, :string, allow_nil?: false)
      argument(:content, :term, allow_nil?: false)
      argument(:expected_content_hash, :term, allow_nil?: false)

      run(__MODULE__.Actions)
    end
  end

  @type t :: %__MODULE__{}
end
