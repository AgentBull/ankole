defmodule AnkoleWeb.ScheduleController do
  @moduledoc """
  Console REST API for actor schedules.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleApi.ScheduleCronScheduleListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.ScheduleCronScheduleResponse
  alias AnkoleWeb.Schemas.ConsoleApi.ScheduleCronUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ScheduleCronWriteRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ScheduleEventListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.ScheduleEventResponse

  @actor_parameters [
    agent_uid: [in: :path, type: :string, required: true],
    session_id: [in: :path, type: :string, required: true]
  ]

  tags(["Schedule"])
  security([%{"consoleBearer" => []}])

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenApiValidationErrorRenderer

  operation(:index_cron,
    summary: "List recurring schedules for one agent session",
    parameters: @actor_parameters,
    responses: [
      ok: {"Cron schedules", "application/json", ScheduleCronScheduleListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create_cron,
    summary: "Create one recurring schedule",
    parameters: @actor_parameters,
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
      @actor_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
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
      @actor_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
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
      @actor_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse}]
  )

  operation(:resume_cron,
    summary: "Resume one recurring schedule",
    parameters:
      @actor_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse}]
  )

  operation(:remove_cron,
    summary: "Remove one recurring schedule",
    parameters:
      @actor_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Cron schedule", "application/json", ScheduleCronScheduleResponse}]
  )

  operation(:run_cron,
    summary: "Manually run one recurring schedule",
    parameters:
      @actor_parameters ++ [cron_schedule_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Scheduled event", "application/json", ScheduleEventResponse}]
  )

  operation(:cron_runs,
    summary: "List recent concrete fires for one recurring schedule",
    parameters:
      @actor_parameters ++
        [
          cron_schedule_id: [in: :path, type: :string, required: true],
          limit: [in: :query, type: :integer, required: false]
        ],
    responses: [ok: {"Scheduled events", "application/json", ScheduleEventListResponse}]
  )

  operation(:index_checkbacks,
    summary: "List checkback wakeups for one agent session",
    parameters: @actor_parameters,
    responses: [ok: {"Scheduled events", "application/json", ScheduleEventListResponse}]
  )

  operation(:cancel_checkback,
    summary: "Cancel one pending checkback wakeup",
    parameters:
      @actor_parameters ++ [scheduled_event_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Scheduled event", "application/json", ScheduleEventResponse}]
  )

  def index_cron(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "read") do
      schedules =
        actor.agent_uid
        |> Schedule.list_cron_schedules(actor.session_id)
        |> Enum.map(&Schedule.cron_projection/1)

      json(conn, %{data: schedules})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create_cron(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "update"),
         attrs <- cron_create_attrs(conn, actor),
         {:ok, %{cron_schedule: schedule}} <- Schedule.create_cron_schedule(attrs) do
      json(conn, %{data: Schedule.cron_projection(schedule)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show_cron(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "read"),
         {:ok, schedule} <- cron_for_actor(params, actor) do
      json(conn, %{data: Schedule.cron_projection(schedule)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update_cron(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "update"),
         {:ok, schedule} <- cron_for_actor(params, actor),
         {:ok, updated} <-
           Schedule.update_cron_schedule(schedule.id, normalize_external_attrs(conn.body_params)) do
      json(conn, %{data: Schedule.cron_projection(updated)})
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
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "update"),
         {:ok, schedule} <- cron_for_actor(params, actor),
         {:ok, %{scheduled_event: event}} <- Schedule.run_cron_schedule(schedule.id) do
      json(conn, %{data: Schedule.event_projection(event)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def cron_runs(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "read"),
         {:ok, schedule} <- cron_for_actor(params, actor) do
      runs =
        schedule.id
        |> Schedule.list_cron_runs(list_limit(params))
        |> Enum.map(&Schedule.event_projection/1)

      json(conn, %{data: runs})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def index_checkbacks(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "read") do
      events =
        actor.agent_uid
        |> Schedule.list_checkbacks(actor.session_id)
        |> Enum.map(&Schedule.event_projection/1)

      json(conn, %{data: events})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def cancel_checkback(conn, params) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), "delete"),
         {:ok, scheduled_event_id} <- text_param(params, "scheduled_event_id"),
         {:ok, event} <- Schedule.get_scheduled_event(scheduled_event_id),
         :ok <- event_belongs_to_actor(event, actor),
         {:ok, cancelled} <- Schedule.cancel_checkback(scheduled_event_id) do
      json(conn, %{data: Schedule.event_projection(cancelled)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp mutate_cron(conn, params, action, fun) do
    with {:ok, actor} <- actor_params(params),
         :ok <- ConsolePolicy.authorize(conn, schedule_resource(actor.agent_uid), action),
         {:ok, schedule} <- cron_for_actor(params, actor),
         {:ok, updated} <- fun.(schedule.id) do
      json(conn, %{data: Schedule.cron_projection(updated)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp cron_create_attrs(conn, actor) do
    conn.body_params
    |> normalize_external_attrs()
    |> Map.merge(%{
      "agent_uid" => actor.agent_uid,
      "session_id" => actor.session_id,
      "created_by" => %{
        "kind" => "operator_api",
        "principal_uid" => conn.assigns[:current_principal_uid]
      }
    })
  end

  defp cron_for_actor(params, actor) do
    with {:ok, cron_schedule_id} <- text_param(params, "cron_schedule_id"),
         {:ok, schedule} <- Schedule.get_cron_schedule(cron_schedule_id),
         :ok <- cron_belongs_to_actor(schedule, actor) do
      {:ok, schedule}
    end
  end

  defp cron_belongs_to_actor(%CronSchedule{} = schedule, actor) do
    case schedule.agent_uid == actor.agent_uid and schedule.session_id == actor.session_id do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  defp event_belongs_to_actor(%ScheduledEvent{} = event, actor) do
    case event.agent_uid == actor.agent_uid and event.session_id == actor.session_id do
      true -> :ok
      false -> {:error, :not_found}
    end
  end

  defp actor_params(params) do
    with {:ok, agent_uid} <- text_param(params, "agent_uid"),
         {:ok, session_id} <- text_param(params, "session_id") do
      {:ok, %{agent_uid: String.downcase(agent_uid), session_id: session_id}}
    end
  end

  defp text_param(params, key) do
    atom_key = param_atom(key)

    value =
      cond do
        Map.has_key?(params, key) -> Map.fetch!(params, key)
        Map.has_key?(params, atom_key) -> Map.fetch!(params, atom_key)
        true -> nil
      end

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp param_atom("agent_uid"), do: :agent_uid
  defp param_atom("session_id"), do: :session_id
  defp param_atom("cron_schedule_id"), do: :cron_schedule_id
  defp param_atom("scheduled_event_id"), do: :scheduled_event_id
  defp param_atom("limit"), do: :limit

  defp schedule_resource(agent_uid), do: "agent:#{agent_uid}:schedules"

  defp list_limit(params) do
    case integer_param(params, "limit") do
      value when is_integer(value) and value > 0 -> min(value, 100)
      _value -> 25
    end
  end

  defp integer_param(params, key) do
    case Map.get(params, key) || Map.get(params, param_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _value -> nil
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> nil
    end
  end

  defp normalize_external_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_external_attrs(_attrs), do: %{}

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "schedule was not found")

  defp error(conn, :cron_schedule_not_found),
    do: error(conn, 404, "not_found", "schedule was not found")

  defp error(conn, :scheduled_event_not_found),
    do: error(conn, 404, "not_found", "event was not found")

  defp error(conn, {:missing, key}) do
    error(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    error(
      conn,
      422,
      "validation_failed",
      "request validation failed",
      changeset_details(changeset)
    )
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_schedule", "schedule request is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp changeset_details(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&format_changeset_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &%{path: to_string(field), message: &1})
    end)
  end

  defp format_changeset_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, message ->
      String.replace(message, "%{#{key}}", to_string(value))
    end)
  end

  defp error(conn, status, code, message, details \\ []) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
