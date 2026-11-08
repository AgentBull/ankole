defmodule Ankole.Principals.ProfileAvatar do
  @moduledoc false
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Principals

  postgres do
    table("profile_avatars")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:object_id, "profile_avatars_object_fkey"}])
    unique_index_names([{[:key], "profile_avatars_pkey"}])

    check_constraints do
      check_constraint(:content_type, "profile_avatars_content_type")
    end
  end

  attributes do
    attribute(:key, :string, primary_key?: true, allow_nil?: false, constraints: [trim?: false])
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:content_type, :string, allow_nil?: false, constraints: [trim?: false])
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :put_in_tx do
      transaction?(false)
      accept([:key, :object_id, :content_type])
      upsert?(true)
      upsert_fields([:object_id, :content_type, :updated_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
