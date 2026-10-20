defmodule AnkoleWeb.BackgroundActivityController do
  @moduledoc "Three independently authorized read projections of an Agent's background activity."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias OpenApiSpex.Schema
  alias AnkoleWeb.{ConsoleErrors, ConsoleParams, ConsolePolicy}
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  alias AnkoleWeb.Schemas.BackgroundActivities.{
    BackgroundActivityJobsResponse,
    BackgroundActivityWorkflowResponse,
    BackgroundActivityAutomationRunsResponse
  }

  @parameters [
    agent_uid: [in: :path, type: :string, required: true],
    limit: [
      in: :query,
      schema: %Schema{type: :integer, minimum: 1, maximum: 100},
      required: false
    ]
  ]
  tags(["Background Activities"])
  security([%{"consoleSession" => []}])
  plug(OpenApiSpex.Plug.CastAndValidate, render_error: AnkoleWeb.OpenAPIValidationErrorRenderer)

  operation(:jobs,
    operation_id: "backgroundActivityJobs",
    summary: "Read this Agent's queued, running and waiting background Jobs",
    parameters: @parameters ++ [cursor: [in: :query, type: :string, required: false]],
    responses: [
      ok: {"Background Jobs", "application/json", BackgroundActivityJobsResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:automation_runs,
    operation_id: "backgroundActivityAutomationRuns",
    summary: "Read live automation runs, including runs of cancelled definitions",
    parameters: @parameters ++ [cursor: [in: :query, type: :string, required: false]],
    responses: [
      ok: {"Automation runs", "application/json", BackgroundActivityAutomationRunsResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:workflow,
    operation_id: "backgroundActivityWorkflow",
    summary: "Read live Workflow calls and runs awaiting execution or terminal cleanup",
    parameters:
      @parameters ++
        [
          calls_cursor: [in: :query, type: :string, required: false],
          runs_cursor: [in: :query, type: :string, required: false]
        ],
    responses: [
      ok: {"Workflow activity", "application/json", BackgroundActivityWorkflowResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def jobs(conn, params) do
    observed_at = DateTime.utc_now(:microsecond)

    with {:ok, agent} <- agent(params),
         :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "read"),
         {:ok, page} <-
           Ankole.BackgroundAgentJobs.Queries.list_activity(agent,
             cursor: params[:cursor],
             limit: limit(params)
           ) do
      json(conn, activity_page(page, observed_at, [:jobs]))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def automation_runs(conn, params) do
    observed_at = DateTime.utc_now(:microsecond)

    with {:ok, agent} <- agent(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent}:automation_jobs", "read"),
         {:ok, cursor} <- cursor(params[:cursor]) do
      page = Ankole.AutomationJobs.ConsoleQueries.activity(agent, cursor, limit(params))
      json(conn, activity_page(page, observed_at, [:runs]))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def workflow(conn, params) do
    observed_at = DateTime.utc_now(:microsecond)

    with {:ok, agent} <- agent(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent}:workflow", "read"),
         {:ok, calls_cursor} <- cursor(params[:calls_cursor]),
         {:ok, runs_cursor} <- cursor(params[:runs_cursor]) do
      page =
        Ankole.Workflow.ConsoleQueries.activity(agent, calls_cursor, runs_cursor, limit(params))

      json(conn, activity_page(page, observed_at, [:live_calls, :runs]))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp agent(params) do
    with {:ok, uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, uid} <- Ankole.Principals.normalize_uid(uid),
         do: {:ok, uid}
  end

  defp activity_page(page, observed_at, groups) do
    Enum.reduce(groups, Map.put(page, :observed_at, DateTime.to_iso8601(observed_at)), fn group,
                                                                                          page ->
      Map.update!(page, group, fn rows ->
        Enum.map(rows, fn row ->
          Map.new(row, fn
            {key, %DateTime{} = value} -> {key, DateTime.to_iso8601(value)}
            field -> field
          end)
        end)
      end)
    end)
  end

  defp limit(params), do: ConsoleParams.integer(params, :limit, 25)
  defp cursor(value) when value in [nil, ""], do: {:ok, nil}

  defp cursor(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_007_199_254_740_991 -> {:ok, id}
      _ -> {:error, :invalid_activity_cursor}
    end
  end

  defp cursor(_), do: {:error, :invalid_activity_cursor}
  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "access denied")

  defp error(conn, _reason),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "invalid Agent or activity cursor")
end
