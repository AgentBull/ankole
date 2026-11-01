defmodule AnkoleWeb.AgentFileController do
  @moduledoc "Site Console uploads and byte downloads for any tenant Drive."
  use AnkoleWeb, :controller
  action_fallback :fallback
  alias Ankole.{Attrs, Files}
  alias AnkoleWeb.ConsoleErrors

  def download(conn, params) do
    with {:ok, tenant_id} <-
           Attrs.required_text(Map.get(params, "tenant_id"), {:missing, :tenant_id}),
         {:ok, id} <- required_id(params),
         {:ok, %{node: node, object: object}} <-
           Files.console_download(conn.assigns.authz_actor, tenant_id, id) do
      AnkoleWeb.PodResponse.send_sandboxed_object(
        conn,
        object,
        node.name,
        node.content_type,
        true
      )
    end
  end

  def upload(conn, params) do
    body = conn.body_params

    with {:ok, tenant_id} <-
           Attrs.required_text(Map.get(params, "tenant_id"), {:missing, :tenant_id}),
         {:ok, parent_id} <- Attrs.required_text(body["parent_id"], {:missing, :parent_id}),
         {:ok, name} <- Attrs.required_text(body["name"], {:missing, :name}),
         {:ok, upload} <- upload_param(body),
         :ok <- assert_upload_size(upload),
         {:ok, file} <-
           Files.console_upload(
             conn.assigns.authz_actor,
             tenant_id,
             parent_id,
             name,
             upload.path,
             upload.content_type
           ) do
      json(conn, %{uploaded_file: file})
    end
  end

  defp required_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp required_id(_params), do: {:error, {:missing, :id}}

  defp upload_param(body) do
    case Map.get(body, "file") do
      %Plug.Upload{} = upload -> {:ok, upload}
      _value -> {:error, :missing_file}
    end
  end

  defp assert_upload_size(%Plug.Upload{path: path}) do
    with {:ok, max_bytes} <- Files.upload_limit(),
         {:ok, %{size: size}} <- File.stat(path) do
      if size > max_bytes, do: {:error, {:file_too_large, size, max_bytes}}, else: :ok
    end
  end

  defp fallback(conn, {:error, reason}), do: error(conn, reason)

  defp error(conn, :forbidden),
    do: ConsoleErrors.render(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "file not found")

  defp error(conn, :invalid_uid), do: ConsoleErrors.not_found(conn, "agent not found")

  defp error(conn, :agent_not_found),
    do: ConsoleErrors.render(conn, 404, "agent_not_found", "agent not found")

  defp error(conn, :already_exists),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "already_exists",
        "a file already exists at the target path"
      )

  defp error(conn, {:path_conflict, parent, child}),
    do:
      ConsoleErrors.render(conn, 409, "path_conflict", "a file cannot also be a folder", [
        %{parent: parent, child: child}
      ])

  defp error(conn, {:missing, label}),
    do: ConsoleErrors.required_field(conn, label)

  defp error(conn, :missing_file),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "file is required")

  defp error(conn, {:file_too_large, _size, max_bytes}) do
    ConsoleErrors.render(conn, 422, "file_too_large", "file exceeds the transfer limit", [
      %{max_bytes: max_bytes}
    ])
  end

  defp error(conn, :invalid_name),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "invalid file name")

  defp error(conn, {:invalid_path, value}),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "invalid path", [%{value: value}])

  defp error(conn, reason) do
    ConsoleErrors.unexpected(
      conn,
      "files.agent_file_api.unexpected_error",
      reason,
      "file_operation_failed",
      "file operation failed"
    )
  end
end
