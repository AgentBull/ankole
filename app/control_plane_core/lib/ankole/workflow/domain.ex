defmodule Ankole.Workflow.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.Workflow.Schemas.Run)
    resource(Ankole.Workflow.Schemas.AgentCall)
  end
end
