defmodule Ankole.Pod.AppletIdempotencyKey do
  @moduledoc "Durable in-flight mutex and response cache for Applet HTTP and SDK idempotency keys."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod

  postgres do
    table("pod_applet_idempotency_keys")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "pod_applet_idempotency_keys_page_fkey"}])

    unique_index_names([
      {[:page_id, :scope_uid, :idempotency_key], "pod_applet_idempotency_keys_pkey"}
    ])

    check_constraints do
      check_constraint(:idempotency_key, "pod_applet_idempotency_keys_key_present")
    end
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:scope_uid, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false]
    )

    attribute(:idempotency_key, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, min_length: 1, max_length: 255]
    )

    attribute(:request_hash, :string, allow_nil?: false, public?: true)
    attribute(:status_code, :integer, allow_nil?: false, public?: true)

    attribute(:response_body, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      public?: true
    )

    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :claim_in_tx do
      transaction?(false)

      accept([
        :page_id,
        :scope_uid,
        :idempotency_key,
        :request_hash,
        :status_code,
        :response_body,
        :expires_at
      ])
    end

    update :complete_in_tx do
      transaction?(false)
      require_atomic?(false)
      accept([:status_code, :response_body, :expires_at])
    end

    destroy :release_in_tx do
      transaction?(false)
      require_atomic?(true)
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
