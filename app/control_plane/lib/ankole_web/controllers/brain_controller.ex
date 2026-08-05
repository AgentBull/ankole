defmodule AnkoleWeb.BrainController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc "Console REST API for human supervision of Brain knowledge."

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Brain
  alias Ankole.WorkerFiles
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
      schema: %Schema{type: :string, format: :"date-time"},
      required: false
    ],
    inserted_before: [
      in: :query,
      schema: %Schema{type: :string, format: :"date-time"},
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
            schema: %Schema{type: :string, format: :"date-time"},
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
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, cursor} <- page_cursor(params),
         {:ok, page} <- Brain.list_entries(owner_uid, entry_list_opts(params, cursor)) do
      json(conn, %{entries: page.entries, next_cursor: encode_cursor(page.next_cursor)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         {:ok, entry_id} <- required_text(params, "id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- Brain.open_entry(owner_uid, entry_id) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def apply_operations(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, operations} <- operations(conn.body_params),
         {:ok, result} <-
           Brain.apply_human_operations(
             owner_uid,
             operations,
             actor_uid,
             store_key: optional_text(params, "store"),
             reason: optional_text(conn.body_params, "reason")
           ) do
      json(conn, json_safe(result))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def audit_log(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         {:ok, entry_id} <- required_text(params, "id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- audit_page(owner_uid, params, entry_id) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def audit_index(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, payload} <- audit_page(owner_uid, params, nil) do
      json(conn, payload)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def source(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         {:ok, document_id} <- required_text(params, "document_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, source} <- Brain.resolve_source(owner_uid, document_id) do
      json(conn, %{source: source})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def source_index(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, sources} <- Brain.list_sources(owner_uid) do
      json(conn, %{sources: sources})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def status(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, status} <- Brain.status(owner_uid) do
      json(conn, %{memory_status: status})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def source_raw(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         {:ok, document_id} <- required_text(params, "document_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, raw} <- Brain.source_raw(owner_uid, document_id) do
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
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         {:ok, store_key} <- required_text(params, "store"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, attrs} <- source_attrs(conn.body_params || %{}),
         {:ok, material} <- Brain.capture_source(owner_uid, store_key, attrs, actor_uid) do
      conn |> put_status(:created) |> json(material)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def learn_source(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         {:ok, document_id} <- required_text(params, "document_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, source} <- Brain.learn_source(owner_uid, document_id) do
      json(conn, %{source: source})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def restore_audit(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         {:ok, audit_id} <- required_text(params, "audit_id"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, restoration} <- Brain.restore_audit(owner_uid, audit_id, actor_uid) do
      json(conn, %{restoration: json_safe(restoration)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def restore_audits(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, actor_uid} <- current_principal_uid(conn),
         {:ok, audit_ids} <- audit_ids(conn.body_params),
         {:ok, restoration} <- Brain.restore_audits(owner_uid, audit_ids, actor_uid) do
      json(conn, %{restoration: json_safe(restoration)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def run_dreaming(conn, params) do
    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "update"),
         {:ok, result} <- Brain.run_dreaming(owner_uid) do
      json(conn, %{run: json_safe(result)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def dreaming_fitness(conn, params) do
    opts =
      [
        horizon_days: param(params, "horizon_days"),
        lookback_days: param(params, "lookback_days")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    with {:ok, owner_uid} <- required_text(params, "owner_uid"),
         :ok <- ConsolePolicy.authorize(conn, brain_resource(owner_uid), "read"),
         {:ok, fitness} <- Brain.dreaming_fitness(owner_uid, opts) do
      json(conn, %{fitness: json_safe(fitness)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp current_principal_uid(%Plug.Conn{assigns: %{current_principal_uid: uid}})
       when is_binary(uid),
       do: {:ok, uid}

  defp brain_resource(owner_uid), do: "brain:#{owner_uid}"

  @author_kinds ~w(human agent dreaming)
  @server_owned_operation_keys ~w(
    owner_uid store_key author_kind author_uid actor_kind actor_uid
  )

  defp audit_page(owner_uid, params, entry_id) do
    with {:ok, cursor} <- page_cursor(params),
         {:ok, page} <- Brain.list_audit(owner_uid, audit_list_opts(params, entry_id, cursor)) do
      {:ok, %{audit_log: page.audit_log, next_cursor: encode_cursor(page.next_cursor)}}
    end
  end

  defp entry_list_opts(params, cursor) do
    author = optional_text(params, "author")

    [
      query: optional_text(params, "query"),
      type: optional_text(params, "type"),
      store_key: optional_text(params, "store"),
      author_kind: author_kind(author),
      author_uid: author_uid(author),
      updated_after: param(params, "updated"),
      cursor: cursor,
      limit: page_limit(params)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp audit_list_opts(params, entry_id, cursor) do
    actor = optional_text(params, "actor")

    [
      entry_id: entry_id,
      store_key: optional_text(params, "store"),
      action: optional_text(params, "action"),
      actor_kind: author_kind(actor),
      actor_uid: author_uid(actor),
      run_id: optional_text(params, "run_id"),
      inserted_after: param(params, "inserted_after"),
      inserted_before: param(params, "inserted_before"),
      cursor: cursor,
      limit: page_limit(params)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp author_kind("human"), do: :human
  defp author_kind("agent"), do: :agent
  defp author_kind("dreaming"), do: :dreaming
  defp author_kind(_author), do: nil

  defp author_uid(author) when is_binary(author) and author not in @author_kinds, do: author
  defp author_uid(_author), do: nil

  # CastAndValidate already rejects a non-integer or out-of-range limit, and
  # it casts the `date-time` parameters to DateTime structs before the action.
  defp page_limit(params), do: param(params, "limit") || 50

  defp page_cursor(params) do
    case optional_text(params, "cursor") do
      nil ->
        {:ok, nil}

      cursor ->
        with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
             [iso, id] <- String.split(decoded, "|", parts: 2),
             {:ok, datetime, _offset} <- DateTime.from_iso8601(iso),
             {:ok, id} <- Ecto.UUID.cast(id) do
          {:ok, {datetime, id}}
        else
          _invalid -> {:error, :invalid_page_cursor}
        end
    end
  end

  defp encode_cursor(nil), do: nil

  defp encode_cursor({datetime, id}) do
    Base.url_encode64("#{DateTime.to_iso8601(datetime)}|#{id}", padding: false)
  end

  defp operations(body) when is_map(body) do
    case param(body, "operations") do
      operations when is_list(operations) and operations != [] ->
        operations
        |> Enum.reduce_while({:ok, []}, fn
          operation, {:ok, acc} when is_map(operation) ->
            sanitized =
              operation
              |> stringify_keys()
              |> Map.drop(@server_owned_operation_keys)
              |> drop_create_nil_defaults()

            {:cont, {:ok, [sanitized | acc]}}

          _operation, _acc ->
            {:halt, {:error, :invalid_operations}}
        end)
        |> case do
          {:ok, sanitized} -> {:ok, Enum.reverse(sanitized)}
          {:error, reason} -> {:error, reason}
        end

      _value ->
        {:error, :invalid_operations}
    end
  end

  defp operations(_body), do: {:error, :invalid_operations}

  defp source_attrs(body) when is_map(body) do
    case optional_text(body, "kind") do
      "file" -> source_file_attrs(body)
      "paste" -> source_text_attrs(body)
      "url" -> source_url_attrs(body)
      _invalid -> {:error, :invalid_source_kind}
    end
  end

  defp source_attrs(_body), do: {:error, :invalid_source}

  defp source_file_attrs(body) do
    case param(body, "file") do
      %Plug.Upload{} = upload ->
        max_bytes = WorkerFiles.max_transfer_bytes()

        with {:ok, %{size: size}} <- File.stat(upload.path),
             true <- size > 0 and size <= max_bytes,
             {:ok, content} <- File.read(upload.path) do
          {:ok,
           %{
             kind: "file",
             title: optional_text(body, "title") || upload.filename,
             original_name: upload.filename,
             media_type: upload.content_type || "application/octet-stream",
             content: content
           }}
        else
          false -> {:error, {:invalid_source_file_size, max_bytes}}
          {:error, reason} -> {:error, {:source_file_read_failed, reason}}
        end

      _missing ->
        {:error, {:missing, "file"}}
    end
  end

  defp source_text_attrs(body) do
    with {:ok, title} <- required_text(body, "title"),
         {:ok, content} <- required_source_content(body, "content") do
      {:ok, %{kind: "paste", title: title, content: content}}
    end
  end

  defp source_url_attrs(body) do
    with {:ok, url} <- required_text(body, "url") do
      {:ok, %{kind: "url", title: optional_text(body, "title"), url: url}}
    end
  end

  defp required_source_content(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:missing, key}}, else: {:ok, value}

      _missing ->
        {:error, {:missing, key}}
    end
  end

  defp audit_ids(body) when is_map(body) do
    case param(body, "audit_ids") do
      ids when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &is_binary/1), do: {:ok, ids}, else: {:error, :invalid_audit_selection}

      _invalid ->
        {:error, :invalid_audit_selection}
    end
  end

  defp audit_ids(_body), do: {:error, :invalid_audit_selection}

  defp drop_create_nil_defaults(%{"operation" => operation_name} = operation)
       when operation_name in ["create_entry", :create_entry] do
    Enum.reduce(["summary", "aliases", "properties"], operation, fn key, acc ->
      if Map.get(acc, key) == nil, do: Map.delete(acc, key), else: acc
    end)
  end

  defp drop_create_nil_defaults(operation), do: operation

  defp json_safe(nil), do: nil
  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {string_key(key), json_safe(item)} end)
  end

  defp json_safe(value), do: inspect(value)

  defp stringify_keys(value) do
    Map.new(value, fn {key, item} -> {string_key(key), item} end)
  end

  defp required_text(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp optional_text(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  # Cast params carry atom keys and multipart bodies carry string keys; one
  # reader accepts both so every call site stays shape-agnostic.
  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(params, fn {candidate, value} ->
          if string_key(candidate) == key, do: {:found, value}
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: to_string(key)

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
