defmodule Ankole.BackgroundActivities do
  @moduledoc "The independently authorized read projections of Agent background activity."
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(Ankole.BackgroundActivities.ConsoleOperations)
  end

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      route(
        Ankole.BackgroundActivities.ConsoleOperations,
        :get,
        "/agents/:agent_uid/background-activities/background-jobs",
        :console_jobs,
        name: "background_activity_jobs"
      )

      route(
        Ankole.BackgroundActivities.ConsoleOperations,
        :get,
        "/agents/:agent_uid/background-activities/workflow",
        :console_workflow,
        name: "background_activity_workflow"
      )

      route(
        Ankole.BackgroundActivities.ConsoleOperations,
        :get,
        "/agents/:agent_uid/background-activities/automation-runs",
        :console_automation_runs,
        name: "background_activity_automation_runs"
      )
    end
  end
end
