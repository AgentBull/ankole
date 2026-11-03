defmodule Ankole.Pod.Bases.ChangeOutbox do
  @moduledoc "Committed inline Base batches awaiting Signal delivery."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

  postgres do
    table("base_change_outbox")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:table_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:data_version, :integer, allow_nil?: false)
    attribute(:actor_ref, :string, allow_nil?: false)
    attribute(:changes, Ankole.Ash.Types.JSONValue, allow_nil?: false)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :append do
      accept([:id, :page_id, :table_id, :data_version, :actor_ref, :changes])
    end

    destroy(:acknowledge)
  end
end
