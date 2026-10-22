defmodule Ankole.Sessions.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Sessions.SessionWorkspace do
      define(:get_session_workspace, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_session_workspaces, action: :read)
      define(:allocate_session_workspace, action: :allocate)
      define(:advance_epoch_session_workspace, action: :advance_epoch)
    end

    resource Ankole.Sessions.RoundState do
      define(:get_round_state, action: :read, get_by: [:message_id], not_found_error?: false)
      define(:list_round_states, action: :read)
      define(:record_once_round_state, action: :record_once)
    end

    resource Ankole.Sessions.Receipts do
      define(:get_receipts,
        action: :read,
        get_by: [:response_id, :call_id],
        not_found_error?: false
      )

      define(:list_receiptses, action: :read)
      define(:commit_result_receipts, action: :commit_result)
      define(:discard_receipts, action: :discard)
    end

    resource Ankole.Sessions.AmbientJudgment do
      define(:get_ambient_judgment, action: :read, get_by: [:signal_id], not_found_error?: false)
      define(:list_ambient_judgments, action: :read)
      define(:record_ambient_judgment, action: :record)
      define(:degrade_anchor_ambient_judgment, action: :degrade_anchor)
    end
  end
end
