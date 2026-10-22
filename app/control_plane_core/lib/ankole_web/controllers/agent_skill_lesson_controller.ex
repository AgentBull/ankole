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

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIAgent.Library
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentSkillLessonCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentSkillLessonsResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  @standard_responses [
    ok: {"Agent skill lessons", "application/json", AgentSkillLessonsResponse},
    default: {"Error", "application/json", ErrorEnvelope}
  ]

  tags(["Agents"])
  security([%{"consoleSession" => []}])

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
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "read") do
      render_lessons(conn, agent_uid)
    end
  end

  def create(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, skill_name} <- body_text(conn.body_params, :skill_name),
         {:ok, content} <- body_text(conn.body_params, :content),
         {:ok, _lesson} <-
           Library.create_skill_lesson(
             agent_uid,
             skill_name,
             content,
             Ankole.ActorRef.from_principal(conn.assigns.current_principal)
           ) do
      render_lessons(conn, agent_uid)
    end
  end

  def retire(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, lesson_id} <- ConsoleParams.text(params, :lesson_id),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, _lesson} <- Library.retire_skill_lesson(agent_uid, lesson_id) do
      render_lessons(conn, agent_uid)
    end
  end

  defp render_lessons(conn, agent_uid) do
    case Library.list_skill_lessons(agent_uid) do
      {:ok, lessons} -> json(conn, %{skill_lessons: lessons})
      {:error, reason} -> {:error, reason}
    end
  end

  defp body_text(params, key) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:missing, Atom.to_string(key)}}
    end
  end

  defp body_text(_params, key), do: {:error, {:missing, Atom.to_string(key)}}

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "agent was not found")

  defp error(conn, reason) when reason in [:skill_not_found, :skill_lesson_not_found] do
    ConsoleErrors.not_found(conn, "agent skill lesson was not found")
  end

  defp error(conn, :skill_lesson_already_retired) do
    ConsoleErrors.render(conn, 422, "validation_failed", "skill lesson is already retired")
  end

  defp error(conn, :skill_not_enabled) do
    ConsoleErrors.render(conn, 422, "validation_failed", "skill is not enabled for this agent")
  end

  defp error(conn, :blank_content) do
    ConsoleErrors.render(conn, 422, "validation_failed", "lesson content is required")
  end

  defp error(conn, :content_contains_url) do
    ConsoleErrors.render(conn, 422, "validation_failed", "lesson content must not contain a URL")
  end

  defp error(conn, {:missing, key}),
    do: ConsoleErrors.required_field(conn, key)

  defp error(conn, %module{} = changeset) when module in [Ash.Changeset, Ash.Error.Invalid] do
    ConsoleErrors.changeset(conn, changeset)
  end

  defp error(conn, reason) do
    ConsoleErrors.render(conn, 422, "invalid_skill_lesson", "agent skill lesson is invalid", [
      %{reason: inspect(reason)}
    ])
  end
end
