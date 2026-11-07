defmodule Ankole.Pod.PageSearchDocument do
  @moduledoc """
  Unified full-text search projection for one Page (`title`, `meta_text`, and `body_text`).

  Every row mirrors facts already owned by `pages`, `page_contents`, `base_*`, or
  a file page's current object. `page_id` is the primary key so the `pg_search`
  BM25 index keys on a single UUID column while pushing `tenant_id` down inside
  the index scan.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod

  postgres do
    table("page_search_documents")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "page_search_documents_tenant_id_page_id_fkey"}])
    unique_index_names([{[:page_id], "page_search_documents_pkey"}])
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:title, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:meta_text, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:body_text, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :put do
      accept([:page_id, :title, :meta_text, :body_text, :updated_at])
      upsert?(true)
      upsert_fields([:title, :meta_text, :body_text, :updated_at])

      change(fn changeset, _context ->
        Enum.reduce([:title, :meta_text, :body_text], changeset, fn attr, acc ->
          case Ash.Changeset.fetch_change(acc, attr) do
            {:ok, value} when is_binary(value) ->
              Ash.Changeset.force_change_attribute(
                acc,
                attr,
                Ankole.Pod.SearchProjection.sanitize(value)
              )

            _ ->
              acc
          end
        end)
      end)
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
