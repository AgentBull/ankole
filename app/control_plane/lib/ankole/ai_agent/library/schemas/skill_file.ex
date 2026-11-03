defmodule Ankole.AIAgent.Library.Schemas.SkillFile do
  @moduledoc "An immutable object reference inside a Skill package."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AIAgent

  postgres do
    table("skill_files")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(path: "skill_files_tenant_id_skill_id_relative_path_key")
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:skill_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:relative_path, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:mode, :integer, allow_nil?: false, default: 0o444)
    attribute(:content_type, :string, allow_nil?: false)
    create_timestamp(:created_at, type: Ankole.Ash.Types.Timestamptz)
    update_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz)
  end

  identities do
    identity(:path, [:skill_id, :relative_path])
  end

  actions do
    defaults([:read])

    create :put do
      transaction?(false)
      accept([:skill_id, :relative_path, :object_id, :mode, :content_type])
      upsert?(true)
      upsert_identity(:path)
      upsert_fields([:object_id, :mode, :content_type, :updated_at])
    end

    update :rename do
      transaction?(false)
      require_atomic?(true)
      accept([:relative_path])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
