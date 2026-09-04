defmodule AnkoleWeb.ScheduleController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for Agent schedules.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronScheduleListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronScheduleResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleEventListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleEventResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleRunListResponse

  @agent_parameters [agent_uid: [in: :path, type: :string, required: true]]
  @agent_filter_parameters [agent: [in: :query, type: :string, required: false]]

  tags(["Schedule"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index_cron,
    summary: "List recurring schedules",
    parameters: @agent_filter_parameters,
    responses: [
      ok: {"Cron schedules", "application/json", ScheduleCronScheduleListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create_cron,
    summary: "Create one recurring schedule",
    parameters: @agent_parameters,
    request_body: {"Cron schedule", "application/json", ScheduleCronWriteRequest, required: true},
    responses: [
      ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid schedule", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show_cron,
    summary: "Read one recurring schedule",
    parameters:
      @agent_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update_cron,
    summary: "Update one recurring schedule",
    parameters:
      @agent_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Cron schedule update", "application/json", ScheduleCronUpdateRequest, required: true},
    responses: [
      ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid schedule", "application/json", ErrorEnvelope}
    ]
  )

  operation(:pause_cron,
    summary: "Pause one recurring schedule",
    parameters:
      @agent_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse}]
  )

  operation(:resume_cron,
    summary: "Resume one recurring schedule",
    parameters:
      @agent_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse}]
  )

  operation(:remove_cron,
    summary: "Remove one recurring schedule",
    parameters:
      @agent_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse}]
  )

  operation(:run_cron,
    summary: "Manually run one recurring schedule",
    parameters:
      @agent_parameters ++
        [
          cron_schedule_id: [in: :path, type: :string, required: true],
          idempotency_key: [
            in: :header,
            name: :"Idempotency-Key",
            type: :string,
            required: true
          ]
        ],
    responses: [ok: {"Scheduled event", "application/json", ScheduleEventResponse}]
  )

  operation(:cron_runs,
    summary: "List recent concrete fires for one recurring schedule",
    parameters:
      @agent_parameters ++
        [
          cron_schedule_id: [in: :path, type: :string, required: true],
          limit: [in: :query, type: :integer, required: false]
        ],
    responses: [ok: {"Schedule runs", "application/json", ScheduleRunListResponse}]
  )

  operation(:index_checkbacks,
    summary: "List checkback wakeups",
    parameters:
      @agent_filter_parameters ++
        [
          limit: [
            in: :query,
            schema: %OpenAPISpex.Schema{type: :integer, minimum: 1, maximum: 500},
            required: false
          ]
        ],
    responses: [
      ok: {"Scheduled events", "application/json", ScheduleEventListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:cancel_checkback,
    summary: "Cancel one pending checkback wakeup",
    parameters:
      @agent_parameters ++
        [
          scheduled_event_id: [
            in: :path,
            schema: %OpenAPISpex.Schema{
              type: :integer,
              minimum: 1000,
              maximum: 9_007_199_254_740_991
            },
            required: true
          ]
        ],
    responses: [ok: {"Scheduled event", "application/json", ScheduleEventResponse}]
  )

  def index_cron(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "schedules", "read") do
      schedules =
        params
        |> ConsoleParams.agent_filter_param()
        |> Schedule.list_cron_schedules()
        |> Enum.map(&Schedule.cron_projection/1)

      json(conn, %{cron_schedules: schedules})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create_cron(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(agent_uid), "update"),
         attrs <- cron_create_attrs(conn, agent_uid),
         created_by <- cron_created_by(conn),
         {:ok, %{cron_schedule: schedule}} <-
           Schedule.create_cron_schedule(attrs, created_by: created_by) do
      json(conn, %{cron_schedule: Schedule.cron_projection(schedule)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show_cron(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(agent_uid), "read"),
         {:ok, schedule} <- cron_for_agent(params, agent_uid) do
      json(conn, %{cron_schedule: Schedule.cron_projection(schedule)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update_cron(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(agent_uid), "update"),
         {:ok, schedule} <- cron_for_agent(params, agent_uid),
         {:ok, updated} <-
           Schedule.update_cron_schedule(
             schedule.id,
             Ankole.Attrs.normalize_external_attrs(conn.body_params)
           ) do
      json(conn, %{cron_schedule: Schedule.cron_projection(updated)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def pause_cron(conn, params),
    do: mutate_cron(conn, params, "update", &Schedule.pause_cron_schedule/1)

  def resume_cron(conn, params),
    do: mutate_cron(conn, params, "update", &Schedule.resume_cron_schedule/1)

  def remove_cron(conn, params),
    do: mutate_cron(conn, params, "delete", &Schedule.remove_cron_schedule/1)

  def run_cron(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(agent_uid), "update"),
         {:ok, schedule} <- cron_for_agent(params, agent_uid),
         {:ok, request_id} <- request_idempotency_key(conn),
         {:ok, %{scheduled_event: event}} <-
           Schedule.run_cron_schedule(schedule.id, idempotency_key: request_id) do
      json(conn, %{schedule_event: Schedule.event_projection(event)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def cron_runs(conn, params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(agent_uid), "read"),
         {:ok, schedule} <- cron_for_agent(params, agent_uid) do
      runs =
        schedule.id
        |> Schedule.list_cron_runs(list_limit(params))
        |> Enum.map(&Schedule.event_projection/1)

      json(conn, %{schedule_runs: runs})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index_checkbacks(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "schedules", "read") do
      events =
        params
        |> ConsoleParams.agent_filter_param()
        |> Schedule.list_checkbacks(nil, limit: ConsoleParams.integer(params, :limit, nil))
        |> Enum.map(&Schedule.event_projection/1)

      json(conn, %{schedule_events: events})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def cancel_checkback(conn, %{scheduled_event_id: scheduled_event_id} = params) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(agent_uid), "delete"),
         {:ok, event} <- Schedule.get_scheduled_event(scheduled_event_id),
         :ok <- event_belongs_to_agent(event, agent_uid),
         {:ok, cancelled} <- Schedule.cancel_checkback(scheduled_event_id) do
      json(conn, %{schedule_event: Schedule.event_projection(cancelled)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp mutate_cron(conn, params, action, fun) do
    with {:ok, agent_uid} <- agent_uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(agent_uid), action),
         {:ok, schedule} <- cron_for_agent(params, agent_uid),
         {:ok, updated} <- fun.(schedule.id) do
      json(conn, %{cron_schedule: Schedule.cron_projection(updated)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp cron_create_attrs(conn, agent_uid) do
    conn.body_params
    |> Ankole.Attrs.normalize_external_attrs()
    |> Map.put("agent_uid", agent_uid)
  end

  defp cron_created_by(conn) do
    %{
      "kind" => "operator_api",
      "principal_uid" => conn.assigns[:current_principal_uid]
    }
  end

  defp cron_for_agent(params, agent_uid) do
    with {:ok, cron_schedule_id} <- ConsoleParams.text(params, :cron_schedule_id),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- belongs_to_agent(schedule.agent_uid, agent_uid) do
      {:ok, schedule}
    end
  end

  defp event_belongs_to_agent(%ScheduledEvent{} = event, agent_uid),
    do: belongs_to_agent(event.agent_uid, agent_uid)

  defp belongs_to_agent(owner_uid, agent_uid) do
    case owner_uid == agent_uid do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  defp agent_uid_param(params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid) do
      {:ok, String.downcase(agent_uid)}
    end
  end

  defp schedule_resource(agent_uid), do: "agent:#{agent_uid}:schedules"

  defp list_limit(params) do
    case ConsoleParams.integer(params, :limit, nil) do
      value when is_integer(value) and value > 0 -> min(value, 100)
      _value -> 25
    end
  end

  defp request_idempotency_key(conn) do
    case get_req_header(conn, "idempotency-key") do
      [value] when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, "Idempotency-Key"}}
          request_id -> {:ok, request_id}
        end

      _values ->
        {:error, {:missing, "Idempotency-Key"}}
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "schedule was not found")

  defp error(conn, :cron_schedule_not_found),
    do: error(conn, 404, "not_found", "schedule was not found")

  defp error(conn, :scheduled_event_not_found),
    do: error(conn, 404, "not_found", "event was not found")

  defp error(conn, {:missing, key}) do
    error(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, :cron_task_required) do
    error(
      conn,
      422,
      "validation_failed",
      "payload.task must carry the self-contained recurring instruction for a direct-Agent schedule"
    )
  end

  defp error(conn, :cron_owner_session_reserved) do
    error(
      conn,
      422,
      "validation_failed",
      "owner_session_id cannot be a derived cron execution session"
    )
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    error(
      conn,
      422,
      "validation_failed",
      "request validation failed",
      ConsoleErrors.changeset_details(changeset)
    )
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_schedule", "schedule request is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
