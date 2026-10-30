defmodule Ankole.Pod.PageDailyActivity do
  @moduledoc "Daily document activity retained independently of the OT replay window."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod,
    tenant_in_primary_key: true

  postgres do
    table("page_daily_activity")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "page_daily_activity_page_fkey"}])
    unique_index_names([{[:page_id, :day], "page_daily_activity_pkey"}])

    check_constraints do
      check_constraint(:views, "page_daily_activity_counts")
    end
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:day, :date, primary_key?: true, allow_nil?: false)
    attribute(:views, :integer, allow_nil?: false, default: 0)
    attribute(:edits, :integer, allow_nil?: false, default: 0)
    attribute(:comments, :integer, allow_nil?: false, default: 0)
  end

  actions do
    defaults([:read])

    create :put do
      accept([:page_id, :day, :views, :edits, :comments])
      upsert?(true)
      upsert_fields([:views, :edits, :comments])
    end

    destroy :purge do
      require_atomic?(true)
    end
  end
end
