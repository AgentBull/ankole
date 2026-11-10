defmodule Ankole.Pod.AppletApproval do
  @moduledoc "One durable review request and its assigned Human's decision."

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod

  postgres do
    table("pod_applet_approvals")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:page_id, "pod_applet_approvals_page_fkey"},
      {:reviewer_uid, "pod_applet_approvals_reviewer_fkey"}
    ])

    identity_index_names(request: "pod_applet_approvals_request_index")

    check_constraints do
      check_constraint(:request_key, "pod_applet_approvals_request_key_check")
      check_constraint(:summary, "pod_applet_approvals_summary_check")
      check_constraint(:details, "pod_applet_approvals_details_check")
      check_constraint(:note, "pod_applet_approvals_note_check")
      check_constraint(:status, "pod_applet_approvals_resolution_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:request_key, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:requester_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:reviewer_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:summary, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:details, :string, constraints: [trim?: false])

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :approved, :rejected]]
    )

    attribute(:decided_at, :utc_datetime_usec)
    attribute(:note, :string, constraints: [trim?: false])
    create_timestamp(:inserted_at)
  end

  identities do
    identity(:request, [:page_id, :request_key])
  end

  actions do
    defaults([:read])

    create :request_in_tx do
      transaction?(false)
      accept([:page_id, :request_key, :requester_uid, :reviewer_uid, :summary, :details])
      upsert?(true)
      upsert_identity(:request)
      upsert_fields([])
    end

    update :decide_in_tx do
      transaction?(false)
      require_atomic?(false)
      accept([:status, :decided_at, :note])
    end
  end
end
