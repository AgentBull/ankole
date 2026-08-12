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
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
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
              minimum: 1000,
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
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "automation_jobs", "read") do
      jobs =
        params
        |> ConsoleParams.agent_filter_param()
        |> AutomationJobs.list_jobs(nil, limit: integer_param(params, "limit", 100))
        |> Enum.map(&AutomationJobs.console_projection/1)

      json(conn, %{automation_jobs: jobs})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, resource(agent_uid), "read"),
         {:ok, job_id} <- positive_integer_param(params, "automation_job_id"),
         {:ok, %{automation_job: job, runs: runs}} <-
           AutomationJobs.show_job(agent_uid, nil, job_id,
             runs: integer_param(params, "runs", 20)
           ) do
      json(conn, %{automation_job: AutomationJobs.console_projection(job, runs)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp agent_uid_param(params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid") do
      {:ok, String.downcase(agent_uid)}
    end
  end

  defp text_param(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp positive_integer_param(params, key) do
    case param(params, key) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _invalid -> {:error, {:invalid_positive_integer, key}}
        end

      _value ->
        {:error, {:invalid_positive_integer, key}}
    end
  end

  defp integer_param(params, key, default) do
    case positive_integer_param(params, key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, param_atom(key))

  defp param_atom("agent_uid"), do: :agent_uid
  defp param_atom("automation_job_id"), do: :automation_job_id
  defp param_atom("limit"), do: :limit
  defp param_atom("runs"), do: :runs

  defp resource(agent_uid), do: "agent:#{agent_uid}:automation_jobs"

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, :automation_job_not_found),
    do: error(conn, 404, "not_found", "automation job was not found")

  defp error(conn, {:missing, key}),
    do: error(conn, 422, "validation_failed", "#{key} is required")

  defp error(conn, {:invalid_positive_integer, key}),
    do: error(conn, 422, "validation_failed", "#{key} must be a positive integer")

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
