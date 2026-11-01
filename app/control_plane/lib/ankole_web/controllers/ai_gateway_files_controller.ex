defmodule AnkoleWeb.AIGatewayFilesController do
  @moduledoc """
  OpenAI-compatible Files API subset for AIGateway vision inputs.
  """

  use AnkoleWeb, :controller

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.OpenAIError

  def create(conn, _params) do
    params = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case upload(params) do
      %Plug.Upload{} = upload ->
        case Artifacts.create_uploaded_file(subject_uid, upload, params) do
          {:ok, artifact} -> json(conn, Artifacts.file_object(artifact))
          {:error, reason} -> error(conn, reason)
        end

      _missing ->
        error(
          conn,
          OpenAIError.invalid("file", "missing_required_parameter", "file is required.")
        )
    end
  end

  def index(conn, params) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.list_files(subject_uid, params) do
      {:ok, body} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, %{"file_id" => file_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.get_file(subject_uid, file_id) do
      {:ok, artifact} -> json(conn, Artifacts.file_object(artifact))
      {:error, reason} -> error(conn, reason)
    end
  end

  def content(conn, %{"file_id" => file_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.get_file(subject_uid, file_id, payload?: true) do
      {:ok, artifact} ->
        conn
        |> put_resp_header("content-type", artifact.mime_type)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename*=UTF-8''" <>
            URI.encode(
              Ankole.Files.file_name(artifact.filename || "image"),
              &URI.char_unreserved?/1
            )
        )
        |> send_resp(200, artifact.payload)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def delete(conn, %{"file_id" => file_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.delete_file(subject_uid, file_id) do
      {:ok, body} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp upload(params) when is_map(params), do: Map.get(params, "file")

  defp error(conn, %OpenAIError{} = error) do
    conn
    |> put_status(error.status)
    |> json(OpenAIError.envelope(error))
  end

  defp error(conn, _reason) do
    error(
      conn,
      %OpenAIError{
        status: 500,
        message: "The file request could not be completed.",
        type: "server_error",
        code: "server_error",
        param: nil
      }
    )
  end
end
