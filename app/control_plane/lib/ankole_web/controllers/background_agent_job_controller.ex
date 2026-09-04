defmodule AnkoleWeb.BackgroundAgentJobController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Installation-wide console API for observing and cancelling background Agent Jobs.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobHealthResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobResponse
  alias OpenAPISpex.Schema

  @statuses Job.statuses()

  tags(["Background Agent Jobs"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List background Agent Jobs",
    parameters: [
      status: [in: :query, schema: %Schema{type: :string, enum: @statuses}, required: false],
      agent: [in: :query, type: :string, required: false],
      q: [
        in: :query,
        schema: %Schema{type: :string, maxLength: 200},
        required: false,
        description: "Matches an exact Job ID or a case-insensitive title fragment."
      ],
      cursor: [in: :query, type: :string, required: false],
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 100},
        required: false
      ]
    ],
    responses: [
      ok: {"Background Agent Jobs", "application/json", BackgroundAgentJobListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  operation(:health,
    summary: "Read installation-wide background Agent Job reliability metrics",
    responses: [
      ok: {"Background Agent Job health", "application/json", BackgroundAgentJobHealthResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one background Agent Job and one page of its runtime Turn trajectory",
    parameters: [
      job_id: [
        in: :path,
        schema: %Schema{type: :integer, minimum: 1000, maximum: 9_007_199_254_740_991},
        required: true
      ],
      cursor: [
        in: :query,
        type: :string,
        required: false,
        description:
          "The `turns_next_cursor` of the preceding page; omit it for the newest Turns."
      ]
    ],
    responses: [
      ok: {"Background Agent Job", "application/json", BackgroundAgentJobResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid cursor", "application/json", ErrorEnvelope}
    ]
  )

  operation(:complete,
    summary: "Commit an externally verified completion for one background Agent Job",
    parameters: [
      job_id: [
        in: :path,
        schema: %Schema{type: :integer, minimum: 1000, maximum: 9_007_199_254_740_991},
        required: true
      ]
    ],
    request_body:
      {"Completion result", "application/json",
       %Schema{
         type: :object,
         properties: %{
           result_summary: %Schema{type: :string, minLength: 1, maxLength: 16_384}
         },
         required: [:result_summary]
       }},
    responses: [
      ok: {"Background Agent Job", "application/json", BackgroundAgentJobResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Job already failed or stopped", "application/json", ErrorEnvelope}
    ]
  )

  operation(:cancel,
    summary: "Cancel one queued or active background Agent Job",
    parameters: [
      job_id: [
        in: :path,
        schema: %Schema{type: :integer, minimum: 1000, maximum: 9_007_199_254_740_991},
        required: true
      ]
    ],
    responses: [
      ok: {"Background Agent Job", "application/json", BackgroundAgentJobResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "read"),
         {:ok, page} <-
           BackgroundAgentJobs.list_for_console(
             status: params[:status],
             agent_uid: ConsoleParams.agent_filter_param(params),
             search: params[:q],
             cursor: params[:cursor],
             limit: ConsoleParams.integer(params, :limit, 50)
           ) do
      json(conn, %{
        jobs: Enum.map(page.jobs, &BackgroundAgentJobs.console_list_projection/1),
        next_cursor: page.next_cursor
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def health(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "read") do
      json(conn, BackgroundAgentJobs.health_metrics())
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "read"),
         %Job{} = job <- job(params),
         {:ok, detail} <- detail_projection(job, params[:cursor]) do
      json(conn, %{job: detail})
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  # `CastAndValidate` leaves the validated request body in `conn.body_params` and
  # keeps only path and query parameters in the action params, so the summary is
  # read from the body like every other console write.
  def complete(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "update"),
         %Job{} = job <- job(params),
         {:ok, %{job: completed}} <-
           BackgroundAgentJobs.request_complete(job.id, %{
             "agent_uid" => job.agent_uid,
             "completed_by" => "operator:#{conn.assigns.current_principal_uid}",
             "result_summary" => conn.body_params.result_summary
           }),
         {:ok, detail} <- detail_projection(completed, nil) do
      json(conn, %{job: detail})
    else
      nil -> error(conn, :not_found)
      {:error, :background_agent_job_terminal} -> error(conn, :conflict)
      {:error, reason} -> error(conn, reason)
    end
  end

  def cancel(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "background_agent_jobs", "delete"),
         %Job{} = job <- job(params),
         {:ok, %{job: cancelled}} <-
           BackgroundAgentJobs.request_stop(job.id, %{
             "agent_uid" => job.agent_uid,
             "cancel_requested_by" => "operator:#{conn.assigns.current_principal_uid}",
             "reason" => "Cancelled from the operator console"
           }),
         {:ok, detail} <- detail_projection(cancelled, nil) do
      json(conn, %{job: detail})
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp job(%{job_id: job_id}), do: BackgroundAgentJobs.get_job(job_id)

  defp detail_projection(job, cursor) do
    with {:ok, page} <- BackgroundAgentJobs.console_turn_page(job, cursor) do
      {:ok,
       job
       |> BackgroundAgentJobs.console_projection()
       |> Map.merge(%{turns: page.turns, turns_next_cursor: page.next_cursor})}
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found),
    do: error(conn, 404, "not_found", "background Agent Job was not found")

  defp error(conn, :conflict),
    do:
      error(
        conn,
        409,
        "background_agent_job_terminal",
        "background Agent Job already failed or stopped"
      )

  defp error(conn, reason) do
    error(
      conn,
      422,
      "invalid_background_agent_job_request",
      "background Agent Job request is invalid",
      [
        %{reason: inspect(reason)}
      ]
    )
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
