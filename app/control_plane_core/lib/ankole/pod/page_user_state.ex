defmodule Ankole.Pod.PageUserState do
  @moduledoc "One person's favorite and visit times for one page."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod.Domain,
    tenant_in_primary_key: true

  postgres do
    table("page_user_states")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "page_user_states_tenant_id_page_id_fkey"}])
    unique_index_names([{[:principal_uid, :page_id], "page_user_states_pkey"}])
  end

  attributes do
    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:favorited_at, :utc_datetime_usec)
    attribute(:visited_at, :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :put do
      transaction?(false)
      accept([:principal_uid, :page_id, :favorited_at, :visited_at])
      upsert?(true)
      upsert_fields([:favorited_at, :visited_at])
    end

    destroy :remove_empty do
      transaction?(false)
      require_atomic?(true)
      change(filter(expr(is_nil(favorited_at) and is_nil(visited_at))))
    end

    destroy :purge do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
