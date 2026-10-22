defmodule Ankole.AutomationJobs.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(Ankole.AutomationJobs.Schemas.Job)
    resource(Ankole.AutomationJobs.Schemas.Run)
  end
end
