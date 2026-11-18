defmodule Ankole.Pod.AgentUIRequest do
  @moduledoc """
  One operation that an Agent asks a Human's open Pod tab to run on the page's
  ui-sdk components, and the answer that tab returns.
  """

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod

  postgres do
    table("pod_agent_ui_requests")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:agent_uid, "pod_agent_ui_requests_agent_fkey"},
      {:principal_uid, "pod_agent_ui_requests_principal_fkey"}
    ])

    check_constraints do
      check_constraint(:operation, "pod_agent_ui_requests_operation_check")
      check_constraint(:status, "pod_agent_ui_requests_status_check")
      check_constraint(:error, "pod_agent_ui_requests_error_check")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    # The Human whose open Pod tab runs the operation.
    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)

    attribute(:operation, :atom,
      allow_nil?: false,
      constraints: [one_of: [:snapshot, :act, :query]]
    )

    attribute(:arguments, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})

    attribute(:status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :claimed, :done, :failed, :expired]]
    )

    attribute(:result, Ankole.Ash.Types.JSONValue)
    attribute(:error, :string, constraints: [trim?: false])
    create_timestamp(:inserted_at)
    attribute(:claimed_at, :utc_datetime_usec)
    attribute(:completed_at, :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :open_in_tx do
      transaction?(false)
      accept([:agent_uid, :principal_uid, :operation, :arguments])
    end

    # A tab claims a pending request before it runs it, so only one tab runs it.
    update :claim do
      transaction?(false)
      require_atomic?(true)
      accept([])
      change(filter(expr(status == :pending)))
      change(set_attribute(:status, :claimed))
      change(set_attribute(:claimed_at, &DateTime.utc_now/0))
    end

    update :finish do
      transaction?(false)
      require_atomic?(true)
      accept([:status, :result, :error])
      change(filter(expr(status == :claimed)))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end

    update :expire do
      transaction?(false)
      require_atomic?(true)
      accept([])
      change(filter(expr(status in [:pending, :claimed])))
      change(set_attribute(:status, :expired))
      change(set_attribute(:completed_at, &DateTime.utc_now/0))
    end
  end

  @type t :: %__MODULE__{}
end
