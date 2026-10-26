defmodule Ankole.Sessions.Receipt do
  @moduledoc """
  The committed result of one control-plane tool call.

  `Ankole.Sessions.Receipts` writes it with its domain write.
  """

  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Sessions

  @identity_constraint "session_tool_receipts_pkey"

  postgres do
    table("session_tool_receipts")
    repo(Ankole.Repo)
    migrate?(false)
    unique_index_names([{[:response_id, :call_id], @identity_constraint}])
    foreign_key_names([{:agent_uid, "session_tool_receipts_agent_uid_fkey"}])

    check_constraints do
      check_constraint(:result, "session_tool_receipts_result_object")
    end
  end

  attributes do
    attribute(:response_id, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:call_id, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:session_id, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:result, Ankole.Ash.Types.JSONMap, allow_nil?: false)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :commit_result do
      primary?(true)
      accept([:response_id, :call_id, :agent_uid, :session_id, :result])
    end

    destroy :discard do
      require_atomic?(true)
    end
  end
end
