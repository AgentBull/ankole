defmodule AnkoleWeb.PodModelController do
  @moduledoc "Safe model names and preferences for the current Human's native Chat."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias Ankole.Conversations
  alias Ankole.Conversations.ModelPreferences
  alias AnkoleWeb.{ConsoleErrors, Schemas.PodModels}
  alias AnkoleWeb.Schemas.InternalAPI.ErrorEnvelope

  operation(:catalog,
    operation_id: "podModelProfiles",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Configured profile names", "application/json", PodModels.Catalog},
      401 => {"Error", "application/json", ErrorEnvelope},
      404 => {"Error", "application/json", ErrorEnvelope}
    }
  )

  def catalog(conn, %{"uid" => uid}) do
    case ModelPreferences.catalog(uid) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:show,
    operation_id: "podModelSelection",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Chat model preference", "application/json", PodModels.Selection},
      401 => {"Error", "application/json", ErrorEnvelope},
      404 => {"Error", "application/json", ErrorEnvelope}
    }
  )

  def show(conn, %{"id" => id}) do
    case Conversations.model_preferences(conn.assigns.current_principal_uid, id) do
      {:ok, result} -> json(conn, selection_json(result))
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:update,
    operation_id: "setPodModelSelection",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Chat model preference", "application/json", PodModels.Choice},
    responses: %{
      200 => {"Saved preference", "application/json", PodModels.Selection},
      401 => {"Error", "application/json", ErrorEnvelope},
      404 => {"Error", "application/json", ErrorEnvelope},
      422 => {"Error", "application/json", ErrorEnvelope}
    }
  )

  def update(conn, %{"id" => id}) do
    with %{"profile" => profile} <- conn.body_params,
         {:ok, result} <-
           Conversations.set_model_profile(conn.assigns.current_principal_uid, id, profile) do
      json(conn, selection_json(result))
    else
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :invalid_request)
    end
  end

  defp selection_json(result),
    do: %{
      profile: result.profile,
      activeProfile: result.active_profile,
      profiles: result.profiles
    }

  defp error(conn, :model_profile_unavailable),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "model_profile_unavailable",
        "This model profile is unavailable."
      )

  defp error(conn, :invalid_request),
    do: ConsoleErrors.render(conn, 422, "invalid_request", "Request is invalid")

  defp error(conn, :agent_unavailable),
    do: ConsoleErrors.render(conn, 404, "agent_unavailable", "Agent is unavailable")

  defp error(conn, _),
    do: ConsoleErrors.render(conn, 404, "conversation_not_found", "Conversation not found")
end
