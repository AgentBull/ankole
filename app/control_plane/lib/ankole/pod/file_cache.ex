defmodule Ankole.Pod.FileCache do
  @moduledoc """
  Search text and structure metadata derived from a file page's current object.

  The kernel rebuilds every column from the object's bytes, so the row is a
  cache: it never holds a fact that the file does not. `object_id` names the
  object that the row describes.
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
    end
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:subtype, :atom, allow_nil?: false, constraints: [one_of: [:spreadsheet]])
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)

    attribute(:plain_text, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:metadata, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :put do
      accept([:page_id, :subtype, :object_id, :plain_text, :metadata, :updated_at])
      upsert?(true)
      upsert_fields([:subtype, :object_id, :plain_text, :metadata, :updated_at])
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
