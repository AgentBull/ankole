defmodule AnkoleWeb.AutomationJobController do
  @moduledoc """
  Console REST API for automation job and run-history inspection.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
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
  security([%{"consoleSession" => []}])

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
      default: {"Error", "application/json", ErrorEnvelope}
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
              minimum: Ankole.ModelIntegerID.minimum(),
              maximum: Ankole.ModelIntegerID.maximum()
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
      default: {"Error", "application/json", ErrorEnvelope}
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
    end
  end

  defp agent_uid_param(params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid) do
      {:ok, String.downcase(agent_uid)}
    end
  end

  defp resource(agent_uid), do: "agent:#{agent_uid}:automation_jobs"

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :automation_job_not_found),
    do: ConsoleErrors.not_found(conn, "automation job was not found")

  defp error(conn, {:missing, key}),
    do: ConsoleErrors.required_field(conn, key)
end
