defmodule AnkoleWeb.DirectoryAccessController do
  @moduledoc "Console review of provider directory evidence."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias Ankole.IdentityProviders.DirectoryAccess
  alias AnkoleWeb.{ConsoleErrors, ConsolePolicy}
  alias AnkoleWeb.Schemas.HumanAccessAPI
  tags(["Identity Providers"])
  security([%{"consoleBearer" => []}])
  plug OpenApiSpex.Plug.CastAndValidate, render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:show,
    summary: "Read directory evidence and unresolved events",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Directory evidence", "application/json", HumanAccessAPI.DirectoryAccessResponse}
    ]
  )

  operation(:approve,
    summary: "Approve a current directory snapshot and its removals",
    parameters: [provider_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Snapshot review", "application/json", HumanAccessAPI.DirectoryApproveRequest,
       required: true},
    responses: [
      ok: {"Directory evidence", "application/json", HumanAccessAPI.DirectoryAccessResponse}
    ]
  )

  operation(:review_event,
    summary: "Retry or dismiss an unresolved provider event",
    parameters: [
      provider_id: [in: :path, type: :string, required: true],
      event_id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true
      ]
    ],
    request_body:
      {"Event review", "application/json", HumanAccessAPI.DirectoryEventReviewRequest,
       required: true},
    responses: [
      ok: {"Directory evidence", "application/json", HumanAccessAPI.DirectoryAccessResponse}
    ]
  )

  def show(conn, %{provider_id: id}) do
    with :ok <- ConsolePolicy.authorize(conn, "identity_provider:#{id}", "read") do
      state(conn, id)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def approve(conn, %{provider_id: id}) do
    body = conn.body_params

    with :ok <- ConsolePolicy.authorize(conn, "identity_provider:#{id}", "update"),
         {:ok, _} <-
           DirectoryAccess.approve_snapshot(
             id,
             body.snapshot_fingerprint,
             conn.assigns.current_principal_uid,
             body.reason,
             body.confirm_removals
           ) do
      state(conn, id)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def review_event(conn, %{provider_id: id, event_id: event_id}) do
    body = conn.body_params
    action = if body.action == "retry", do: :retry, else: :dismiss

    with :ok <- ConsolePolicy.authorize(conn, "identity_provider:#{id}", "update"),
         %{provider_id: ^id} <- Ankole.Repo.get(Ankole.IdentityProviders.DirectoryEvent, event_id),
         result when result == :ok or elem(result, 0) == :ok <-
           DirectoryAccess.review_event(
             event_id,
             conn.assigns.current_principal_uid,
             body.reason,
             action
           ) do
      state(conn, id)
    else
      nil -> error(conn, :not_found)
      %{provider_id: _} -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp state(conn, id) do
    snapshot =
      case DirectoryAccess.state(id) do
        nil ->
          nil

        value ->
          Map.take(value, [
            :provider_id,
            :status,
            :revision,
            :scope_fingerprint,
            :snapshot_fingerprint,
            :approved_scope_fingerprint,
            :member_uids,
            :missing_uids,
            :last_started_at,
            :last_success_at,
            :last_error,
            :reviewed_by,
            :reviewed_at,
            :review_reason
          ])
      end

    events =
      Enum.map(
        DirectoryAccess.events(id),
        &Map.take(&1, [
          :id,
          :event_id,
          :event_type,
          :external_ids,
          :reason,
          :provider_time,
          :status,
          :last_error,
          :processed_at,
          :reviewed_by,
          :review_reason,
          :inserted_at
        ])
      )

    json(conn, Ankole.JSON.plain(%{snapshot: snapshot, events: events}))
  end

  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "Access denied")

  defp error(conn, :not_found),
    do: ConsoleErrors.render(conn, 404, "not_found", "Directory event was not found")

  defp error(conn, reason) when is_atom(reason),
    do:
      ConsoleErrors.render(
        conn,
        409,
        Atom.to_string(reason),
        "Review the current directory evidence and try again"
      )

  defp error(conn, reason),
    do:
      ConsoleErrors.unexpected(conn, "identity_providers.directory_api.unexpected_error", reason)
end
