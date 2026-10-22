defmodule Ankole.BackgroundAgentJobs.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.BackgroundAgentJobs.Schemas.Job)
    resource(Ankole.BackgroundAgentJobs.Schemas.Turn)
    resource(Ankole.BackgroundAgentJobs.Schemas.TurnItem)
  end
end
