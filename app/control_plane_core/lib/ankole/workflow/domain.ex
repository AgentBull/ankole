defmodule Ankole.Workflow.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Workflow.Schemas.Run do
      define(:get_run, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_runs, action: :read)
      define(:reauthorize_run, action: :reauthorize)
      define(:create_run, action: :create_run)
      define(:update_metadata_run, action: :update_metadata)
    end

    resource Ankole.Workflow.Schemas.AgentCall do
      define(:get_agent_call, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_calls, action: :read)
      define(:create_call_agent_call, action: :create_call)
      define(:update_metadata_agent_call, action: :update_metadata)
    end
  end
end
