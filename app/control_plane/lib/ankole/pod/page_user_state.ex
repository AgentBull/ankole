defmodule Ankole.Pod.PageUserState do
  @moduledoc "One person's favorites, visits, and acknowledged comment activity for one page."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod,
    tenant_in_primary_key: true,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("pod_page_user_state")
    derive_filter?(false)
    derive_sort?(false)

    primary_key do
      keys([:principal_uid, :page_id])
    end
  end

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

    attribute(:page_id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:favorited_at, :utc_datetime_usec, public?: true)
    attribute(:visited_at, :utc_datetime_usec, public?: true)
    attribute(:hide_visits, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:edited_at, :utc_datetime_usec)
    attribute(:comments_read_at, :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    read :viewers do
      pagination(keyset?: true, max_page_size: 100, countable: false, required?: false)
    end

    create :put do
      accept([
        :principal_uid,
        :page_id,
        :favorited_at,
        :visited_at,
        :comments_read_at,
        :hide_visits,
        :edited_at
      ])

      upsert?(true)
      upsert_fields([:favorited_at, :visited_at, :comments_read_at, :hide_visits, :edited_at])
    end

    destroy :remove_empty do
      require_atomic?(true)

      change(
        filter(
          expr(
            is_nil(favorited_at) and is_nil(visited_at) and is_nil(comments_read_at) and
              is_nil(edited_at) and not hide_visits
          )
        )
      )
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
