defmodule Ankole.Pod.AppletBinding do
  @moduledoc "A page editor's table and field overrides for one declared Applet slot."
  use Ankole.Ash.Resource, tenancy: :tenant, tenant_in_primary_key: true, domain: Ankole.Pod

  postgres do
    table("pod_applet_bindings")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "pod_applet_bindings_page_fkey"}])
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)

    attribute(:slot_key, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:table_id, Ankole.Ash.Types.UUIDv7)
    attribute(:field_overrides, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:updated_by, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    create_timestamp(:inserted_at, type: Ankole.Ash.Types.Timestamptz)
    update_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz)
  end

  actions do
    defaults([:read])

    create :put_in_tx do
      transaction?(false)
      accept([:page_id, :slot_key, :table_id, :field_overrides, :updated_by])
      upsert?(true)
      upsert_fields([:table_id, :field_overrides, :updated_by, :updated_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end

    destroy :purge do
      transaction?(false)
      require_atomic?(true)
    end
  end
end
