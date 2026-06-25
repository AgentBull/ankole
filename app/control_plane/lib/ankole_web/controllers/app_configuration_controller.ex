defmodule AnkoleWeb.AppConfigurationController do
  @moduledoc """
  Console REST API for registry-backed AppConfigure values.

  AppConfigure is Ankole's runtime settings registry: a known set of keys, each
  with its own schema, default, and whether it is encrypted or console-editable.
  This controller is the bearer-token surface the console UI uses to list, read,
  set, reset, and (for secrets) reveal those values.

  Every action follows the same shape: authorize the principal for this exact
  resource/action via `ConsolePolicy`, then call the AppConfigure context, then
  map any domain error onto the console error envelope. The `with` chains keep
  authorization first so a forbidden caller never touches the value.
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

  # Casts and validates params/body against the `operation/2` specs below before
  # any action runs; on a schema mismatch it short-circuits with a 422 rendered in
  # our console error envelope instead of the OpenApiSpex default JSON.
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

  @doc """
  Lists every AppConfigure entry the console is allowed to surface.

  Only console-visible entries are returned (the context filters internal-only
  keys), and encrypted values come back masked — `decrypt/2` reveals them.
  """
  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "app_configurations", "read"),
         {:ok, items} <- AppConfigure.list_console_items() do
      json(conn, %{data: items})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Reads one entry by key. Authorization is scoped to that specific key.
  """
  def show(conn, params) do
    with {:ok, key} <- key_param(params),
         :ok <- ConsolePolicy.authorize(conn, "app_configuration:#{key}", "read"),
         {:ok, item} <- AppConfigure.console_detail_by_key(key) do
      json(conn, %{data: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Sets the global value for one key (the installation-wide override).

  Writes the "global" layer of AppConfigure, on top of the compiled-in default.
  The value is validated against the key's own schema downstream in the context.
  """
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

  @doc """
  Resets one key by removing its global override, falling back to the default.

  This deletes the override layer, not the key — the entry remains and reverts to
  its compiled-in default. Authorized under the distinct `"reset"` action.
  """
  def delete(conn, params) do
    with {:ok, key} <- key_param(params),
         :ok <- ConsolePolicy.authorize(conn, "app_configuration:#{key}", "reset"),
         {:ok, item} <- AppConfigure.console_delete_global_by_key(key) do
      json(conn, %{data: item})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  @doc """
  Reveals an encrypted value on demand.

  Decryption is a separate, separately-authorized action (`"decrypt"`) precisely
  so that listing/reading config does not expose secrets — a principal can browse
  config without being able to read the secret material behind it.
  """
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

  # Translates AppConfigure context errors into the console error envelope with a
  # stable machine `code`. The `ambiguous_key`/`pattern_key_not_editable` cases
  # come from AppConfigure's pattern keys (e.g. wildcard keys that must be
  # materialized globally before they can be edited per-instance).
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
