defmodule Ankole.Pod.SearchQuery do
  @moduledoc """
  One person's recent search query in a Pod, bounded to the newest 20 queries per principal.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod,
    tenant_in_primary_key: true

  postgres do
    table("pod_search_queries")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:id], "pod_search_queries_pkey"},
      {[:principal_uid, :query], "pod_search_queries_principal_query_key"}
    ])

    identity_index_names(principal_query: "pod_search_queries_principal_query_key")

    check_constraints do
      check_constraint(:result_count, "pod_search_queries_result_count_check")
    end
  end

  identities do
    identity(:principal_query, [:principal_uid, :query])
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:query, :string, allow_nil?: false, constraints: [trim?: false])

    attribute(:result_count, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0]
    )

    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :put do
      accept([:id, :principal_uid, :query, :result_count, :updated_at])
      upsert?(true)
      upsert_identity(:principal_query)
      upsert_fields([:result_count, :updated_at])
    end

    update :replace do
      transaction?(false)
      accept([:query, :result_count, :updated_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
