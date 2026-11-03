defmodule Ankole.AutomationJobs.Schemas.State do
  @moduledoc "A Job's durable cursor or application state, shared by its runs."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.AutomationJobs

  postgres do
    table("automation_job_states")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:automation_job_id, :integer, primary_key?: true, allow_nil?: false)

    attribute(:scope_key, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 255, trim?: false]
    )

    attribute(:state_key, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 255, trim?: false]
    )

    attribute(:value, Ankole.Ash.Types.JSONValue)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :put do
      accept([:automation_job_id, :scope_key, :state_key, :value, :updated_at])
      upsert?(true)
      upsert_fields([:value, :updated_at])
    end

    destroy(:remove)
  end
end
