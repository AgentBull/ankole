defmodule Ankole.Signals.BindingReceipt do
  @moduledoc "Seven-day event deduplication and the delivered Run or Session Signal reference."
  use Ankole.Ash.Resource, tenancy: :tenant, tenant_in_primary_key: true, domain: Ankole.Signals

  postgres do
    table("signal_binding_receipts")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:binding_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:source, :string, primary_key?: true, allow_nil?: false)
    attribute(:source_event_id, :string, primary_key?: true, allow_nil?: false)
    attribute(:signal_id, :string, allow_nil?: false)
    attribute(:automation_job_run_id, :integer)
    attribute(:delivered_signal_id, :string)
    create_timestamp(:received_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create_if_absent :receive_event do
      accept([:binding_id, :source, :source_event_id, :signal_id])
    end

    update :deliver do
      accept([:automation_job_run_id, :delivered_signal_id])
    end

    destroy(:expire)
  end
end
