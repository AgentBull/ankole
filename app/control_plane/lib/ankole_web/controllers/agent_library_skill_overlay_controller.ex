defmodule AnkoleWeb.AgentLibrarySkillOverlayController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for the per-Agent skill overlays that hold skill experience.

  Dreaming and the worker `skill_append` tool write the same rows, so every write
  here is compare-and-set: a stale Console editor is rejected instead of dropping
  guidance that a curation run added in the meantime.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIAgent.Library
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibrarySkillOverlaysResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibrarySkillOverlayWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  @standard_responses [
    ok: {"Agent skill overlays", "application/json", AgentLibrarySkillOverlaysResponse},
    unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
    forbidden: {"Forbidden", "application/json", ErrorEnvelope},
    not_found: {"Not found", "application/json", ErrorEnvelope},
    unprocessable_entity: {"Invalid skill overlay", "application/json", ErrorEnvelope}
  ]

  tags(["Agents"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "Read the skill overlays of one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: @standard_responses
  )

  operation(:update,
    summary: "Replace one agent skill overlay",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      skill_name: [in: :path, type: :string, required: true]
    ],
    request_body:
      {"Agent skill overlay", "application/json", AgentLibrarySkillOverlayWriteRequest,
       required: true},
    responses:
      Keyword.put(
        @standard_responses,
        :conflict,
        {"Skill overlay changed", "application/json", ErrorEnvelope}
      )
  )

  operation(:delete,
    summary: "Delete one agent skill overlay",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      skill_name: [in: :path, type: :string, required: true]
    ],
    responses: @standard_responses
  )

  def index(conn, params) do
    with {:ok, agent_uid} <- required_path_text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "read") do
      render_overlays(conn, agent_uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    with {:ok, agent_uid} <- required_path_text(params, :agent_uid),
         {:ok, skill_name} <- required_path_text(params, :skill_name),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, text} <- overlay_text(conn.body_params),
         {:ok, expected_content_hash} <- body_text(conn.body_params, :expected_content_hash),
         {:ok, _overlay} <-
           Library.replace_skill_overlay_cas(
             agent_uid,
             skill_name,
             expected_content_hash,
             %{"text" => text}
           ) do
      render_overlays(conn, agent_uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, agent_uid} <- required_path_text(params, :agent_uid),
         {:ok, skill_name} <- required_path_text(params, :skill_name),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, _overlay} <- Library.delete_skill_overlay(agent_uid, skill_name) do
      render_overlays(conn, agent_uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp render_overlays(conn, agent_uid) do
    case Library.list_skill_overlays(agent_uid) do
      {:ok, overlays} -> json(conn, %{skill_overlays: overlays})
      {:error, reason} -> error(conn, reason)
    end
  end

  # A blank overlay reads as "no overlay" to the worker, so accepting one here
  # would leave a row that the Console lists and the model never sees.
  defp overlay_text(body_params) do
    with {:ok, text} <- body_text(body_params, :text) do
      case String.trim(text) do
        "" -> {:error, :blank_skill_overlay}
        trimmed -> {:ok, trimmed}
      end
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

  defp error(conn, reason) when reason in [:skill_not_found, :skill_overlay_not_found] do
    error(conn, 404, "not_found", "agent skill overlay was not found")
  end

  defp error(conn, :skill_overlay_conflict) do
    error(
      conn,
      409,
      "skill_overlay_conflict",
      "agent skill overlay changed since it was loaded"
    )
  end

  defp error(conn, :skill_not_enabled) do
    error(conn, 422, "validation_failed", "skill is not enabled for this agent")
  end

  defp error(conn, :blank_skill_overlay) do
    error(conn, 422, "validation_failed", "delete the overlay instead of storing blank text")
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
    error(conn, 422, "invalid_skill_overlay", "agent skill overlay is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
