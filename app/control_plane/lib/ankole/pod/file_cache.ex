defmodule Ankole.Pod.FileCache do
  @moduledoc """
  Structure metadata and extraction status derived from a file page's current object.

  The kernel rebuilds every column from the object's bytes, while extracted
  searchable text lives in `Ankole.Pod.PageSearchDocument.body_text`. `object_id`
  names the object that the row describes, and `extract_status` records whether
  extraction succeeded (`:ok`), was intentionally skipped (`:skipped`), or failed
  on malformed input (`:failed`) so background reconciliation never retries an
  unchanged object at the same `extractor_version`.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod,
    tenant_in_primary_key: true

  postgres do
    table("pod_file_caches")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "pod_file_caches_tenant_id_page_id_fkey"}])
    unique_index_names([{[:page_id], "pod_file_caches_pkey"}])

    check_constraints do
      check_constraint(:subtype, "pod_file_caches_subtype_check")
      check_constraint(:extract_status, "pod_file_caches_extract_status_check")
    end
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)

    attribute(:subtype, :atom,
      allow_nil?: false,
      constraints: [one_of: [:spreadsheet, :text, :document]]
    )

    attribute(:format, :string, allow_nil?: false, default: "xlsx")
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:extractor_version, :integer, allow_nil?: false, default: 1)

    attribute(:extract_status, :atom,
      allow_nil?: false,
      default: :ok,
      constraints: [one_of: [:ok, :skipped, :failed]]
    )

    attribute(:extract_error, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :put do
      accept([
        :page_id,
        :subtype,
        :format,
        :object_id,
        :extractor_version,
        :extract_status,
        :extract_error,
        :metadata,
        :updated_at
      ])

      upsert?(true)

      upsert_fields([
        :subtype,
        :format,
        :object_id,
        :extractor_version,
        :extract_status,
        :extract_error,
        :metadata,
        :updated_at
      ])
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
