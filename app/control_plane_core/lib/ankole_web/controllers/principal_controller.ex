defmodule AnkoleWeb.PrincipalController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API that replaces the local password of a Principal.

  The response gives a new one-time password, so this endpoint stays outside
  the JSON:API resource routes of `Ankole.Principals`.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.IdentityProviders.LocalPassword
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetResponse

  tags(["Principals"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:create_local_password_reset,
    summary: "Replace one user's local password with a new one-time password",
    parameters: [uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Reset options", "application/json", LocalPasswordResetRequest, required: true},
    responses: [
      ok: {"New one-time password", "application/json", LocalPasswordResetResponse},
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def create_local_password_reset(conn, params) do
    body = conn.body_params

    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "reset"),
         :ok <- require_local_identity_provider(),
         {:ok, initial_password} <-
           LocalPassword.reset_local_password(uid, Map.get(body, :must_change_password, true)) do
      json(conn, %{initial_password: initial_password})
    end
  end

  defp uid_param(params) do
    case Map.get(params, :uid) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, "uid"}}
    end
  end

  # Every local-account write requires an enabled local identity provider so
  # the console cannot mint credentials that no login path accepts.
  defp require_local_identity_provider do
    case LocalPassword.enabled?() do
      true -> :ok
      false -> {:error, :local_identity_provider_disabled}
    end
  end

  defp fallback(conn, failure),
    do:
      ConsoleErrors.fallback(conn, failure, &error/2,
        validation: {"validation_failed", "local password request is invalid"}
      )

  defp error(conn, :not_found),
    do: ConsoleErrors.not_found(conn, "principal was not found")

  defp error(conn, {:missing, key}),
    do: ConsoleErrors.required_field(conn, key)

  defp error(conn, :local_identity_provider_disabled),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "local_identity_provider_disabled",
        "local account sign-in is not enabled"
      )

  defp error(conn, :email_missing),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "email_missing",
        "this user has no email address, which local sign-in requires"
      )

  defp error(conn, :not_human),
    do: ConsoleErrors.render(conn, 422, "not_human", "local passwords apply to human users only")

  defp error(conn, reason),
    do:
      ConsoleErrors.unexpected(
        conn,
        "principals.api.unexpected_error",
        reason,
        "invalid_principal",
        "principal request is invalid"
      )
end
