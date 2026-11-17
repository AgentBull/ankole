defmodule Ankole.Connectors.WriteReceipt do
  @moduledoc "Durable same-turn receipt guarding non-idempotent connector writes across disconnects."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Connectors

  postgres do
    table("connector_write_receipts")
    repo(Ankole.Repo)
    migrate?(false)

    unique_index_names([
      {[:tenant_id, :authority_scope, :toolkit, :tool_name, :args_sha256],
       "connector_write_receipts_scope_call_uidx"}
    ])

    check_constraints do
      check_constraint(:status, "connector_write_receipts_status_check")
      check_constraint(:authority_scope, "connector_write_receipts_scope_present")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Kernel.gen_uuid_v7/0
    )

    attribute(:authority_scope, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:toolkit, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:tool_name, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:args_sha256, :string, allow_nil?: false)
    attribute(:status, :string, allow_nil?: false, default: "in_flight")
    attribute(:http_status, :integer)
    attribute(:external_ref, :string)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false)
    timestamps(type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :claim_in_tx do
      transaction?(false)

      accept([
        :authority_scope,
        :toolkit,
        :tool_name,
        :args_sha256,
        :status,
        :expires_at
      ])
    end

    update :settle_in_tx do
      transaction?(false)
      accept([:status, :http_status, :external_ref, :expires_at])
    end

    destroy :release_in_tx do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
