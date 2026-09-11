defmodule AnkoleWeb.HumanAccessController do
  @moduledoc "Console operations for Human restrictions and reviewed recovery."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  import Ecto.Query
  alias Ankole.{AuthZ, Principals, Repo}
  alias Ankole.Principals.{HumanAccess, WorkAccess, WorkCleanup}
  alias AnkoleWeb.{ConsoleErrors, ConsolePolicy}
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias AnkoleWeb.Schemas.HumanAccessAPI

  tags(["Principals"])
  security([%{"consoleBearer" => []}])
  plug OpenApiSpex.Plug.CastAndValidate, render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:show,
    summary: "Read Human access, permission review, and cleanup state",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Human access", "application/json", HumanAccessAPI.HumanAccessResponse},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:disable,
    summary: "Disable a Human and revoke future access",
    parameters: [uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Reason", "application/json", HumanAccessAPI.AccessReasonRequest, required: true},
    responses: [
      ok: {"Human access", "application/json", HumanAccessAPI.HumanAccessResponse},
      conflict: {"Cannot disable", "application/json", ErrorEnvelope}
    ]
  )

  operation(:clear_restriction,
    summary: "Clear one verified restriction without restoring access",
    parameters: [
      uid: [in: :path, type: :string, required: true],
      restriction_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    request_body:
      {"Review", "application/json", HumanAccessAPI.AccessReasonRequest, required: true},
    responses: [
      ok: {"Human access", "application/json", HumanAccessAPI.HumanAccessResponse},
      conflict: {"Review required", "application/json", ErrorEnvelope}
    ]
  )

  operation(:restore,
    summary: "Restore Human access after identity and permission review",
    parameters: [uid: [in: :path, type: :string, required: true]],
    request_body:
      {"Approved review", "application/json", HumanAccessAPI.AccessRestoreRequest, required: true},
    responses: [
      ok: {"Human access", "application/json", HumanAccessAPI.HumanAccessResponse},
      conflict: {"Review changed", "application/json", ErrorEnvelope}
    ]
  )

  operation(:retry_cleanup,
    summary: "Retry cleanup of revoked future work",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: [ok: {"Human access", "application/json", HumanAccessAPI.HumanAccessResponse}]
  )

  operation(:unresolved_work,
    summary: "List work whose Human or service authority needs review",
    responses: [ok: {"Work review", "application/json", HumanAccessAPI.WorkReviewResponse}]
  )

  operation(:classify_work,
    summary: "Set the reviewed authority of unresolved work",
    request_body:
      {"Work review", "application/json", HumanAccessAPI.WorkClassifyRequest, required: true},
    responses: [
      ok: {"Work review", "application/json", HumanAccessAPI.WorkReviewResponse},
      conflict: {"Review changed", "application/json", ErrorEnvelope}
    ]
  )

  def show(conn, %{uid: uid}) do
    with :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "read") do
      access(conn, uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def disable(conn, %{uid: uid}) do
    body = conn.body_params

    with :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "update"),
         {:ok, _} <- HumanAccess.disable(uid, body.reason, actor(conn), body.operation_id) do
      access(conn, uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def clear_restriction(conn, %{uid: uid, restriction_id: id}) do
    body = conn.body_params

    with :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "update"),
         {:ok, _} <-
           HumanAccess.clear_restriction(uid, id, actor(conn), body.reason, body.operation_id) do
      access(conn, uid)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def restore(conn, %{uid: uid}) do
    body = conn.body_params

    with :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "update"),
         true <- body.identity_verified,
         {:ok, _} <-
           HumanAccess.restore(
             uid,
             body.review_fingerprint,
             actor(conn),
             body.reason,
             body.operation_id
           ) do
      access(conn, uid)
    else
      false -> error(conn, :identity_review_required)
      {:error, reason} -> error(conn, reason)
    end
  end

  def retry_cleanup(conn, %{uid: uid}) do
    with :ok <- ConsolePolicy.authorize(conn, "principal:#{uid}", "update"),
         {:ok, %{type: :human} = principal} <- Principals.get_principal(uid),
         :ok <- WorkCleanup.enqueue_in_tx(uid, principal.access_version) do
      access(conn, uid)
    else
      {:ok, _} -> error(conn, :not_human)
      {:error, reason} -> error(conn, reason)
    end
  end

  def unresolved_work(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "principals", "update") do
      json(conn, Ankole.JSON.plain(%{work: WorkAccess.list_unresolved()}))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def classify_work(conn, _params) do
    body = conn.body_params
    human_uid = if body.authorization_kind == "human", do: Map.get(body, :human_uid), else: nil

    with :ok <- ConsolePolicy.authorize(conn, "principals", "update"),
         true <-
           body.authorization_kind == "service" or (is_binary(human_uid) and human_uid != ""),
         {:ok, _} <- WorkAccess.classify(body.kind, body.id, human_uid, actor(conn), body.reason) do
      json(conn, Ankole.JSON.plain(%{work: WorkAccess.list_unresolved()}))
    else
      false -> error(conn, :human_uid_required)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp access(conn, uid) do
    with {:ok, %{type: :human} = principal} <- Principals.get_principal(uid),
         {:ok, review} <- AuthZ.restoration_review(uid) do
      jobs =
        Repo.all(
          from j in Oban.Job,
            where:
              j.worker == "Ankole.Principals.WorkCleanup" and
                fragment("?->>'human_uid' = ?", j.args, ^uid),
            order_by: [desc: j.id],
            limit: 20
        )

      json(
        conn,
        Ankole.JSON.plain(%{
          uid: uid,
          status: principal.status,
          access_version: principal.access_version,
          access_revoked_at: principal.access_revoked_at,
          permission_review: review,
          restrictions:
            Enum.map(
              HumanAccess.restrictions(uid),
              &Map.take(&1, [
                :id,
                :source,
                :reason,
                :provider_time,
                :recovery_verified_at,
                :cleared_at,
                :inserted_at
              ])
            ),
          history:
            Enum.map(
              HumanAccess.history(uid),
              &Map.take(&1, [
                :id,
                :source,
                :action,
                :reason,
                :actor_uid,
                :access_version,
                :details,
                :inserted_at
              ])
            ),
          work: WorkAccess.list_for_human(uid),
          cleanup_jobs:
            Enum.map(
              jobs,
              &Map.take(&1, [
                :id,
                :state,
                :attempt,
                :max_attempts,
                :scheduled_at,
                :completed_at,
                :discarded_at
              ])
            )
        })
      )
    else
      {:ok, _} -> error(conn, :not_human)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp actor(conn), do: conn.assigns.current_principal_uid
  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "Access denied")

  defp error(conn, :not_found),
    do: ConsoleErrors.render(conn, 404, "not_found", "Human or restriction was not found")

  defp error(conn, reason) when is_atom(reason),
    do:
      ConsoleErrors.render(
        conn,
        409,
        Atom.to_string(reason),
        "Access change could not be applied: #{reason}"
      )

  defp error(conn, %Ecto.Changeset{} = changeset),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "validation_failed",
        "The access change is invalid",
        ConsoleErrors.changeset_details(changeset)
      )

  defp error(conn, reason),
    do: ConsoleErrors.unexpected(conn, "principals.access_api.unexpected_error", reason)
end
