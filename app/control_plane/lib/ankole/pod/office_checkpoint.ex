defmodule Ankole.Pod.OfficeCheckpoint do
  @moduledoc """
  Identity bijection sidecar for a compacted Word or Presentation file object.

  Ankole exports pure ECMA-376 `.docx`, `.docm`, and `.pptx` files without
  custom XML parts or proprietary namespace attributes. When compaction writes a
  new Drive object while collaborators still hold in-flight operations against
  earlier session IDs, `checkpoint` records the deterministic ID mapping for
  `object_id`. An external upload or version restore names a different
  `object_id` and purges this row so externally edited files open cleanly.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod,
    tenant_in_primary_key: true

  postgres do
    table("pod_office_checkpoints")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "pod_office_checkpoints_tenant_id_page_id_fkey"}])
    unique_index_names([{[:page_id], "pod_office_checkpoints_pkey"}])
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:checkpoint, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :put do
      accept([:page_id, :object_id, :checkpoint, :updated_at])
      upsert?(true)
      upsert_fields([:object_id, :checkpoint, :updated_at])
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
