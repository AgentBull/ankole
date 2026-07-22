defmodule AnkoleWeb.BrainController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc "Console REST API for human supervision of Brain knowledge."

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias AnkoleWeb.BrainController.Adapter
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.BrainConsoleAPI.AuditLogResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.AuditRestorationResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.AuditRestorationsRequest
  alias AnkoleWeb.Schemas.BrainConsoleAPI.EntryListResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.EntryOperationsRequest
  alias AnkoleWeb.Schemas.BrainConsoleAPI.EntryOperationsResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.EntryResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.DreamingFitnessResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.DreamingRunResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.SourceEntryResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.SourceListResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.SourceCaptureRequest
  alias AnkoleWeb.Schemas.BrainConsoleAPI.SourceCaptureResponse
  alias AnkoleWeb.Schemas.BrainConsoleAPI.StatusResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias OpenAPISpex.Schema

  @owner_parameter [
    owner_uid: [
      in: :query,
      type: :string,
      required: true,
      description: "Principal whose Brain library is being supervised"
    ]
  ]

  @page_parameters [
    cursor: [in: :query, type: :string, required: false],
    limit: [
      in: :query,
      schema: %Schema{type: :integer, minimum: 1, maximum: 100},
      required: false
    ]
  ]

  @audit_filter_parameters [
    store: [in: :query, type: :string, required: false],
    action: [in: :query, type: :string, required: false],
    actor: [in: :query, type: :string, required: false],
    run_id: [in: :query, schema: %Schema{type: :string, format: :uuid}, required: false],
    inserted_after: [
      in: :query,
      schema: %Schema{type: :string, format: :date_time},
      required: false
    ],
    inserted_before: [
      in: :query,
      schema: %Schema{type: :string, format: :date_time},
      required: false
    ]
  ]

  tags(["Brain"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List Brain entries for one owner",
    parameters:
      @owner_parameter ++
        [
          type: [in: :query, type: :string, required: false],
          query: [in: :query, type: :string, required: false],
          store: [in: :query, type: :string, required: false],
          author: [
            in: :query,
            type: :string,
            required: false,
            description: "An author kind (human/agent/dreaming) or exact author UID"
          ],
          updated: [
            in: :query,
            type: :string,
            required: false,
            description: "ISO-8601 lower bound for entry updated_at"
          ]
        ] ++ @page_parameters,
    responses: [
      ok: {"Brain entries", "application/json", EntryListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Open one current Brain entry projection",
    parameters: @owner_parameter ++ [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Brain entry", "application/json", EntryResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:apply_operations,
    summary: "Apply structured human Brain entry operations",
    parameters:
      @owner_parameter ++
        [
          store: [
            in: :query,
            type: :string,
            required: false,
            description: "Required for create-only batches; existing entries derive their store"
          ]
        ],
    request_body:
      {"Structured Brain operations", "application/json", EntryOperationsRequest, required: true},
    responses: [
      ok: {"Operation results", "application/json", EntryOperationsResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Optimistic lock conflict", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid operations", "application/json", ErrorEnvelope}
    ]
  )

  operation(:audit_log,
    summary: "List the audit trail for one Brain entry",
    parameters:
      @owner_parameter ++
        [id: [in: :path, type: :string, required: true]] ++
        @audit_filter_parameters ++ @page_parameters,
    responses: [
      ok: {"Brain audit log", "application/json", AuditLogResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:audit_index,
    summary: "Preview filtered Brain audit records for supervision or batch recovery",
    parameters: @owner_parameter ++ @audit_filter_parameters ++ @page_parameters,
    responses: [
      ok: {"Brain audit log", "application/json", AuditLogResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  operation(:source,
    summary: "Resolve a Brain source inside one owner's visible stores",
    parameters: @owner_parameter ++ [document_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Brain source", "application/json", SourceEntryResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:source_index,
    summary: "List retained Brain sources for one owner",
    parameters: @owner_parameter,
    responses: [
      ok: {"Retained sources", "application/json", SourceListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:source_raw,
    summary: "Download the immutable bytes of one explicitly retained Brain source",
    parameters: @owner_parameter ++ [document_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Source bytes", "application/octet-stream", %Schema{type: :string, format: :binary}},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:create_source,
    summary: "Save manual text as knowledge or retain binary source bytes",
    parameters:
      @owner_parameter ++
        [
          store: [
            in: :query,
            type: :string,
            required: true,
            description: "Exact Brain store that may cite this source"
          ]
        ],
    request_body: {"Source", "multipart/form-data", SourceCaptureRequest, required: true},
    responses: [
      created: {"Saved material", "application/json", SourceCaptureResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid source", "application/json", ErrorEnvelope}
    ]
  )

  operation(:learn_source,
    summary: "Start one Agent learning run for an already retained source",
    parameters: @owner_parameter ++ [document_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Learning run queued", "application/json", SourceEntryResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"No worker is ready", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Learning could not start", "application/json", ErrorEnvelope}
    ]
  )

  operation(:status,
    summary: "Read the single long-term memory health surface",
    parameters: @owner_parameter,
    responses: [
      ok: {"Long-term memory status", "application/json", StatusResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope}
    ]
  )

  operation(:restore_audit,
    summary: "Restore the state captured by one Brain audit record",
    parameters: @owner_parameter ++ [audit_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Restoration result", "application/json", AuditRestorationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Optimistic lock conflict", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Audit record cannot be restored", "application/json", ErrorEnvelope}
    ]
  )

  operation(:restore_audits,
    summary: "Atomically restore an explicit Brain audit selection",
    description:
      "The caller previews audit records first, submits their exact ids, and the server restores them newest-first in one transaction.",
    parameters: @owner_parameter,
    request_body:
      {"Exact audit selection", "application/json", AuditRestorationsRequest, required: true},
    responses: [
      ok: {"Batch restoration result", "application/json", AuditRestorationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      conflict: {"Audit selection or current state changed", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid audit selection", "application/json", ErrorEnvelope}
    ]
  )

  operation(:run_dreaming,
    summary: "Run Agent-level Brain curation now",
    description:
      "Manually starts the same Agent-only Stage B path used by the scheduled Brain curation job.",
    parameters: @owner_parameter,
    responses: [
      ok: {"Dreaming run result", "application/json", DreamingRunResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Dreaming run failed", "application/json", ErrorEnvelope}
    ]
  )

  operation(:dreaming_fitness,
    summary: "Read dreaming output survival as a selection-pressure signal",
    description:
      "Reads the audit log for the share of dreaming block writes that survived human review (no human edit or delete within the horizon), overall and per run. Writes younger than the horizon are reported as pending, not survivors.",
    parameters:
      @owner_parameter ++
        [
          horizon_days: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 90},
            required: false,
            description:
              "Days a dreaming write must survive human review to count as survived (default 7)"
          ],
          lookback_days: [
            in: :query,
            schema: %Schema{type: :integer, minimum: 1, maximum: 365},
            required: false,
            description: "How far back to read dreaming writes (default 90)"
          ]
        ],
    responses: [
      ok: {"Dreaming fitness signal", "application/json", DreamingFitnessResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.list_entries(owner_uid, params) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         {:ok, entry_id} <- Adapter.required_text(params, "id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.open_entry(owner_uid, entry_id) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def apply_operations(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, payload} <-
           Adapter.apply_operations(owner_uid, params, conn.body_params, actor_uid) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def audit_log(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         {:ok, entry_id} <- Adapter.required_text(params, "id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.list_audit(owner_uid, params, entry_id) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def audit_index(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.list_audit(owner_uid, params) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def source(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         {:ok, document_id} <- Adapter.required_text(params, "document_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.source(owner_uid, document_id) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def source_index(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.list_sources(owner_uid) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def status(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.status(owner_uid) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def source_raw(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         {:ok, document_id} <- Adapter.required_text(params, "document_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, raw} <- Adapter.source_raw(owner_uid, document_id) do
      conn
      |> put_resp_content_type(raw.media_type)
      |> put_resp_header(
        "content-disposition",
        "attachment; filename*=UTF-8''" <> URI.encode(raw.filename, &URI.char_unreserved?/1)
      )
      |> send_resp(200, raw.content)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create_source(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         {:ok, store_key} <- Adapter.required_text(params, "store"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, payload} <-
           Adapter.create_source(
             owner_uid,
             store_key,
             conn.body_params || %{},
             actor_uid
           ) do
      conn |> put_status(:created) |> json(payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def learn_source(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         {:ok, document_id} <- Adapter.required_text(params, "document_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, payload} <- Adapter.learn_source(owner_uid, document_id) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def restore_audit(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         {:ok, audit_id} <- Adapter.required_text(params, "audit_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, payload} <- Adapter.restore_audit(owner_uid, audit_id, actor_uid) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def restore_audits(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, payload} <- Adapter.restore_audits(owner_uid, conn.body_params, actor_uid) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def run_dreaming(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, payload} <- Adapter.run_dreaming(owner_uid) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def dreaming_fitness(conn, params) do
    with {:ok, owner_uid} <- Adapter.required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Adapter.dreaming_fitness(owner_uid, params) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp current_principal_uid(%Plug.Conn{assigns: %{current_principal_uid: uid}})
       when is_binary(uid),
       do: {:ok, uid}

  defp brain_resource(owner_uid), do: "brain:#{owner_uid}"

  defp error(conn, :forbidden), do: ConsoleErrors.render(conn, 403, "forbidden", "access denied")

  defp error(conn, reason)
       when reason in [:not_found, :entry_not_found, :audit_not_found] do
    ConsoleErrors.render(conn, 404, "not_found", "Brain record was not found")
  end

  defp error(conn, reason)
       when reason in [:no_ready_file_worker, :no_worker_available, :worker_not_ready] do
    ConsoleErrors.render(
      conn,
      409,
      "worker_not_ready",
      "No Agent Computer worker is ready; retry learning later"
    )
  end

  defp error(conn, {:not_found, _kind}) do
    ConsoleErrors.render(conn, 404, "not_found", "Brain record was not found")
  end

  defp error(conn, reason)
       when reason in [:stale, :stale_entry, :lock_version_mismatch, :optimistic_lock_conflict] do
    optimistic_lock_error(conn)
  end

  defp error(conn, {:stale, _details}), do: optimistic_lock_error(conn)

  defp error(conn, {:audit_restore_conflict, _details}) do
    ConsoleErrors.render(
      conn,
      409,
      "audit_restore_conflict",
      "The audited change is no longer the current state; reopen the entry before deciding"
    )
  end

  defp error(conn, :audit_selection_changed) do
    ConsoleErrors.render(
      conn,
      409,
      "audit_selection_changed",
      "The selected audit records changed; preview and select them again"
    )
  end

  defp error(conn, {:missing, key}) do
    ConsoleErrors.render(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, {:invalid_datetime, key}) do
    ConsoleErrors.render(conn, 422, "validation_failed", "#{key} must be an ISO-8601 datetime")
  end

  defp error(conn, {:invalid_integer, key}) do
    ConsoleErrors.render(conn, 422, "validation_failed", "#{key} must be a positive integer")
  end

  defp error(conn, reason) when reason in [:invalid_horizon_days, :invalid_lookback_days] do
    ConsoleErrors.render(conn, 422, "validation_failed", "#{reason} is out of range")
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    ConsoleErrors.render(
      conn,
      422,
      "validation_failed",
      "request validation failed",
      ConsoleErrors.changeset_details(changeset)
    )
  end

  defp error(conn, reason) do
    ConsoleErrors.render(conn, 422, "invalid_brain_operation", "Brain request is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp optimistic_lock_error(conn) do
    ConsoleErrors.render(
      conn,
      409,
      "optimistic_lock_conflict",
      "Brain content changed; reload before applying this operation"
    )
  end
end
