defmodule AnkoleWeb.BackgroundAgentJobController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console read models of background Agent Jobs: the reliability metrics and
  one page of the runtime Turn trajectory of a Job.

  The Job records, their list, and the cancel and complete operations are in
  the v2 API (`Ankole.BackgroundAgentJobs`).
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobHealthResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnPageResponse
  alias OpenAPISpex.Schema

  tags(["Background Agent Jobs"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:health,
    summary: "Read installation-wide background Agent Job reliability metrics",
    responses: [
      ok: {"Background Agent Job health", "application/json", BackgroundAgentJobHealthResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  operation(:turns,
    summary: "Read one page of the runtime Turn trajectory of one background Agent Job",
    parameters: [
      job_id: [
        in: :path,
        schema: %Schema{
          type: :integer,
          minimum: Ankole.ModelIntegerID.minimum(),
          maximum: Ankole.ModelIntegerID.maximum()
        },
        required: true
      ],
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description: "The `next_cursor` of the preceding page; omit it for the newest Turns."
      ]
    ],
    responses: [
      ok: {"Turn page", "application/json", BackgroundAgentJobTurnPageResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def health(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "read") do
      json(conn, BackgroundAgentJobs.health_metrics())
    end
  end

  def turns(conn, %{job_id: job_id} = params) do
    with :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "read"),
         %Job{} = job <- BackgroundAgentJobs.get_job(job_id),
         {:ok, page} <- BackgroundAgentJobs.console_turn_page(job, params[:cursor]) do
      json(conn, %{turns: page.turns, next_cursor: page.next_cursor})
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fallback(conn, failure),
    do:
      ConsoleErrors.fallback(conn, failure, &error/2,
        validation:
          {"invalid_background_agent_job_request", "background Agent Job request is invalid"}
      )

  defp error(conn, :not_found),
    do: ConsoleErrors.not_found(conn, "background Agent Job was not found")

  defp error(conn, reason) do
    ConsoleErrors.unexpected(
      conn,
      "background_agent_jobs.api.unexpected_error",
      reason,
      "invalid_background_agent_job_request",
      "background Agent Job request is invalid"
    )
  end
end
