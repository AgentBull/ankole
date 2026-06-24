defmodule AnkoleWeb.AppConfigurationController do
  @moduledoc """
  Console REST API for registry-backed AppConfigure values.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.AppConfigure
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.AppConfigurationDecryptionResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AppConfigurationListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AppConfigurationResponse
  alias AnkoleWeb.Schemas.ConsoleApi.AppConfigurationUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope

  tags(["AppConfigure"])
  security([%{"consoleBearer" => []}])

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenApiValidationErrorRenderer

  operation(:index,
    summary: "List console-visible AppConfigure entries",
    responses: [
      ok: {"AppConfigure entries", "application/json", AppConfigurationListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one console-editable AppConfigure entry",
    parameters: [key: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"AppConfigure entry", "application/json", AppConfigurationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Not editable", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Store one global AppConfigure value",
    parameters: [key: [in: :path, type: :string, required: true]],
    request_body:
      {"AppConfigure update", "application/json", AppConfigurationUpdateRequest, required: true},
    responses: [
      ok: {"AppConfigure entry", "application/json", AppConfigurationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid value", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Reset one global AppConfigure value",
    parameters: [key: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"AppConfigure entry", "application/json", AppConfigurationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Not editable", "application/json", ErrorEnvelope}
    ]
  )

  operation(:decrypt,
    summary: "Reveal one encrypted AppConfigure value on demand",
    parameters: [key: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Decrypted value", "application/json", AppConfigurationDecryptionResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Not encrypted", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "app_configurations", "read"),
         {:ok, items} <- AppConfigure.list_console_items() do
      json(conn, %{data: items})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, key} <- key_param(params),
         :ok <- ConsolePolicy.authorize(conn, "app_configuration:#{key}", "read"),
         {:ok, item} <- AppConfigure.console_detail_by_key(key) do
      json(conn, %{data: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    with {:ok, key} <- key_param(params),
         :ok <- ConsolePolicy.authorize(conn, "app_configuration:#{key}", "update"),
         {:ok, value} <- request_value(conn.body_params),
         {:ok, item} <- AppConfigure.console_put_global_by_key(key, value) do
      json(conn, %{data: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    with {:ok, key} <- key_param(params),
         :ok <- ConsolePolicy.authorize(conn, "app_configuration:#{key}", "reset"),
         {:ok, item} <- AppConfigure.console_delete_global_by_key(key) do
      json(conn, %{data: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def decrypt(conn, params) do
    with {:ok, key} <- key_param(params),
         :ok <- ConsolePolicy.authorize(conn, "app_configuration:#{key}", "decrypt"),
         {:ok, value} <- AppConfigure.console_decrypt_by_key(key) do
      json(conn, %{data: %{key: key, value: value}})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp key_param(%{"key" => key}) when is_binary(key), do: {:ok, key}
  defp key_param(%{key: key}) when is_binary(key), do: {:ok, key}
  defp key_param(_params), do: {:error, :missing_key}

  defp request_value(%{"value" => value}), do: {:ok, value}
  defp request_value(%{value: value}), do: {:ok, value}
  defp request_value(_body), do: {:error, :missing_value}

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")

  defp error(conn, {:unknown_key, _key}) do
    error(conn, 404, "not_found", "app configuration was not found")
  end

  defp error(conn, {:ambiguous_key, _key, matches}) do
    error(conn, 422, "ambiguous_key", "app configuration matches more than one pattern", [
      %{matches: matches}
    ])
  end

  defp error(conn, {:pattern_key_not_editable, _key}) do
    error(conn, 422, "not_editable", "pattern key must exist globally before console editing")
  end

  defp error(conn, :not_encrypted) do
    error(conn, 422, "not_encrypted", "app configuration is not encrypted")
  end

  defp error(conn, :missing_value) do
    error(conn, 422, "validation_failed", "value is required")
  end

  defp error(conn, :missing_key) do
    error(conn, 422, "validation_failed", "key is required")
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_value", "app configuration value is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message, details: details}})
  end
end
