defmodule AnkoleWeb.CodexAccountController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed Codex subscription accounts.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIAgent.CodexAccounts
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.CodexAccountCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.CodexAccountListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.CodexAccountResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.CodexAccountUpdateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  tags(["Codex Accounts"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List Codex accounts",
    responses: [
      ok: {"Codex accounts", "application/json", CodexAccountListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create a Codex account",
    request_body:
      {"Codex account", "application/json", CodexAccountCreateRequest, required: true},
    responses: [
      ok: {"Codex account", "application/json", CodexAccountResponse},
      unprocessable_entity: {"Invalid Codex account", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update a Codex account",
    parameters: [account_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Codex account", "application/json", CodexAccountUpdateRequest, required: true},
    responses: [
      ok: {"Codex account", "application/json", CodexAccountResponse},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid Codex account", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete a Codex account",
    parameters: [account_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Codex account", "application/json", CodexAccountResponse},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Codex account in use", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "codex_accounts", "read") do
      json(conn, %{codex_accounts: CodexAccounts.list_accounts()})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "codex_accounts", "update"),
         {:ok, account} <- CodexAccounts.create_account(conn.body_params) do
      json(conn, %{codex_account: CodexAccounts.projection(account)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    account_id = Map.get(params, :account_id, Map.get(params, "account_id", ""))

    with :ok <- ConsolePolicy.authorize(conn, "codex_account:#{account_id}", "update"),
         {:ok, account} <- CodexAccounts.update_account(account_id, conn.body_params) do
      json(conn, %{codex_account: CodexAccounts.projection(account)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, params) do
    account_id = Map.get(params, :account_id, Map.get(params, "account_id", ""))

    with :ok <- ConsolePolicy.authorize(conn, "codex_account:#{account_id}", "delete"),
         {:ok, account} <- CodexAccounts.delete_account(account_id) do
      json(conn, %{codex_account: CodexAccounts.projection(account)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp error(conn, :forbidden), do: render_error(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found),
    do: render_error(conn, 404, "not_found", "Codex account was not found")

  defp error(conn, {:codex_account_in_use, references}) do
    render_error(conn, 422, "codex_account_in_use", "Codex account is still in use", references)
  end

  defp error(conn, {:missing, key}) do
    render_error(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    render_error(
      conn,
      422,
      "validation_failed",
      "request validation failed",
      ConsoleErrors.changeset_details(changeset)
    )
  end

  defp error(conn, reason) do
    render_error(conn, 422, "invalid_codex_account", "Codex account is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp render_error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
