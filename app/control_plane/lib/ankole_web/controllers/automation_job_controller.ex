defmodule AnkoleWeb.AutomationJobController do
  @moduledoc """
  Console REST API for automation job and run-history inspection.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.AutomationJobs
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AutomationJobListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AutomationJobResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @agent_parameters [agent_uid: [in: :path, type: :string, required: true]]

  tags(["Automation Jobs"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List automation jobs",
    parameters: [
      agent: [in: :query, type: :string, required: false],
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 500},
        required: false
      ]
    ],
    responses: [
      ok: {"Automation jobs", "application/json", AutomationJobListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one automation job and its recent run history",
    parameters:
      @agent_parameters ++
        [
          automation_job_id: [
            in: :path,
            schema: %Schema{
              type: :integer,
              minimum: 1,
              maximum: 9_007_199_254_740_991
            },
            required: true
          ],
          runs: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 100},
            required: false
          ]
        ],
    responses: [
      ok: {"Automation job", "application/json", AutomationJobResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid job identifier", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "automation_jobs", "read") do
      jobs =
        params
        |> ConsoleParams.agent_filter_param()
        |> AutomationJobs.list_jobs(nil, limit: ConsoleParams.integer(params, :limit, 100))
        |> Enum.map(&AutomationJobs.console_projection/1)

      json(conn, %{automation_jobs: jobs})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, %{automation_job_id: job_id} = params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, resource(agent_uid), "read"),
         {:ok, %{automation_job: job, runs: runs}} <-
           AutomationJobs.show_job(agent_uid, nil, job_id,
             runs: ConsoleParams.integer(params, :runs, 20)
           ) do
      json(conn, %{automation_job: AutomationJobs.console_projection(job, runs)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp agent_uid_param(params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid) do
      {:ok, String.downcase(agent_uid)}
    end
  end

  defp resource(agent_uid), do: "agent:#{agent_uid}:automation_jobs"

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, :automation_job_not_found),
    do: error(conn, 404, "not_found", "automation job was not found")

  defp error(conn, {:missing, key}),
    do: error(conn, 422, "validation_failed", "#{key} is required")

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
