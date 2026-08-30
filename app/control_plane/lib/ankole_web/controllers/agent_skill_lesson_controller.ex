defmodule AnkoleWeb.AgentSkillLessonController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for per-Agent skill lessons.

  Dreaming writes leased lessons through its own gates; this surface gives
  operators the veto and the manual path: list every row, add a human lesson,
  and retire any lesson. A retired dreaming lesson joins the immunity list, so
  Dreaming never re-adds equivalent content.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIAgent.Library
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentSkillLessonCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentSkillLessonsResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  @standard_responses [
    ok: {"Agent skill lessons", "application/json", AgentSkillLessonsResponse},
    unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
    forbidden: {"Forbidden", "application/json", ErrorEnvelope},
    not_found: {"Not found", "application/json", ErrorEnvelope},
    unprocessable_entity: {"Invalid skill lesson", "application/json", ErrorEnvelope}
  ]

  tags(["Agents"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "Read the skill lessons of one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: @standard_responses
  )

  operation(:create,
    summary: "Add one human skill lesson",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Agent skill lesson", "application/json", AgentSkillLessonCreateRequest, required: true},
    responses: @standard_responses
  )

  operation(:retire,
    summary: "Retire one skill lesson",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      lesson_id: [in: :path, type: :string, required: true]
    ],
    responses: @standard_responses
  )

  def index(conn, params) do
    with {:ok, agent_uid} <- required_path_text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "read") do
      render_lessons(conn, agent_uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, params) do
    with {:ok, agent_uid} <- required_path_text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, skill_name} <- body_text(conn.body_params, :skill_name),
         {:ok, content} <- body_text(conn.body_params, :content),
         {:ok, _lesson} <-
           Library.create_skill_lesson(
             agent_uid,
             skill_name,
             content,
             conn.assigns.current_principal_uid
           ) do
      render_lessons(conn, agent_uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def retire(conn, params) do
    with {:ok, agent_uid} <- required_path_text(params, :agent_uid),
         {:ok, lesson_id} <- required_path_text(params, :lesson_id),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, _lesson} <- Library.retire_skill_lesson(agent_uid, lesson_id) do
      render_lessons(conn, agent_uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp render_lessons(conn, agent_uid) do
    case Library.list_skill_lessons(agent_uid) do
      {:ok, lessons} -> json(conn, %{skill_lessons: lessons})
      {:error, reason} -> error(conn, reason)
    end
  end

  defp required_path_text(params, key) do
    case map_value(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, Atom.to_string(key)}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, Atom.to_string(key)}}
    end
  end

  defp body_text(params, key) when is_map(params) do
    case map_value(params, key) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:missing, Atom.to_string(key)}}
    end
  end

  defp body_text(_params, key), do: {:error, {:missing, Atom.to_string(key)}}

  defp map_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "agent was not found")

  defp error(conn, reason) when reason in [:skill_not_found, :skill_lesson_not_found] do
    error(conn, 404, "not_found", "agent skill lesson was not found")
  end

  defp error(conn, :skill_lesson_already_retired) do
    error(conn, 422, "validation_failed", "skill lesson is already retired")
  end

  defp error(conn, :skill_not_enabled) do
    error(conn, 422, "validation_failed", "skill is not enabled for this agent")
  end

  defp error(conn, :blank_content) do
    error(conn, 422, "validation_failed", "lesson content is required")
  end

  defp error(conn, :content_contains_url) do
    error(conn, 422, "validation_failed", "lesson content must not contain a URL")
  end

  defp error(conn, {:missing, key}),
    do: error(conn, 422, "validation_failed", "#{key} is required")

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
    error(conn, 422, "invalid_skill_lesson", "agent skill lesson is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
