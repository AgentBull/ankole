defmodule Ankole.Kernel do
  @moduledoc """
  Native kernel helpers loaded by the Elixir control plane.
  """

  # A dependency compiles with `Mix.env() == :prod`, so the build path also
  # names the environment.
  @build_env (cond do
                Mix.env() == :test or Path.basename(Mix.Project.build_path()) == "test" -> :test
                Mix.env() == :dev or Path.basename(Mix.Project.build_path()) == "dev" -> :dev
                true -> :prod
              end)
  @rustler_mode if(Mix.env() == :prod, do: :release, else: :debug)
  @rustler_features if(@build_env == :test, do: ["nif", "test-ca"], else: ["nif"])
  # Dev and test builds share `app/kernel/priv` through `_build` symlinks.
  # Test builds enable `test-ca`. Thus each of them loads its own NIF file.
  @rustler_load_path (case @build_env do
                        :prod -> "priv/native/ankole_kernel"
                        env -> "priv/native/ankole_kernel_#{env}"
                      end)

  # A local variable, not an attribute: only the branch that finds sccache
  # reads it, and an unread attribute warns on hosts without sccache.
  sccache_remote_env_keys = ~w(
    SCCACHE_BUCKET
    SCCACHE_REDIS
    SCCACHE_REDIS_ENDPOINT
    SCCACHE_MEMCACHED
    SCCACHE_MEMCACHED_ENDPOINT
    SCCACHE_GCS_BUCKET
    SCCACHE_AZURE_CONNECTION_STRING
    SCCACHE_AZURE_BLOB_CONTAINER
    SCCACHE_WEBDAV_ENDPOINT
    SCCACHE_GHA_ENABLED
    SCCACHE_S3_KEY_PREFIX
  )

  @rustler_env (
                 sccache_mode =
                   case System.get_env("ANKOLE_SCCACHE", "")
                        |> String.trim()
                        |> String.downcase() do
                     value when value in ["", "auto"] ->
                       :auto

                     value when value in ["1", "true"] ->
                       :enabled

                     value when value in ["0", "false"] ->
                       :disabled

                     other ->
                       raise ArgumentError,
                             "Invalid ANKOLE_SCCACHE value #{inspect(other)}; expected 0, 1, true, false, or auto"
                   end

                 cond do
                   sccache_mode == :disabled ->
                     []

                   System.get_env("RUSTC_WRAPPER") not in [nil, ""] ->
                     []

                   sccache = System.find_executable("sccache") ->
                     [
                       {"RUSTC_WRAPPER", sccache},
                       {"CMAKE_C_COMPILER_LAUNCHER",
                        case System.get_env("CMAKE_C_COMPILER_LAUNCHER") do
                          value when value in [nil, ""] -> sccache
                          value -> value
                        end},
                       {"CMAKE_CXX_COMPILER_LAUNCHER",
                        case System.get_env("CMAKE_CXX_COMPILER_LAUNCHER") do
                          value when value in [nil, ""] -> sccache
                          value -> value
                        end},
                       {"SCCACHE_CACHE_SIZE",
                        case System.get_env("SCCACHE_CACHE_SIZE") do
                          value when value in [nil, ""] -> "20G"
                          value -> value
                        end}
                       | Enum.map(sccache_remote_env_keys, &{&1, nil})
                     ]

                   sccache_mode == :enabled ->
                     Mix.shell().info(
                       "WARN: ANKOLE_SCCACHE=1 is set, but sccache is not on PATH; continuing with standard Cargo."
                     )

                     []

                   true ->
                     []
                 end
               )

  Mix.shell().info("Building Ankole.Kernel NIF in #{@rustler_mode} mode")

  use Rustler,
    otp_app: :ankole_kernel,
    crate: "ankole_kernel",
    # Rustler compares this path verbatim when excluding target artifacts from
    # Elixir external resources, so keep it absolute instead of using `.`.
    path: Path.expand("../..", __DIR__),
    default_features: false,
    features: @rustler_features,
    load_from: {:ankole_kernel, @rustler_load_path},
    mode: @rustler_mode,
    env: @rustler_env

  # Rustler always writes `priv/native/ankole_kernel`. Copy it to the
  # environment-specific name. Remove the old file first, because a running VM
  # can have it loaded.
  if @build_env != :prod do
    for source <- Path.wildcard("priv/native/ankole_kernel.{so,dll}") do
      target = @rustler_load_path <> Path.extname(source)
      File.rm(target)
      File.cp!(source, target)
    end

    Mix.Project.build_structure()
  end

  # The Cargo root also contains Mix and Bun outputs. Rustler lists those as
  # external resources, but they are not inputs to the native library.
  resources = Module.get_attribute(__MODULE__, :external_resource)
  Module.delete_attribute(__MODULE__, :external_resource)

  for resource <- resources,
      root = resource |> Path.relative_to(Path.expand("../..", __DIR__)) |> Path.split() |> hd(),
      root not in ~w(_build deps node_modules priv target),
      Path.extname(resource) != ".node" do
    @external_resource resource
  end

  @type error_reason :: String.t()

  @doc "Decodes an image and returns a WebP data URL within the model's byte and dimension limits."
  @spec model_image_url(binary()) :: {:ok, String.t()} | {:error, term()}
  def model_image_url(bytes) when is_binary(bytes) do
    case normalize_model_image_nif(bytes) do
      output when is_binary(output) -> {:ok, "data:image/webp;base64," <> Base.encode64(output)}
      {:error, _reason} = error -> error
    end
  end

  @spec normalize_model_image_nif(binary()) :: binary() | {:error, String.t()}
  defp normalize_model_image_nif(_bytes), do: :erlang.nif_error(:nif_not_loaded)
  @type result(value) :: value | {:error, error_reason()}
  @type extra_context :: String.t() | nil
  @type authz_snapshot :: map()
  @type authz_decision :: map()
  @type signals_filter_context :: map()
  @type jwt_claims :: map()
  @type jwt_header :: map()
  @type jwt_validation :: map()
  @type universal_ai_client_stream :: reference()
  @type object_store :: reference()
  @type reciprocal_rank_fusion_result :: %{
          required(String.t()) => String.t() | float()
        }
  @type web_url_facts :: %{
          scheme: String.t(),
          host: String.t() | nil,
          host_class: :metadata | :private | :public | nil
        }

  @doc """
  Decrypts a compact AEAD token produced by `aead_encrypt/2`.

  The plaintext is returned as a binary so encrypted values can contain arbitrary
  bytes, not only UTF-8 text.
  """
  @spec aead_decrypt(String.t(), String.t()) :: result(binary())
  def aead_decrypt(_ciphertext, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encrypts a binary payload with the shared kernel AEAD format.

  The returned string is safe to copy through URLs, environment variables, and
  config files because it uses padding-free base64url segments.
  """
  @spec aead_encrypt(binary(), String.t()) :: result(String.t())
  def aead_encrypt(_plaintext, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Encodes one Drive node name, preserving the virtual type suffix."
  def vfs_name(name, kind, id), do: vfs_name_nif(name, to_string(kind), id)
  def vfs_decode_name(name), do: vfs_decode_name_nif(name)
  def vfs_range(range, size), do: vfs_range_nif(range, size)
  def vfs_xml_request(source, method), do: vfs_xml_request_nif(source, method)
  def vfs_multistatus(entries), do: vfs_multistatus_nif(Torque.encode!(entries))

  def vfs_record_patch(source),
    do: source |> Torque.encode!() |> vfs_record_patch_nif() |> decode_vfs_json()

  def vfs_pipeline(parts),
    do: parts |> Torque.encode!() |> vfs_pipeline_nif() |> decode_vfs_json()

  def vfs_export_chunk(path, format, columns, rows, first, last),
    do:
      vfs_export_chunk_nif(
        path,
        format,
        Torque.encode!(columns),
        Torque.encode!(rows),
        first,
        last
      )

  def vfs_import_chunk(path, format, offset),
    do: path |> vfs_import_chunk_nif(format, offset) |> decode_vfs_json()

  defp decode_vfs_json(json) when is_binary(json), do: Torque.decode(json)
  defp decode_vfs_json(error), do: error

  def vfs_import_id(tenant, table, request, millis, row),
    do: vfs_import_id_nif(tenant, table, request, millis, row)

  def vfs_document_export(source) do
    case vfs_document_export_nif(source) do
      {:error, _} = error -> error
      markdown -> {:ok, markdown}
    end
  end

  def vfs_document_reconcile(source, markdown),
    do: source |> vfs_document_reconcile_nif(markdown) |> decode_page_result()

  def vfs_merge_knowledge(base, base_meta, current, current_meta, edited, edited_meta) do
    case vfs_merge_knowledge_nif(
           base,
           Torque.encode!(base_meta),
           current,
           Torque.encode!(current_meta),
           edited,
           Torque.encode!(edited_meta)
         )
         |> decode_json_result() do
      {:error, _} = error -> error
      result -> {:ok, %{xml: result["xml"], metadata: result["metadata"]}}
    end
  end

  defp vfs_merge_knowledge_nif(_base, _base_meta, _current, _current_meta, _edited, _edited_meta),
    do: :erlang.nif_error(:nif_not_loaded)

  def vfs_fingerprint(source), do: vfs_fingerprint_nif(source)

  def page_content_empty(xml), do: page_content_empty_nif(xml)
  defp page_content_empty_nif(_xml), do: :erlang.nif_error(:nif_not_loaded)

  def vfs_projection(kind, xml, metadata \\ %{}) do
    exported =
      if kind == :knowledge, do: knowledge_export(xml, metadata), else: vfs_document_export(xml)

    with {:ok, markdown} <- exported,
         empty when is_boolean(empty) <- page_content_empty(xml) do
      {:ok,
       %{
         vfs_md_size: byte_size(markdown),
         vfs_md_blake3: vfs_fingerprint(markdown),
         vfs_content_empty:
           empty and (kind != :knowledge or map_size(Map.drop(metadata, ["extract_facts"])) == 0)
       }}
    end
  end

  defp vfs_name_nif(_name, _kind, _id), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_decode_name_nif(_name), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_range_nif(_range, _size), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_xml_request_nif(_source, _method), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_multistatus_nif(_entries), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_record_patch_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_pipeline_nif(_parts), do: :erlang.nif_error(:nif_not_loaded)

  defp vfs_export_chunk_nif(_path, _format, _columns, _rows, _first, _last),
    do: :erlang.nif_error(:nif_not_loaded)

  defp vfs_import_chunk_nif(_path, _format, _offset), do: :erlang.nif_error(:nif_not_loaded)

  defp vfs_import_id_nif(_tenant, _table, _request, _millis, _row),
    do: :erlang.nif_error(:nif_not_loaded)

  defp vfs_document_export_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_document_reconcile_nif(_source, _markdown), do: :erlang.nif_error(:nif_not_loaded)
  defp vfs_fingerprint_nif(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Parses an OKF document into business metadata and canonical knowledge page XML."
  def knowledge_parse(source) when is_binary(source) do
    case source |> knowledge_parse_nif() |> decode_json_result() do
      {:error, _} = error ->
        error

      result ->
        {:ok,
         %{xml: result["xml"], plain_text: result["plain_text"], metadata: result["metadata"]}}
    end
  end

  @doc "Validates the Markdown-representable knowledge page vocabulary."
  def knowledge_validate(source) when is_binary(source),
    do: source |> knowledge_validate_nif() |> decode_page_result()

  @doc "Serializes business metadata and knowledge XML as deterministic OKF Markdown."
  def knowledge_export(source, metadata) when is_binary(source) and is_map(metadata) do
    case knowledge_export_nif(source, Torque.encode!(metadata)) do
      {:error, _} = error -> error
      markdown -> {:ok, markdown}
    end
  end

  @doc "Reads the knowledge introduction and H2 outline; callers append authorized child summaries."
  def knowledge_overview(source, metadata) when is_binary(source) and is_map(metadata) do
    case knowledge_overview_nif(source, Torque.encode!(metadata)) do
      {:error, _} = error -> error
      markdown -> {:ok, markdown}
    end
  end

  defp knowledge_parse_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp knowledge_validate_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp knowledge_export_nif(_source, _metadata), do: :erlang.nif_error(:nif_not_loaded)
  defp knowledge_overview_nif(_source, _metadata), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Validates page XML and derives its canonical source and search text."
  @spec page_validate(String.t()) :: {:ok, map()} | {:error, String.t()}
  def page_validate(source) when is_binary(source) do
    source |> page_validate_nif() |> decode_page_result()
  end

  @doc "Extracts NFKC-normalized search text and heading byte spans from page XML."
  @spec page_sections(String.t()) ::
          {:ok,
           %{
             plain_text: String.t(),
             sections: [
               %{level: pos_integer(), heading: String.t(), start_byte: non_neg_integer()}
             ]
           }}
          | {:error, String.t()}
  def page_sections(source) when is_binary(source) do
    case page_sections_nif(source) do
      {:error, _reason} = error ->
        error

      {plain_text, sections} ->
        {:ok,
         %{
           plain_text: plain_text,
           sections:
             Enum.map(sections, fn {level, heading, start_byte} ->
               %{level: level, heading: heading, start_byte: start_byte}
             end)
         }}
    end
  end

  @doc "Rewrites Principal mention targets through the canonical page XML codec."
  def page_rename_principal(source, old, new),
    do: source |> page_rename_principal_nif(old, new) |> decode_page_result()

  @doc "Applies one prepared Wordgard ChangeSet through the page XML conversion chain."
  @spec page_apply(String.t(), list()) :: {:ok, map()} | {:error, String.t()}
  def page_apply(source, changes) when is_binary(source) and is_list(changes) do
    source |> page_apply_nif(Ankole.Kernel.JSON.encode!(changes)) |> decode_page_result()
  end

  @doc "Computes a structural and UTF-16 ChangeSet between canonical page documents."
  @spec page_diff(String.t(), String.t()) :: {:ok, list()} | {:error, String.t()}
  def page_diff(old, new) when is_binary(old) and is_binary(new) do
    case page_diff_nif(old, new) do
      {:error, _} = error -> error
      json -> Ankole.Kernel.JSON.decode(json)
    end
  end

  @doc "Computes the single-retain identity ChangeSet for a normalized page document."
  @spec page_identity_changes(String.t()) :: {:ok, [pos_integer()]} | {:error, String.t()}
  def page_identity_changes(source) when is_binary(source) do
    case page_identity_changes_nif(source) do
      {:error, _} = error -> error
      json -> Torque.decode(json)
    end
  end

  @doc "Reads native comment IDs and a document copy without annotation marks."
  def page_comment_info(source) when is_binary(source) do
    case page_comment_info_nif(source) do
      {:error, _} = error ->
        error

      json ->
        with {:ok, %{"ids" => ids, "stripped_xml" => xml}} <- Torque.decode(json),
             do: {:ok, %{ids: ids, stripped_xml: xml}}
    end
  end

  @doc "Moves one comment mark to a document range and returns its quoted text."
  def page_comment_annotate(source, id, from, to)
      when is_binary(source) and is_binary(id) and is_integer(from) and from >= 0 and
             is_integer(to) and to >= from do
    case page_comment_annotate_nif(source, id, from, to) do
      {:error, _} = error -> error
      {xml, plain_text, quote} -> {:ok, %{xml: xml, plain_text: plain_text, quote: quote}}
    end
  end

  @doc "Removes one comment's native marks while preserving document content."
  def page_comment_remove(source, id) when is_binary(source) and is_binary(id),
    do: source |> page_comment_remove_nif(id) |> decode_page_result()

  @doc "Carries current comment marks through a content diff without copying historical marks."
  def page_restore_comments(current, target) when is_binary(current) and is_binary(target),
    do: current |> page_restore_comments_nif(target) |> decode_page_result()

  defp page_comment_info_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp page_comment_annotate_nif(_source, _id, _from, _to), do: :erlang.nif_error(:nif_not_loaded)
  defp page_comment_remove_nif(_source, _id), do: :erlang.nif_error(:nif_not_loaded)
  defp page_restore_comments_nif(_current, _target), do: :erlang.nif_error(:nif_not_loaded)

  defp page_diff_nif(_old, _new), do: :erlang.nif_error(:nif_not_loaded)
  defp page_identity_changes_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp page_validate_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp page_sections_nif(_source), do: :erlang.nif_error(:nif_not_loaded)
  defp page_rename_principal_nif(_source, _old, _new), do: :erlang.nif_error(:nif_not_loaded)
  defp page_apply_nif(_source, _changes), do: :erlang.nif_error(:nif_not_loaded)

  defp decode_page_result({:error, _reason} = error), do: error

  defp decode_page_result({xml, plain_text}), do: {:ok, %{xml: xml, plain_text: plain_text}}

  @typedoc "An immutable spreadsheet version held by the kernel. Applying an operation returns a new one."
  @type spreadsheet :: reference()
  @type spreadsheet_conflict ::
          :target_deleted
          | :overlapping_structural_edit
          | :sheet_deleted
          | :concurrent_sort_or_merge
  @type spreadsheet_export :: %{xlsx_bytes: binary(), plain_text: String.t(), metadata: map()}

  @doc """
  Creates a workbook with one empty sheet whose `sheet_id` is 1, and returns it with its `.xlsx`
  bytes, search text, and metadata.
  """
  @spec spreadsheet_create_blank(String.t()) ::
          {:ok,
           %{
             doc_ref: spreadsheet(),
             xlsx_bytes: binary(),
             plain_text: String.t(),
             metadata: map()
           }}
          | {:error, error_reason()}
  def spreadsheet_create_blank(title) when is_binary(title) do
    case spreadsheet_create_blank_nif(title) do
      {:error, _reason} = error ->
        error

      {doc_ref, xlsx_bytes, plain_text, metadata} ->
        {:ok,
         %{
           doc_ref: doc_ref,
           xlsx_bytes: xlsx_bytes,
           plain_text: plain_text,
           metadata: Torque.decode!(metadata)
         }}
    end
  end

  @doc """
  Reads `.xlsx` bytes and replays the committed operations not yet compacted into them, in
  revision order.
  """
  @spec spreadsheet_open(binary(), [map()]) ::
          {:ok, %{doc_ref: spreadsheet(), plain_text: String.t(), metadata: map()}}
          | {:error, error_reason()}
  def spreadsheet_open(xlsx_bytes, tail_ops) when is_binary(xlsx_bytes) and is_list(tail_ops) do
    case spreadsheet_open_nif(xlsx_bytes, Torque.encode!(tail_ops)) do
      {:error, _reason} = error ->
        error

      {doc_ref, plain_text, metadata} ->
        {:ok, %{doc_ref: doc_ref, plain_text: plain_text, metadata: Torque.decode!(metadata)}}
    end
  end

  @doc """
  Rebases `incoming_op` over `prior_ops` (the operations committed after the author's base
  revision, in revision order) and applies it to `doc_ref`, which must be the latest revision.

  Returns the new document with the committed operation and its structural edit, or
  `{:conflict, reason}` when the rebase would have to guess. `doc_ref` stays valid either way.
  """
  @spec spreadsheet_apply(spreadsheet(), map(), [map()]) ::
          {:ok, %{doc_ref: spreadsheet(), committed_op: map(), structural_edit: map() | nil}}
          | {:conflict, spreadsheet_conflict()}
          | {:error, error_reason()}
  def spreadsheet_apply(doc_ref, incoming_op, prior_ops)
      when is_reference(doc_ref) and is_map(incoming_op) and is_list(prior_ops) do
    case spreadsheet_apply_nif(doc_ref, Torque.encode!(incoming_op), Torque.encode!(prior_ops)) do
      {:ok, {doc_ref, committed_op, structural_edit}} ->
        {:ok,
         %{
           doc_ref: doc_ref,
           committed_op: Torque.decode!(committed_op),
           structural_edit: structural_edit && Torque.decode!(structural_edit)
         }}

      {:conflict, _reason} = conflict ->
        conflict

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Serializes a spreadsheet as `.xlsx` with its search text and metadata."
  @spec spreadsheet_export_xlsx(spreadsheet()) ::
          {:ok, spreadsheet_export()} | {:error, error_reason()}
  def spreadsheet_export_xlsx(doc_ref) when is_reference(doc_ref) do
    case spreadsheet_export_xlsx_nif(doc_ref) do
      {:error, _reason} = error ->
        error

      {xlsx_bytes, plain_text, metadata} ->
        {:ok,
         %{xlsx_bytes: xlsx_bytes, plain_text: plain_text, metadata: Torque.decode!(metadata)}}
    end
  end

  defp spreadsheet_create_blank_nif(_title), do: :erlang.nif_error(:nif_not_loaded)
  defp spreadsheet_open_nif(_xlsx_bytes, _tail_ops), do: :erlang.nif_error(:nif_not_loaded)

  defp spreadsheet_apply_nif(_doc_ref, _incoming_op, _prior_ops),
    do: :erlang.nif_error(:nif_not_loaded)

  defp spreadsheet_export_xlsx_nif(_doc_ref), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns zero-based byte offsets and lengths for original CommonMark code, with delimiters."
  @spec markdown_code_ranges(String.t()) :: [{non_neg_integer(), non_neg_integer()}]
  def markdown_code_ranges(source) when is_binary(source) do
    markdown_code_ranges_nif(source)
  end

  @doc false
  @spec markdown_code_ranges_nif(String.t()) :: [{non_neg_integer(), non_neg_integer()}]
  defp markdown_code_ranges_nif(_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Repairs common model-emitted Markdown defects outside code, math, links, HTML, and wikilinks.
  """
  @spec repair_generated_markdown(String.t()) :: String.t()
  def repair_generated_markdown(source) when is_binary(source) do
    markdown_repair_generated_nif(source)
  end

  @doc false
  @spec markdown_repair_generated_nif(String.t()) :: String.t()
  defp markdown_repair_generated_nif(_source), do: :erlang.nif_error(:nif_not_loaded)

  @type sql_dialect :: :postgres | :mysql | :clickhouse | :generic
  @type sql_inspection :: %{required(String.t()) => term()}

  @doc """
  Parses one read-only SQL query and returns the facts that the caller needs to
  check it before execution. The function does no I/O.

  The kernel accepts exactly one `SELECT` or `WITH` query. It rejects the input
  with one of these error codes:

    * `"empty"` - the input contains no statement.
    * `"parse_error"` - the dialect cannot parse the input, the input is not
      UTF-8, or the input is larger than 1 MiB.
    * `"multiple_statements"` - the input contains more than one statement.
    * `"not_read_only"` - the input is DML, DDL, `SELECT INTO`, a CTE that
      modifies data, or another statement that is not a query.
    * `"locking_clause"` - the query uses `FOR UPDATE`, `FOR SHARE`, or
      `LOCK IN SHARE MODE`.
    * `"side_effect_function"` - the query calls a built-in function of the
      dialect that has effects outside the query result, anywhere in the
      statement, including table functions and `LATERAL` calls. The kernel
      matches the last part of the function name case-insensitively, so a
      schema-qualified call also fails, and the message names the function.
      PostgreSQL covers notifications, advisory locks, backend signals,
      configuration and WAL control, replication slots and origins, statistics
      resets, `set_config`, sequences, large-object writes, server-file writes,
      `dblink`, and `pg_sleep`. MySQL covers named locks, `SLEEP`,
      `BENCHMARK`, `LOAD_FILE`, and replication waits. ClickHouse covers
      `sleep`, `sleepEachRow`, and functions that reach files, processes, or
      external systems, such as `url`, `remote`, `s3`, and `executable`. The
      generic dialect rejects the union of these lists.

  The check is syntactic. It cannot see what a user-defined function does, so
  the caller also runs the query in a read-only session, and the database role
  of the connection decides which other functions the query may execute.

  The success map has these string keys:

    * `"kind"` - `"with"` when the outermost query has a `WITH` clause,
      otherwise `"select"`.
    * `"tables"` - each referenced base table, also inside CTEs and subqueries,
      as `%{"catalog", "schema", "name"}`. CTE names and table functions are
      not tables. Names keep the case in which the query writes them.
    * `"columns"` - each column reference as `%{"table", "name"}`, where
      `"table"` is the qualifier as written or `nil`. Output aliases that
      `ORDER BY` or `GROUP BY` refers to also appear here.
    * `"aggregates"` - lower-case aggregate names, such as `"sum"` or
      `"count_distinct"` for `COUNT(DISTINCT ...)`. Window calls with `OVER`
      are not aggregates.
    * `"literals"` - comparisons between a column and literals in `WHERE` and
      `HAVING`, as `%{"column", "table", "operator", "values"}`. The operator
      is one of `=`, `<>`, `<`, `<=`, `>`, `>=`, `in`, `like`, or `ilike`.
      `BETWEEN` yields one `>=` and one `<=` entry. Negated forms are skipped.
    * `"joins"` - the number of `JOIN` clauses in the whole query.
    * `"group_by"` - whether any `SELECT` has `GROUP BY`.
    * `"limit"` - the outermost literal `LIMIT` or `FETCH FIRST` count, or `nil`.
    * `"fanout_risk"` - whether a `SELECT` with two or more relations applies
      a duplicate-sensitive aggregate (not `MIN`, `MAX`, or a `DISTINCT`
      aggregate) to `*`, an unqualified column, or a column of a relation that
      is not a pre-aggregated derived table or CTE. The heuristic does not read
      join keys, so it also flags safe N:1 joins.
  """
  @spec sql_inspect(String.t(), sql_dialect()) ::
          {:ok, sql_inspection()}
          | {:error, %{required(String.t()) => String.t()}}
  def sql_inspect(sql, dialect)
      when is_binary(sql) and dialect in [:postgres, :mysql, :clickhouse, :generic],
      do: sql_inspect_nif(sql, Atom.to_string(dialect))

  defp sql_inspect_nif(_sql, _dialect), do: :erlang.nif_error(:nif_not_loaded)

  @typedoc "Result of extracting searchable text and locating metadata from a file."
  @type file_extraction :: %{
          status: :ok | :skipped | :failed,
          subtype: :text | :document,
          format: String.t(),
          extractor_version: pos_integer(),
          plain_text: String.t(),
          metadata: map(),
          error: String.t() | nil
        }

  @doc "Returns the current kernel file-text extractor schema version."
  @spec file_extractor_version() :: pos_integer()
  def file_extractor_version, do: file_extractor_version_nif()

  @doc "Classifies a filename and optional MIME type into a supported file-text subtype and format."
  @spec file_classify_format(String.t(), String.t() | nil) ::
          {:ok, %{subtype: :text | :document, format: String.t()}} | :unsupported
  def file_classify_format(filename, mime_type \\ nil)
      when is_binary(filename) and (is_binary(mime_type) or is_nil(mime_type)) do
    case file_classify_format_nif(filename, mime_type) do
      {:ok, {subtype, format}} -> {:ok, %{subtype: subtype, format: format}}
      :unsupported -> :unsupported
    end
  end

  @doc "Extracts bounded NFKC-normalized search text and locating metadata from file bytes."
  @spec file_extract_text(binary(), String.t(), String.t() | nil) ::
          {:ok, file_extraction()} | {:error, error_reason()}
  def file_extract_text(bytes, filename, mime_type \\ nil)
      when is_binary(bytes) and is_binary(filename) and
             (is_binary(mime_type) or is_nil(mime_type)) do
    case file_extract_text_nif(bytes, filename, mime_type) do
      {:error, _reason} = error ->
        error

      %{
        status: status,
        subtype: subtype,
        format: format,
        extractor_version: extractor_version,
        plain_text: plain_text,
        metadata_json: metadata_json,
        error: err
      } ->
        {:ok,
         %{
           status: status,
           subtype: subtype,
           format: format,
           extractor_version: extractor_version,
           plain_text: plain_text,
           metadata: Torque.decode!(metadata_json),
           error: err
         }}
    end
  end

  defp file_extractor_version_nif, do: :erlang.nif_error(:nif_not_loaded)
  defp file_classify_format_nif(_filename, _mime_type), do: :erlang.nif_error(:nif_not_loaded)

  defp file_extract_text_nif(_bytes, _filename, _mime_type),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Authorizes one exact action on one concrete resource.

  The snapshot must contain every Principal, group, grant, resource, action, and
  request-context value the kernel needs. The native layer never loads database
  state itself.
  """
  @spec authz_authorize(authz_snapshot()) :: result(authz_decision())
  def authz_authorize(snapshot) when is_map(snapshot) do
    snapshot
    |> Torque.encode!()
    |> authz_authorize_nif()
    |> decode_json_result()
  end

  @doc """
  Authorizes every requested action against one concrete resource.
  """
  @spec authz_authorize_all(authz_snapshot()) :: result(authz_decision())
  def authz_authorize_all(snapshot) when is_map(snapshot) do
    snapshot
    |> Torque.encode!()
    |> authz_authorize_all_nif()
    |> decode_json_result()
  end

  @doc "Evaluates independent resource/action checks with one authorization snapshot."
  @spec authz_authorize_checks(map()) :: result(map())
  def authz_authorize_checks(snapshot) when is_map(snapshot) do
    snapshot
    |> Torque.encode!()
    |> authz_authorize_checks_nif()
    |> decode_json_result()
  end

  @doc "Evaluates Pod groups and conditional grants for one Principal and request context."
  @spec authz_evaluate_drive_context(map()) :: result(map())
  def authz_evaluate_drive_context(snapshot) when is_map(snapshot) do
    snapshot
    |> Torque.encode!()
    |> authz_evaluate_drive_context_nif()
    |> decode_json_result()
  end

  @spec authz_authorize_nif(String.t()) :: result(String.t())
  defp authz_authorize_nif(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  @spec authz_authorize_all_nif(String.t()) :: result(String.t())
  defp authz_authorize_all_nif(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  defp authz_authorize_checks_nif(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  defp authz_evaluate_drive_context_nif(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_open_nif(String.t(), pid(), reference()) ::
          {:ok, universal_ai_client_stream()} | {:error, map()}
  def universal_ai_client_open_nif(_encoded_spec, _owner_pid, _stream_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_read_nif(universal_ai_client_stream(), non_neg_integer()) ::
          result(:ok)
  def universal_ai_client_read_nif(_stream, _count), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_cancel_nif(universal_ai_client_stream()) :: result(:ok)
  def universal_ai_client_cancel_nif(_stream), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_model_request_nif(String.t(), pid(), reference()) ::
          :ok | {:error, map()}
  def universal_ai_client_model_request_nif(_encoded_spec, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_raw_request_nif(String.t(), pid(), reference()) ::
          :ok | {:error, map()}
  def universal_ai_client_raw_request_nif(_encoded_spec, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_open_nif(String.t()) :: {:ok, object_store()} | {:error, map()}
  def object_store_open_nif(_spec), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_write_limit_nif(object_store()) :: pos_integer()
  def object_store_write_limit_nif(_store), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_read_nif(object_store(), String.t(), pid(), reference()) ::
          :ok | {:error, map()}
  def object_store_read_nif(_store, _key, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_read_range_nif(
          object_store(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          pid(),
          reference()
        ) :: :ok | {:error, map()}
  def object_store_read_range_nif(_store, _key, _offset, _length, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_read_to_file_nif(object_store(), String.t(), String.t(), pid(), reference()) ::
          :ok | {:error, map()}
  def object_store_read_to_file_nif(_store, _key, _path, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_write_nif(object_store(), String.t(), binary(), pid(), reference()) ::
          :ok | {:error, map()}
  def object_store_write_nif(_store, _key, _bytes, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_write_from_file_nif(
          object_store(),
          String.t(),
          String.t(),
          pid(),
          reference()
        ) :: :ok | {:error, map()}
  def object_store_write_from_file_nif(_store, _key, _path, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def object_store_writer_open_nif(_store, _key, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def object_store_writer_write_nif(_writer, _bytes, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def object_store_writer_close_nif(_writer, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  def object_store_writer_abort_nif(_writer), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec object_store_delete_nif(object_store(), String.t(), pid(), reference()) ::
          :ok | {:error, map()}
  def object_store_delete_nif(_store, _key, _owner_pid, _request_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns `true` when a CEL authorization condition compiles and uses supported variables.
  """
  @spec authz_validate_condition(String.t()) :: result(boolean())
  def authz_validate_condition(_condition), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns `true` when a CEL Pod condition uses only Principal and request-context variables."
  @spec authz_validate_drive_condition(String.t()) :: result(boolean())
  def authz_validate_drive_condition(_condition), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Returns the sorted free variables of a CEL condition."
  @spec authz_condition_free_variables(String.t()) :: result([String.t()])
  def authz_condition_free_variables(_condition), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns `true` when a Signals CEL admission filter compiles.
  """
  @spec signals_validate_filter(String.t()) :: result(boolean())
  def signals_validate_filter(_filter_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluates a Signals CEL admission filter against a normalized context.

  The context must contain only the host-supplied `binding` and `signal`
  variables. The native layer does not load database or runtime state while
  evaluating the expression.
  """
  @spec signals_filter_match(String.t(), signals_filter_context()) ::
          result(boolean())
  def signals_filter_match(filter_source, context)
      when is_binary(filter_source) and is_map(context) do
    signals_filter_match_nif(filter_source, Torque.encode!(context))
  end

  @spec signals_filter_match_nif(String.t(), String.t()) :: result(boolean())
  defp signals_filter_match_nif(_filter_source, _context),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns whether a resource pattern is valid.
  """
  @spec authz_validate_resource_pattern(String.t()) :: result(boolean())
  def authz_validate_resource_pattern(_pattern), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns whether a resource pattern matches a concrete resource key.
  """
  @spec authz_match_resource_pattern(String.t(), String.t()) :: result(boolean())
  def authz_match_resource_pattern(_pattern, _resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Estimates token count with the provider-neutral `o200k_base` vocabulary.

  This is a budgeting helper only; it does not infer or select a concrete model.
  """
  @spec estimate_o200k_base_tokens(String.t()) :: non_neg_integer()
  def estimate_o200k_base_tokens(_text), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Truncates `text` at a Unicode grapheme boundary so its `o200k_base` token
  count does not exceed `budget`, trimming trailing whitespace when cut.
  """
  @spec truncate_o200k_base_tokens(String.t(), non_neg_integer()) :: result(String.t())
  def truncate_o200k_base_tokens(_text, _budget), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Chunks one single-scope Brain text using the CJK-aware recursive chunker and
  returns `{chunk_text, exact_token_count}` pairs.
  """
  @spec brain_chunk_text_with_tokens(
          String.t(),
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: result([{String.t(), non_neg_integer()}])
  def brain_chunk_text_with_tokens(
        _text,
        _chunk_size,
        _chunk_overlap,
        _max_chars,
        _max_tokens
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Combines multiple ordered result ID lists with reciprocal-rank fusion.

  Each route contributes `1 / (k + rank)` for an ID's first occurrence in that
  route. Results are ordered by descending fused score; equal scores preserve
  the IDs' first appearance order across the supplied routes.
  """
  @spec reciprocal_rank_fusion([[String.t()]], non_neg_integer()) ::
          result([reciprocal_rank_fusion_result()])
  def reciprocal_rank_fusion(ranked_lists, k \\ 60)

  def reciprocal_rank_fusion(ranked_lists, k)
      when is_list(ranked_lists) and is_integer(k) and k >= 0 do
    ranked_lists
    |> Torque.encode!()
    |> reciprocal_rank_fusion_nif(k)
    |> decode_json_result()
  end

  @spec reciprocal_rank_fusion_nif(String.t(), non_neg_integer()) :: result(String.t())
  defp reciprocal_rank_fusion_nif(_ranked_lists, _k),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes a non-cryptographic XXH3 128-bit observation fingerprint.

  This is for file observations and change detection. It is not a security
  digest and must not be used for provenance or signature checks.
  """
  @spec xxh3_128_hex(binary()) :: result(String.t())
  def xxh3_128_hex(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Derives a deterministic BLAKE3 sub-key from a seed and labeled context.

  `sub_key_id` names the logical key being derived. `extra_context` separates
  call sites that need different keys under the same logical id.
  """
  @spec derive_key(binary(), String.t(), extra_context()) :: result(String.t())
  def derive_key(key_seed, sub_key_id, extra_context \\ nil)
  def derive_key(_key_seed, _sub_key_id, _extra_context), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Signs JSON-compatible JWT claims with an RSA private key in PEM form.

  Only RS256/RS384/RS512 are accepted (default RS256). The header map accepts
  `key_id`/`kid`.
  """
  @spec jwt_sign_pem(jwt_claims(), String.t(), jwt_header()) :: result(String.t())
  def jwt_sign_pem(claims, private_key_pem, header \\ %{})
      when is_map(claims) and is_binary(private_key_pem) and is_map(header) do
    jwt_sign_pem_nif(Torque.encode!(claims), private_key_pem, Torque.encode!(header))
  end

  @spec jwt_sign_pem_nif(String.t(), String.t(), String.t()) :: result(String.t())
  defp jwt_sign_pem_nif(_claims, _private_key_pem, _header),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Verifies an RSA-signed JWT against an RFC 7517 JWK and returns its claims.

  `jwk` is one JWK map with `"kty" => "RSA"` and base64url `"n"`/`"e"`
  components, as served by provider JWKS documents. Only RS256/RS384/RS512 are
  accepted.
  """
  @spec jwt_verify_jwk(String.t(), map(), jwt_validation()) :: result(jwt_claims())
  def jwt_verify_jwk(token, jwk, validation \\ %{})
      when is_binary(token) and is_map(jwk) and is_map(validation) do
    token
    |> jwt_verify_jwk_nif(Torque.encode!(jwk), Torque.encode!(validation))
    |> decode_json_result()
  end

  @spec jwt_verify_jwk_nif(String.t(), String.t(), String.t()) :: result(String.t())
  defp jwt_verify_jwk_nif(_token, _jwk, _validation), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a random 32-byte hex key for kernel cryptographic helpers.
  """
  @spec generate_key() :: String.t()
  def generate_key, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validates and canonicalizes an international phone number as E.164 text.

  No default region is assumed. Provider adapters that accept local national
  numbers must build explicit country-code candidates before calling this.
  """
  @spec phone_normalize_e164(String.t()) :: result(String.t())
  def phone_normalize_e164(_phone), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a standard hyphenated UUIDv4 string.
  """
  @spec gen_uuid() :: String.t()
  def gen_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a standard hyphenated UUIDv7 string for time-sortable identifiers.
  """
  @spec gen_uuid_v7() :: String.t()
  def gen_uuid_v7, do: :erlang.nif_error(:nif_not_loaded)

  @doc "Encodes a canonical UUID as 26 lowercase Crockford Base32 characters."
  @spec uuid_shorten(String.t()) :: result(String.t())
  def uuid_shorten(_uuid), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Expands a canonical 26-character lowercase Crockford Base32 UUID; rejects aliases."
  @spec uuid_expand(String.t()) :: result(String.t())
  def uuid_expand(_short_uuid), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Transliterates a Page title with AnyAscii into a lowercase kebab-case URL slug."
  @spec page_url_slug(String.t()) :: String.t()
  def page_url_slug(_title), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Parses a web URL with WHATWG semantics and classifies its host.

  `host_class` drives the shared web URL policy: `:metadata` hosts are cloud
  credential endpoints Ankole always rejects, `:private` hosts are rejected
  only when `security.ssrf_filter` is enabled, and `:public` hosts are
  allowed. Most callers want `validate_web_url/3`, which applies that policy;
  reach for raw facts only when a caller needs the parsed pieces themselves.
  Both Elixir and Bun consume this one classifier.
  """
  @spec web_url_facts(String.t()) :: result(web_url_facts())
  def web_url_facts(url) when is_binary(url), do: web_url_facts_nif(url)

  @spec web_url_facts_nif(String.t()) :: result(web_url_facts())
  defp web_url_facts_nif(_url), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validates one web URL against the shared SSRF policy.

  Returns `:ok` when the URL scheme is in `schemes` and the classified host
  allows the request: `:public` hosts always pass, `:private` hosts pass only
  when `ssrf_filter?` is disabled, and `:metadata` cloud credential endpoints
  never pass. Returns `{:error, :metadata | :private | :invalid}` so each
  caller keeps its own scheme list and error vocabulary.
  """
  @spec validate_web_url(String.t(), [String.t()], boolean()) ::
          :ok | {:error, :metadata | :private | :invalid}
  def validate_web_url(url, schemes, ssrf_filter?)
      when is_binary(url) and is_list(schemes) and is_boolean(ssrf_filter?),
      do: validate_web_url_nif(url, schemes, ssrf_filter?)

  defp validate_web_url_nif(_url, _schemes, _ssrf_filter?),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "Checks every resolved IP address with the shared SSRF policy. Does not do DNS."
  @spec validate_ip_addresses([String.t()], boolean()) ::
          :ok | {:error, :metadata | :private | :invalid}
  def validate_ip_addresses(addresses, ssrf_filter?)
      when is_list(addresses) and is_boolean(ssrf_filter?),
      do: validate_ip_addresses_nif(addresses, ssrf_filter?)

  defp validate_ip_addresses_nif(_addresses, _ssrf_filter?),
    do: :erlang.nif_error(:nif_not_loaded)

  defp decode_json_result({:error, _reason} = error), do: error
  defp decode_json_result(json) when is_binary(json), do: Torque.decode!(json)
end
