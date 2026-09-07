defmodule AnkoleWeb.PrincipalController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for selecting Principal accounts.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AuthZ
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias AnkoleWeb.AuthZJSON
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PermissionGrantListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalCreateRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalCreateResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalGroupListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.PrincipalUpdateRequest

  tags(["Principals"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List principals",
    parameters: [include_disabled: [in: :query, type: :boolean, required: false]],
    responses: [
      ok: {"Principals", "application/json", PrincipalListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one principal",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Principal", "application/json", PrincipalResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create,
    summary: "Create a human user with a local sign-in password",
    request_body: {"User", "application/json", PrincipalCreateRequest, required: true},
    responses: [
      ok: {"Created user", "application/json", PrincipalCreateResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      conflict: {"Local sign-in disabled", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid user", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Update the display name or email of one human user",
    parameters: [uid: [in: :path, type: :string, required: true]],
    request_body: {"User changes", "application/json", PrincipalUpdateRequest, required: true},
    responses: [
      ok: {"Principal", "application/json", PrincipalResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Local sign-in disabled", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid change", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create_local_password_reset,
    summary: "Replace one user's local password with a new one-time password",
    parameters: [uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Reset options", "application/json", LocalPasswordResetRequest, required: true},
    responses: [
      ok: {"New one-time password", "application/json", LocalPasswordResetResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Local sign-in disabled", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid reset", "application/json", ErrorEnvelope}
    ]
  )

  operation(:groups,
    summary: "List the static Principal groups one Principal belongs to",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Principal groups", "application/json", PrincipalGroupListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:grants,
    summary: "List permission grants owned directly by one Principal",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Permission grants", "application/json", PermissionGrantListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "principals", "read") do
      json(conn, %{
        principals:
          Enum.map(
            Principals.list_principal_accounts(
              include_disabled: Map.get(params, :include_disabled, false)
            ),
            &account_json/1
          )
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "read"),
         {:ok, account} <- Principals.get_principal_account(uid) do
      json(conn, %{principal: account_json(account)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _params) do
    body = conn.body_params

    with :ok <- ConsolePolicy.authorize(conn, "principals", "update"),
         :ok <- require_local_identity_provider(),
         {:ok, email} <- email_attr(Map.get(body, :email)),
         {:ok, result} <-
           Principals.create_local_user(
             %{uid: email, email: email, display_name: Map.get(body, :display_name)},
             Map.get(body, :must_change_password, true)
           ),
         {:ok, account} <- Principals.get_principal_account(result.principal.uid) do
      json(conn, %{principal: account_json(account), initial_password: result.initial_password})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    body = conn.body_params

    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "update"),
         :ok <- require_local_identity_provider(),
         {:ok, attrs} <- update_attrs(body),
         {:ok, _updated} <- Principals.update_human(uid, attrs),
         {:ok, account} <- Principals.get_principal_account(uid) do
      json(conn, %{principal: account_json(account)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create_local_password_reset(conn, params) do
    body = conn.body_params

    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "reset"),
         :ok <- require_local_identity_provider(),
         {:ok, initial_password} <-
           LocalPassword.reset_local_password(uid, Map.get(body, :must_change_password, true)) do
      json(conn, %{initial_password: initial_password})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def groups(conn, params) do
    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}:groups", "read"),
         {:ok, groups} <- AuthZ.list_principal_group_memberships(uid) do
      summaries = AuthZ.summarize_principal_groups()

      json(conn, %{
        principal_groups: Enum.map(groups, &AuthZJSON.group_json(&1, summaries))
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def grants(conn, params) do
    with {:ok, uid} <- uid_param(params),
         :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}:grants", "read"),
         {:ok, grants} <- AuthZ.list_principal_grants(uid) do
      json(conn, %{permission_grants: Enum.map(grants, &AuthZJSON.grant_json/1)})
    else
      {:error, reason} -> error(conn, reason)
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

  defp email_attr(email) do
    case Principals.normalize_email(email) do
      nil -> {:error, {:missing, "email"}}
      normalized -> {:ok, normalized}
    end
  end

  defp update_attrs(body) do
    attrs =
      body
      |> Map.take([:display_name, :email])
      |> Map.new(fn {key, value} -> {key, value} end)

    case Map.fetch(attrs, :email) do
      :error ->
        {:ok, attrs}

      {:ok, email} ->
        with {:ok, normalized} <- email_attr(email) do
          {:ok, Map.put(attrs, :email, normalized)}
        end
    end
  end

  defp account_json(%{principal: %Principal{} = principal} = account) do
    %{
      uid: principal.uid,
      type: Atom.to_string(principal.type),
      status: Atom.to_string(principal.status),
      display_name: principal.display_name,
      avatar_url: principal.avatar_url,
      email: account.email,
      has_external_identity: account.has_external_identity,
      local_credential: local_credential_json(account.local_credential_status),
      inserted_at: DateTime.to_iso8601(principal.inserted_at),
      updated_at: DateTime.to_iso8601(principal.updated_at)
    }
  end

  defp local_credential_json(nil), do: nil
  defp local_credential_json(status), do: %{status: Atom.to_string(status)}

  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "access denied")

  defp error(conn, :not_found),
    do: ConsoleErrors.render(conn, 404, "not_found", "principal was not found")

  defp error(conn, {:missing, key}),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "#{key} is required")

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

  defp error(conn, %Ecto.Changeset{} = changeset) do
    details = ConsoleErrors.changeset_details(changeset)

    # The create path derives the principal uid from the email, so a duplicate
    # uid means the same thing to the operator as a duplicate email.
    case Enum.any?(details, &(&1.path in ["email", "uid"] and &1.message =~ "taken")) do
      true ->
        ConsoleErrors.render(
          conn,
          422,
          "email_taken",
          "another user already uses this email",
          details
        )

      false ->
        ConsoleErrors.render(
          conn,
          422,
          "validation_failed",
          "user attributes are invalid",
          details
        )
    end
  end

  defp error(conn, reason),
    do:
      ConsoleErrors.render(conn, 422, "invalid_principal", "principal request is invalid", [
        %{reason: inspect(reason)}
      ])
end
