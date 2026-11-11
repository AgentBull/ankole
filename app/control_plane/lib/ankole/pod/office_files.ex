defmodule Ankole.Pod.OfficeFiles do
  @moduledoc """
  Owns Office file pages (`.xlsx`, `.xlsm`, `.docx`, `.docm`, and `.pptx`):
  their operation log, compaction, version history, Agent operations, and
  Word-to-Document conversion.

  An Office page is a `type: :file` page whose file name matches `kind/1`
  (`:spreadsheet`, `:word`, or `:presentation`). Its logical state is the
  page's Drive object plus the operations in `pod_office_ops` that are not
  `compacted`. An editor commits one canonical operation (or unit change set)
  at a time under the page row lock: the kernel rebases the operation over the
  operations committed after the author's base revision, stamps server-owned
  author metadata, and commits or rejects with `office_conflict`.

  Compaction exports the document outside any database transaction, stores a
  new Drive object, and under the page row lock names that object at the page
  and marks the exported operations `compacted`. Readers that need the latest
  bytes call `flush_if_dirty/1` first. Outside writes (uploads, Agent Drive
  writes, or version restores) reach `object_committed_in_tx/3`, which marks
  earlier operations `compacted` and appends a `reset` entry. Versions live as
  file snapshots in `Ankole.Pod.Documents.History`.

  `NodeCache` keeps at most 64 opened documents across all kinds on each node
  and owns no durable state.
  """
  require Ash.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.Files, as: Drive
  alias Ankole.Pod.Access

  alias Ankole.Pod.{
    Config,
    FileCache,
    FileExtraction,
    Files,
    OfficeCheckpoint,
    OfficeOp,
    Page,
    Pages,
    Serialization
  }

  alias Ankole.Pod.Documents.History
  alias Ankole.Pod.Jobs.CompactOfficeFile
  alias __MODULE__.NodeCache

  # Drive appends ` (n)` to a duplicate sibling name, so `Budget.xlsx (1)` keeps its kind.
  @spreadsheet_name ~r/\.xls[xm](?: \(\d+\))?$/i
  @word_name ~r/\.doc[xm](?: \(\d+\))?$/i
  @presentation_name ~r/\.pptx(?: \(\d+\))?$/i
  @office_extension_suffix ~r/\.(?:xls[xm]|doc[xm]|pptx)(?: \(\d+\))?$/i

  # Spreadsheet operations that move cells and recalculate the workbook on replay.
  @structural ~w(line.insert line.delete cells.insert cells.delete range.move)
  # Maximum serialized wire size of one incoming operation (4 MiB).
  @max_op_wire_bytes 4 * 1024 * 1024
  @restore_attempts 3

  @type office_kind :: :spreadsheet | :word | :presentation

  @doc """
  Returns the Office kind (`:spreadsheet`, `:word`, `:presentation`) of a file
  name or `type: :file` Page, or `nil` when it is not an Office file.

  Matching ignores case and Drive's trailing ` (n)` duplicate suffix.
  """
  @spec kind(String.t() | Page.t() | term()) :: office_kind() | nil
  def kind(name) when is_binary(name) do
    cond do
      Regex.match?(@spreadsheet_name, name) -> :spreadsheet
      Regex.match?(@word_name, name) -> :word
      Regex.match?(@presentation_name, name) -> :presentation
      true -> nil
    end
  end

  def kind(%Page{type: :file, object_id: id, name: name}) when not is_nil(id), do: kind(name)
  def kind(_), do: nil

  @doc "Whether a file name or Page is any Office file."
  @spec office_file?(term()) :: boolean()
  def office_file?(value), do: not is_nil(kind(value))

  @doc "Whether a file name or Page is a Spreadsheet Office file (`.xlsx` or `.xlsm`)."
  @spec spreadsheet?(term()) :: boolean()
  def spreadsheet?(value), do: kind(value) == :spreadsheet

  @doc """
  Creates a file Page with a blank Office file of `format` named after `title`
  (default `Untitled`).

  `attrs` carry `:format` (`:spreadsheet`, `:word`, or `:presentation`) and
  placement (`:parent_id` or `:private_owner_uid`).
  """
  def create_blank(%Actor{} = actor, attrs) when is_map(attrs) do
    with {:ok, format} <- parse_format(Ankole.Attrs.get(attrs, :format)) do
      ext = default_extension(format)
      title = String.trim(Ankole.Attrs.get(attrs, :title) || "")

      name =
        cond do
          title == "" -> "Untitled" <> ext
          kind(title) == format -> title
          true -> title <> ext
        end

      place = Map.take(attrs, [:parent_id, :private_owner_uid, "parent_id", "private_owner_uid"])

      with {:ok, blank} <- Ankole.Kernel.office_create_blank(format, Path.rootname(name)),
           do: Files.create_from_upload(actor, place, name, blank.bytes, nil)
    end
  end

  defp parse_format(format) when format in [:spreadsheet, "spreadsheet"], do: {:ok, :spreadsheet}
  defp parse_format(format) when format in [:word, "word"], do: {:ok, :word}

  defp parse_format(format) when format in [:presentation, "presentation"],
    do: {:ok, :presentation}

  defp parse_format(_), do: {:error, :invalid_request}

  defp default_extension(:spreadsheet), do: ".xlsx"
  defp default_extension(:word), do: ".docx"
  defp default_extension(:presentation), do: ".pptx"

  @doc """
  Returns what an Office editor loads: the page `revision`, `format`, the
  current `file`, the uncompacted `ops`, and, for spreadsheets, the cached
  workbook `metadata`.

  A file larger than `max_file_bytes` returns `{:error, :file_too_large}` so
  the browser offers the original-file download instead.
  """
  def bootstrap(%Actor{} = actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _page} <- Access.authorize(actor, page, "node_view"),
           {:ok, format, file} <- office_file(page),
           {:ok, limits} <- Config.office_limits(),
           :ok <- within(file.size, limits.max_file_bytes) do
        metadata =
          if format == :spreadsheet do
            cache =
              FileCache
              |> Ash.Query.filter(page_id == ^page.id and object_id == ^file.object_id)
              |> Ankole.Ash.read_one!()

            if cache && cache.extract_status == :ok, do: cache.metadata, else: nil
          else
            nil
          end

        checkpoint =
          if format in [:word, :presentation],
            do: checkpoint_for_object(page.id, file.object_id),
            else: nil

        {:ok,
         %{
           page_id: page.id,
           revision: page.revision,
           format: format,
           file: Files.entry(file),
           ops:
             page.id
             |> uncompacted()
             |> Enum.map(&Map.take(&1, [:revision, :client_id, :client_seq, :op])),
           checkpoint: checkpoint,
           metadata: metadata
         }}
      end
    end)
  end

  @doc """
  Commits one canonical operation against the author's base revision.

  `attrs` carry `base_revision`, `client_id`, `client_seq`, and `op`. Retrying
  the same `(client_id, client_seq)` with the same payload acknowledges the
  earlier commit; reusing the sequence with different bytes fails with
  `:client_sequence_conflict`. Conflicting concurrent edits return
  `{:office_conflict, %{reason, revision, changes}}`.
  """
  def apply_op(actor, page_id, attrs, authority \\ nil)

  def apply_op(%Actor{} = actor, page_id, attrs, authority) when is_map(attrs) do
    authority = authority || actor.turn_authority

    request = %{
      base: Ankole.Attrs.get(attrs, :base_revision),
      client: Ankole.Attrs.get(attrs, :client_id),
      seq: Ankole.Attrs.get(attrs, :client_seq),
      op: Ankole.Attrs.get(attrs, :op)
    }

    with true <- valid_request?(request),
         encoded = Torque.encode!(request.op),
         true <- byte_size(encoded) <= @max_op_wire_bytes do
      actor_name = Ankole.Principals.display_name(actor.principal)

      request =
        Map.merge(request, %{
          digest: :crypto.hash(:sha256, encoded),
          actor_name: actor_name
        })

      # Opening a document reads the object store, so it runs before taking the row lock.
      with {:ok, page} <- Pages.authorize(actor, page_id, "node_edit"),
           {:ok, format} <- require_office_file(page),
           {:ok, limits} <- Config.office_limits(),
           {:ok, document} <- latest(page_id, limits.max_file_bytes) do
        authority
        |> Access.write(
          fn -> apply_in_tx(actor, page_id, format, request, document, limits) end,
          after_commit: &committed/1
        )
        |> result()
      end
    else
      _ -> {:error, :invalid_request}
    end
  end

  def apply_op(_actor, _page_id, _attrs, _authority), do: {:error, :invalid_request}

  defp valid_request?(%{base: base, client: client, seq: seq, op: op}) do
    is_integer(base) and base >= 0 and is_binary(client) and byte_size(client) in 1..255 and
      is_integer(seq) and seq > 0 and is_map(op)
  end

  @doc false
  def apply_in_tx(%Actor{} = actor, page_id, expected_format, request, document, limits) do
    with {:ok, page} <- Pages.lock(page_id),
         {:ok, _page} <- Access.authorize(actor, page, "node_edit"),
         {:ok, ^expected_format} <- require_office_file(page) do
      previous =
        OfficeOp
        |> Ash.Query.filter(
          page_id == ^page.id and client_id == ^request.client and client_seq == ^request.seq
        )
        |> Ankole.Ash.read_one!()

      cond do
        previous && previous.request_sha256 != request.digest ->
          {:error, :client_sequence_conflict}

        previous ->
          replayed = replay(page, request.base)

          {:ok,
           %{
             page_id: page.id,
             result: Map.put(replayed, :acknowledged_revision, previous.revision)
           }}

        true ->
          commit_op(actor, page, expected_format, request, document, limits)
      end
    else
      {:ok, _other_format} -> {:error, :office_busy}
      error -> error
    end
  end

  defp commit_op(actor, page, format, request, document, limits) do
    case replay(page, request.base) do
      %{reset_required: true} = replayed ->
        {:ok, %{page_id: page.id, result: replayed}}

      %{changes: prior} ->
        op =
          if format == :spreadsheet,
            do: own_comment(request.actor_name, request.op),
            else: request.op

        with {:ok, doc} <- catch_up(document, page, format),
             {:ok, applied} <- rebase(doc, op, prior, request.actor_name, page),
             :ok <- media_room(page, format, applied, limits) do
          save(actor, page, format, request, prior, applied, limits)
        end
    end
  end

  # The server names the author of a spreadsheet note; the client's value is never trusted.
  defp own_comment(actor_name, %{"type" => "comment.set"} = op) when is_binary(actor_name),
    do: Map.put(op, "author", actor_name)

  defp own_comment(_actor_name, op), do: op

  # Media bytes added in the operation must leave the file and pending log within `max_file_bytes`.
  defp media_room(page, format, %{carries_media: true, committed_op: op}, limits)
       when is_integer(limits.max_file_bytes) do
    added = added_media_bytes(format, op)

    if added > 0 do
      with {:ok, used} <- current_office_bytes(page) do
        if used + added <= limits.max_file_bytes,
          do: :ok,
          else: {:error, :office_full}
      end
    else
      :ok
    end
  end

  defp media_room(_page, _format, _applied, _limits), do: :ok

  defp current_office_bytes(page) do
    with {:ok, file} <- page_file(page) do
      pending =
        OfficeOp
        |> Ash.Query.filter(page_id == ^page.id and not compacted)
        |> Ankole.Ash.aggregate!([{:bytes, :sum, field: :wire_bytes}])
        |> Map.fetch!(:bytes)

      {:ok, (file.size || 0) + (pending || 0)}
    end
  end

  defp added_media_bytes(:spreadsheet, %{"picture" => %{"data" => data}})
       when is_binary(data),
       do: div(byte_size(data) * 3, 4)

  defp added_media_bytes(:word, %{"edits" => edits}) when is_list(edits) do
    Enum.reduce(edits, 0, fn
      %{"kind" => "entry.put", "map" => map, "value" => data}, acc
      when map in ["media", "passthrough"] and is_binary(data) ->
        acc + div(byte_size(data) * 3, 4)

      _, acc ->
        acc
    end)
  end

  defp added_media_bytes(:presentation, %{"edits" => edits}) when is_list(edits) do
    Enum.reduce(edits, 0, fn
      %{"kind" => "media.put", "data" => data}, acc when is_binary(data) ->
        acc + div(byte_size(data) * 3, 4)

      _, acc ->
        acc
    end)
  end

  defp added_media_bytes(_format, _op), do: 0

  defp rebase(doc, op, prior, actor_name, page) do
    case Ankole.Kernel.office_apply(doc, op, Enum.map(prior, & &1.op), actor_name) do
      {:ok, applied} ->
        {:ok, applied}

      {:conflict, reason} ->
        {:error,
         {:office_conflict,
          %{
            reason: reason,
            revision: page.revision,
            changes: Enum.map(prior, &Serialization.office_op_json/1)
          }}}

      {:busy, _reason} ->
        {:error, :office_busy}

      {:error, message} ->
        {:error, {:invalid_operation, message}}
    end
  end

  defp save(actor, page, format, request, prior, applied, limits) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, page} <- Pages.update_properties_in_tx(page, :advance_revision, %{updated_at: now}),
         {:ok, entry} <-
           Ankole.Ash.create(OfficeOp, :append, %{
             page_id: page.id,
             revision: page.revision,
             kind: :op,
             client_id: request.client,
             client_seq: request.seq,
             request_sha256: request.digest,
             op: applied.committed_op,
             author: ActorRef.from_actor(actor),
             created_at: now
           }),
         :ok <- schedule_compaction_in_tx(page.id, format, now, limits, applied) do
      {:ok,
       %{
         page_id: page.id,
         document: {format, page.revision, applied.doc_ref},
         result: %{
           revision: page.revision,
           changes: prior ++ [entry],
           reset_required: false,
           acknowledged_revision: page.revision
         }
       }}
    end
  end

  defp schedule_compaction_in_tx(page_id, format, now, limits, applied) do
    args = %{page_id: page_id}
    due = DateTime.add(now, limits.compaction_idle_seconds, :second)

    with :ok <- Ankole.Job.schedule_in_tx(CompactOfficeFile, args, due) do
      if compaction_due?(page_id, format, limits, applied),
        do: Ankole.Job.schedule_in_tx(CompactOfficeFile, args, now, only_earlier: true),
        else: :ok
    end
  end

  defp compaction_due?(_page_id, _format, _limits, %{carries_media: true}), do: true

  defp compaction_due?(page_id, format, limits, applied) do
    pending = Ash.Query.filter(OfficeOp, page_id == ^page_id and not compacted)

    Ankole.Ash.count!(pending) >= limits.compaction_op_threshold or
      (format == :spreadsheet and not is_nil(Map.get(applied, :structural_edit)) and
         pending
         |> Ash.Query.filter(op[:type] in ^@structural)
         |> Ankole.Ash.count!() >= limits.compaction_structural_threshold)
  end

  @doc "Caches the committed document on this node and publishes the commit to the page channel."
  def committed(%{page_id: id, document: {format, revision, doc}}) do
    NodeCache.put({Repo.tenant_id!(), id}, format, revision, doc)
    Pages.broadcast(id)
  end

  def committed(_result), do: :ok

  @doc """
  Returns the entries committed after `revision`, for an editor that catches up.

  `reset_required` asks the editor to bootstrap again: the file was replaced,
  the log was pruned past `revision`, or the entries exceed one channel message.
  """
  def since(%Actor{} = actor, page_id, revision) when is_integer(revision) and revision >= 0 do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _page} <- Access.authorize(actor, page, "node_view"),
           {:ok, _format} <- require_office_file(page),
           do: {:ok, replay(page, revision)}
    end)
  end

  def since(_actor, _page_id, _revision), do: {:error, :invalid_request}

  defp replay(page, base) do
    query =
      Ash.Query.filter(
        OfficeOp,
        page_id == ^page.id and revision > ^base and revision <= ^page.revision
      )

    bytes = Ankole.Ash.aggregate!(query, [{:bytes, :sum, field: :wire_bytes}]).bytes || 0

    envelope_bytes =
      byte_size(
        Torque.encode!(%{
          revision: page.revision,
          changes: [],
          reset_required: false,
          acknowledged_revision: page.revision
        })
      )

    if bytes + envelope_bytes > Ankole.Pod.DocumentWire.max_bytes() do
      %{revision: page.revision, changes: [], reset_required: true}
    else
      changes = query |> Ash.Query.sort(revision: :asc) |> Ankole.Ash.read!()

      %{
        revision: page.revision,
        changes: changes,
        reset_required: base > page.revision or not contiguous?(changes, base, page.revision)
      }
    end
  end

  defp contiguous?(entries, from, to) do
    Enum.map(entries, & &1.revision) == Enum.to_list((from + 1)..to//1) and
      Enum.all?(entries, &(&1.kind == :op))
  end

  @doc """
  Writes the uncompacted operations of an Office page into its stored file
  before a reader takes the bytes. Runs outside any transaction.
  """
  def flush_if_dirty(page_id) do
    with {:ok, id} <- Ecto.UUID.cast(page_id),
         true <- pending?(id),
         {:ok, {revision, format, doc}} <- latest(id, nil),
         {:ok, export} <- Ankole.Kernel.office_export_with_checkpoint(doc),
         {:ok, stored} <- Drive.store(export.bytes),
         {:ok, _flushed} <-
           Repo.transact_top_level(
             fn -> compact_in_tx(id, format, revision, stored, export) end,
             after_commit: &compacted(&1, id)
           ) do
      :ok
    else
      :error -> :ok
      false -> :ok
      error -> error
    end
  end

  defp compacted(:compacted, page_id), do: Ankole.Pod.node_committed(%{id: page_id})
  defp compacted(:current, _page_id), do: :ok

  defp pending?(page_id),
    do:
      OfficeOp
      |> Ash.Query.filter(page_id == ^page_id and not compacted)
      |> Ankole.Ash.exists?()

  @doc "Wakes compaction immediately when the page has uncompacted operations."
  def compact_now(page_id) do
    if pending?(page_id),
      do:
        Ankole.Job.schedule(
          CompactOfficeFile,
          %{page_id: page_id},
          DateTime.utc_now(:microsecond),
          only_earlier: true
        ),
      else: :ok
  end

  @doc false
  def compact_in_tx(page_id, format, revision, stored, export) do
    with {:ok, page} <- Pages.lock(page_id) do
      exported =
        OfficeOp
        |> Ash.Query.filter(page_id == ^page.id and not compacted and revision <= ^revision)

      if Ankole.Ash.exists?(exported) do
        compact_exported_in_tx(page, format, exported, revision, stored, export)
      else
        {:ok, :current}
      end
    end
  end

  defp compact_exported_in_tx(page, format, exported, revision, stored, export) do
    now = DateTime.utc_now(:microsecond)

    [first] =
      exported |> Ash.Query.sort(revision: :asc) |> Ash.Query.limit(1) |> Ankole.Ash.read!()

    [last] =
      exported |> Ash.Query.sort(revision: :desc) |> Ash.Query.limit(1) |> Ankole.Ash.read!()

    with {:ok, window} <- Config.ot_replay_window(),
         {:ok, current} <- Drive.fetch_object(page.object_id),
         :ok <- keep_original_in_tx(page, current, first.revision - 1, first.author, now),
         {:ok, file} <- Ankole.Pod.Files.Content.rewrite_in_tx(page.id, stored),
         :ok <- put_checkpoint_in_tx(page.id, file.object_id, Map.get(export, :checkpoint), now),
         {:ok, _compacted} <- Ankole.Ash.update_where(exported, :compact),
         :ok <-
           sync_compacted_search_in_tx(
             %{page | object_id: file.object_id, updated_at: now},
             format,
             file.object_id,
             export,
             now
           ),
         :ok <-
           History.file_checkpoint_in_tx(
             page,
             %{id: file.object_id, sha256: file.sha256},
             revision,
             last.author,
             now
           ),
         {:ok, _pruned} <-
           OfficeOp
           |> Ash.Query.filter(
             page_id == ^page.id and compacted and revision <= ^(page.revision - window)
           )
           |> Ankole.Ash.destroy_where(:prune) do
      {:ok, :compacted}
    end
  end

  # Spreadsheets compute formula-evaluated search text in the compaction transaction.
  # Word and Presentation pages enqueue `SyncFileCache` without clearing `PageSearchDocument`,
  # keeping the existing search projection live while OOXML extraction runs in the background.
  defp sync_compacted_search_in_tx(page, :spreadsheet, object_id, export, now) do
    put_spreadsheet_cache_in_tx(
      page,
      object_id,
      %{status: :ok, plain_text: export.plain_text, metadata: export.metadata},
      now
    )
  end

  defp sync_compacted_search_in_tx(page, format, object_id, _export, _now)
       when format in [:word, :presentation] do
    if office_file?(page.name),
      do: FileExtraction.enqueue_sync_in_tx(page.id, object_id),
      else: :ok
  end

  defp keep_original_in_tx(page, object, revision, author, now) do
    if History.kept_in_tx?(page.id),
      do: :ok,
      else: History.append_file_in_tx(page, object, revision, :created, author, now)
  end

  @doc """
  Keeps an Office page's current object in its history before a Pod upload replaces it.
  """
  def keep_replaced_in_tx(%Actor{} = actor, %Page{type: :file, object_id: id} = page)
      when not is_nil(id) do
    cond do
      pending?(page.id) ->
        {:error, :manifest_changed}

      logged?(page.id) ->
        keep_previous_in_tx(
          page,
          id,
          page.revision,
          ActorRef.from_actor(actor),
          DateTime.utc_now(:microsecond)
        )

      true ->
        :ok
    end
  end

  def keep_replaced_in_tx(_actor, _page), do: :ok

  @doc """
  Records an object named at a file page in the caller's transaction.

  Any page that is an Office file now, or that previously kept an Office
  operation log, marks pending operations `compacted`, appends a `reset` entry,
  and records version snapshots. Spreadsheet search caches update inline; Word,
  Presentation, and non-Office files delegate search extraction to
  `Ankole.Pod.FileExtraction.object_committed_in_tx/2`.
  """
  def object_committed_in_tx(%Actor{} = actor, previous, %Page{type: :file} = node) do
    logged? = logged?(node.id)
    current_kind = kind(node.name)

    if logged? or not is_nil(current_kind) do
      now = DateTime.utc_now(:microsecond)
      author = ActorRef.from_actor(actor)

      with {:ok, page} <-
             Pages.update_properties_in_tx(node, :advance_revision, %{updated_at: now}),
           :ok <- put_checkpoint_in_tx(page.id, nil, nil, now),
           {:ok, _compacted} <-
             OfficeOp
             |> Ash.Query.filter(page_id == ^page.id and not compacted)
             |> Ankole.Ash.update_where(:compact),
           :ok <-
             keep_previous_in_tx(
               page,
               logged? && previous.object_id,
               page.revision - 1,
               author,
               now
             ),
           {:ok, _reset} <-
             Ankole.Ash.create(OfficeOp, :append, %{
               page_id: page.id,
               revision: page.revision,
               kind: :reset,
               compacted: true,
               author: author,
               created_at: now
             }),
           {:ok, object} <- Drive.fetch_object(node.object_id),
           :ok <- keep_new_in_tx(page, object, previous.object_id, author, now) do
        sync_committed_cache_in_tx(page, previous, object, current_kind, now)
      end
    else
      :ok
    end
  end

  def object_committed_in_tx(_actor, _previous, _node), do: :ok

  defp sync_committed_cache_in_tx(page, _previous, object, :spreadsheet, now) do
    with {:ok, derived} <- derive_spreadsheet(page.name, object),
         do: put_spreadsheet_cache_in_tx(page, object.id, derived, now)
  end

  defp sync_committed_cache_in_tx(page, previous, _object, _other_kind, now) do
    if previous && spreadsheet?(previous.name),
      do: put_spreadsheet_cache_in_tx(page, nil, :not_spreadsheet, now),
      else: :ok
  end

  @doc """
  Reconciles the spreadsheet `FileCache` and `PageSearchDocument` for a file
  page whose `object_id` was assigned directly (inbound/private file creation,
  rename to `.xlsx`, or self-healing).
  """
  def reconcile_file_in_tx(%Page{type: :file, object_id: object_id} = page)
      when is_binary(object_id) do
    Repo.require_transaction!({__MODULE__, :reconcile_file_in_tx})

    with {:ok, object} <- Drive.fetch_object(object_id),
         {:ok, derived} <- derive_spreadsheet(page.name, object) do
      put_spreadsheet_cache_in_tx(page, object.id, derived, DateTime.utc_now(:microsecond))
    end
  end

  def reconcile_file_in_tx(_page), do: :ok

  defp logged?(page_id),
    do: OfficeOp |> Ash.Query.filter(page_id == ^page_id) |> Ankole.Ash.exists?()

  defp keep_previous_in_tx(page, previous_id, revision, author, now)
       when is_binary(previous_id) do
    if History.file_kept_in_tx?(page.id, previous_id),
      do: :ok,
      else:
        History.append_file_in_tx(page, %{id: previous_id}, revision, :checkpoint, author, now)
  end

  defp keep_previous_in_tx(_page, _previous_id, _revision, _author, _now), do: :ok

  defp keep_new_in_tx(page, object, previous_id, author, now) do
    reason = if is_nil(previous_id), do: :created, else: :uploaded

    if not office_file?(page.name) or History.file_kept_in_tx?(page.id, object.id),
      do: :ok,
      else: History.append_file_in_tx(page, object, page.revision, reason, author, now)
  end

  defp derive_spreadsheet(name, object) do
    with true <- spreadsheet?(name),
         {:ok, limits} <- Config.office_limits(),
         :ok <- within(object.size, limits.max_file_bytes),
         {:ok, bytes} <- Drive.read_object(object.id),
         {:ok, opened} <- Ankole.Kernel.office_open(:spreadsheet, bytes, []) do
      {:ok, %{status: :ok, plain_text: opened.plain_text, metadata: opened.metadata}}
    else
      false -> {:ok, :not_spreadsheet}
      {:error, :file_too_large} -> {:ok, %{status: :skipped, error: "file_too_large"}}
      {:error, message} when is_binary(message) -> {:ok, %{status: :failed, error: message}}
      error -> error
    end
  end

  defp put_spreadsheet_cache_in_tx(page, _object_id, :not_spreadsheet, _now) do
    with {:ok, _purged} <-
           FileCache |> Ash.Query.filter(page_id == ^page.id) |> Ankole.Ash.destroy_where(:purge),
         do: put_search_text_in_tx(page, "")
  end

  defp put_spreadsheet_cache_in_tx(page, object_id, %{status: :ok} = derived, now) do
    format = spreadsheet_format(page.name)

    with {:ok, _cache} <-
           Ankole.Ash.create(FileCache, :put, %{
             page_id: page.id,
             subtype: :spreadsheet,
             format: format,
             object_id: object_id,
             extractor_version: Ankole.Kernel.file_extractor_version(),
             extract_status: :ok,
             extract_error: nil,
             metadata: derived.metadata,
             updated_at: now
           }),
         do: put_search_text_in_tx(page, derived.plain_text)
  end

  defp put_spreadsheet_cache_in_tx(page, object_id, %{status: status, error: reason}, now)
       when status in [:skipped, :failed] do
    format = spreadsheet_format(page.name)

    with {:ok, _cache} <-
           Ankole.Ash.create(FileCache, :put, %{
             page_id: page.id,
             subtype: :spreadsheet,
             format: format,
             object_id: object_id,
             extractor_version: Ankole.Kernel.file_extractor_version(),
             extract_status: status,
             extract_error: reason,
             metadata: %{},
             updated_at: now
           }),
         do: put_search_text_in_tx(page, "")
  end

  # Brain chunks and learns the same text that search holds.
  defp put_search_text_in_tx(page, text) do
    with :ok <- Ankole.Pod.SearchProjection.upsert_in_tx(page, body_text: text),
         do: Ankole.Brain.Knowledge.file_cache_changed_in_tx(page)
  end

  defp spreadsheet_format(name) when is_binary(name) do
    if Regex.match?(~r/\.xlsm(?: \(\d+\))?$/i, name), do: "xlsm", else: "xlsx"
  end

  defp spreadsheet_format(_), do: "xlsx"

  @doc """
  Lists an Office page's versions from the page history, newest first.

  Requires `node_edit` so sharing the current file with a viewer does not
  expose earlier versions.
  """
  def versions(%Actor{} = actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _page} <- Access.authorize(actor, page, "node_edit"),
           {:ok, _format} <- require_office_file(page),
           do: {:ok, History.file_snapshots_in_tx(page.id)}
    end)
  end

  @doc """
  Makes a historical version the page's active file again.
  """
  def restore(actor, page_id, version_id, authority \\ nil)

  def restore(%Actor{} = actor, page_id, version_id, authority) do
    authority = authority || actor.turn_authority

    with {:ok, _page} <- Pages.authorize(actor, page_id, "node_edit"),
         {:ok, version_id} <- cast_id(version_id) do
      restore_after_flush(actor, page_id, version_id, authority, @restore_attempts)
    end
  end

  defp restore_after_flush(actor, page_id, version_id, authority, attempts) do
    with :ok <- flush_if_dirty(page_id) do
      result =
        Access.write_tree(authority, fn -> restore_in_tx(actor, page_id, version_id) end,
          root_ids: fn -> Ankole.Pod.root_ids([page_id]) end,
          after_commit: &Files.committed/1
        )

      case result do
        {:error, :office_busy} when attempts > 1 ->
          restore_after_flush(actor, page_id, version_id, authority, attempts - 1)

        result ->
          result
      end
    end
  end

  @doc false
  def restore_in_tx(%Actor{} = actor, page_id, version_id) do
    author = ActorRef.from_actor(actor)

    with {:ok, page} <- Pages.lock(page_id),
         {:ok, _page} <- Access.authorize(actor, page, "node_edit"),
         {:ok, _format, current} <- office_file(page),
         {:ok, version} <- History.fetch_file_in_tx(page.id, version_id),
         :ok <- if(pending?(page.id), do: {:error, :office_busy}, else: :ok),
         :ok <-
           History.append_file_in_tx(
             page,
             %{id: current.object_id},
             page.revision,
             :before_restore,
             author,
             DateTime.utc_now(:microsecond)
           ),
         {:ok, _upload} <-
           Files.commit_upload_in_tx(actor, page.id, %{
             role: "file",
             base_object_id: current.object_id,
             name: version.title,
             object: version.object_id,
             content_type: nil
           }),
         {:ok, page} <- Pages.fetch(page.id),
         :ok <-
           History.append_file_in_tx(
             page,
             %{id: version.object_id},
             page.revision,
             :restored,
             author,
             DateTime.utc_now(:microsecond)
           ),
         {:ok, format, file} <- office_file(page) do
      {:ok,
       %{
         page_id: page.id,
         revision: page.revision,
         format: format,
         file: Files.entry(file)
       }}
    end
  end

  # --- Word-to-Document Conversion ---

  @doc """
  Creates a native `:doc` Page from a Word Page (`POST /api/v2/pod/pages/:id/convert-to-document`).

  Requires `node_view` on the Word Page. When neither `parent_id` nor
  `private_owner_uid` is supplied, places the new Page as the next sibling
  after the Word Page when the caller may create `:doc` Pages under its parent,
  and otherwise places it in the caller's Private root.
  """
  def convert_to_document(actor, page_id, attrs \\ %{}, authority \\ nil)

  def convert_to_document(%Actor{} = actor, page_id, attrs, authority) when is_map(attrs) do
    authority = authority || actor.turn_authority

    with {:ok, page} <- Pages.authorize(actor, page_id, "node_view"),
         :ok <- require_kind(page, :word),
         {:ok, limits} <- Config.office_limits(),
         {:ok, {_revision, :word, doc}} <- latest(page.id, limits.max_file_bytes),
         {:ok, converted} <- convert_word_doc(doc),
         {:ok, stored_assets} <- store_converted_media(converted.media) do
      owner_uid = Ankole.Principals.authority_uid(Ankole.AuthZ.Actor.uid(actor))

      Access.write_tree(
        authority,
        fn ->
          convert_to_document_in_tx(actor, page.id, attrs, owner_uid, converted, stored_assets)
        end,
        root_ids: fn ->
          Enum.uniq(
            Ankole.Pod.root_ids([page.id]) ++
              Pages.destination_root_ids(actor, attrs) ++
              Pages.destination_root_ids(actor, %{private_owner_uid: owner_uid})
          )
        end,
        after_commit: fn %{page: created} -> Pages.committed_tree(created) end
      )
    end
  end

  defp convert_word_doc(doc) do
    case Ankole.Kernel.office_to_document(doc) do
      {:ok, converted} -> {:ok, converted}
      {:error, :document_too_large} -> {:error, :document_too_large}
      {:error, message} -> {:error, {:invalid_office_file, message}}
    end
  end

  defp store_converted_media(media) when is_list(media) do
    Enum.reduce_while(media, {:ok, []}, fn item, {:ok, acc} ->
      case Drive.store(item.bytes) do
        {:ok, stored} ->
          filename = Drive.file_name(item.filename)

          hex_sha =
            case stored.sha256 do
              <<raw::binary-size(32)>> -> Base.encode16(raw, case: :lower)
              <<hex::binary-size(64)>> -> String.downcase(hex)
            end

          {:cont,
           {:ok,
            [
              %{
                path: "assets/" <> hex_sha <> "/" <> filename,
                object: stored,
                content_type: item.mime
              }
              | acc
            ]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp convert_to_document_in_tx(actor, page_id, attrs, owner_uid, converted, stored_assets) do
    Pages.lock_tree()

    with {:ok, source} <- Pages.lock(page_id, :share),
         {:ok, _} <- Access.authorize(actor, source, "node_view"),
         :ok <- require_kind(source, :word),
         {:ok, placement} <- conversion_placement_in_tx(actor, source, attrs, owner_uid),
         title = conversion_title(source, attrs),
         create_attrs =
           Map.merge(placement, %{
             type: :doc,
             title: title,
             xml: converted.xml,
             saved_from_message_id: Ankole.Attrs.get(attrs, :saved_from_message_id)
           }),
         {:ok, new_page} <- Pages.create_in_tx(actor, create_attrs),
         {:ok, _files} <- Files.commit_files_in_tx(new_page.id, stored_assets, []),
         {:ok, new_page} <- Pages.fetch(new_page.id) do
      {:ok,
       %{
         page: new_page,
         omitted: converted.omitted,
         downgraded: converted.downgraded
       }}
    end
  end

  defp conversion_placement_in_tx(actor, source, attrs, owner_uid) do
    explicit_parent = Ankole.Attrs.get(attrs, :parent_id)
    explicit_owner = Ankole.Attrs.get(attrs, :private_owner_uid)

    cond do
      not is_nil(explicit_parent) or not is_nil(explicit_owner) ->
        {:ok, %{parent_id: explicit_parent, private_owner_uid: explicit_owner}}

      sibling_convertible?(actor, source) ->
        {:ok, %{parent_id: source.parent_id, after_id: source.id}}

      true ->
        {:ok, %{private_owner_uid: owner_uid}}
    end
  end

  defp sibling_convertible?(actor, %{parent_id: parent_id}) when is_binary(parent_id) do
    with {:ok, parent} <- Ankole.Pod.fetch_node(parent_id),
         {:ok, root} <- Ankole.Pod.root(parent_id),
         true <- is_nil(root.conversation_id) and root.system_key != "ankole_brain",
         {:ok, _} <- Ankole.Pod.Pages.Tree.authorize_child_create(actor, parent) do
      true
    else
      _ -> false
    end
  end

  defp sibling_convertible?(_actor, _source), do: false

  defp conversion_title(source, attrs) do
    case String.trim(Ankole.Attrs.get(attrs, :title) || "") do
      "" ->
        raw = source.title || source.name || "Untitled"
        stripped = Regex.replace(@office_extension_suffix, raw, "")
        if String.trim(stripped) == "", do: "Untitled", else: stripped

      explicit ->
        explicit
    end
  end

  # --- Agent Operations ---

  @doc "Returns structural and textual details of the logical Office document."
  def inspect_doc(%Actor{} = actor, page_id, params \\ %{}) when is_map(params) do
    with {:ok, page} <- Pages.authorize(actor, page_id, "node_view"),
         {:ok, format} <- require_office_file(page),
         {:ok, limits} <- Config.office_limits(),
         {:ok, {revision, ^format, doc}} <- latest(page.id, limits.max_file_bytes),
         {:ok, inspected} <- Ankole.Kernel.office_inspect(doc, Map.drop(params, ["id", :id])) do
      {:ok,
       Map.merge(inspected, %{
         "page_id" => page.id,
         "format" => Atom.to_string(format),
         "revision" => revision
       })}
    else
      {:ok, _other_revision_and_format} -> {:error, :office_busy}
      error -> error
    end
  end

  @doc "Renders one page or slide (1-based) of a Word or Presentation Page to PNG outside any transaction."
  def render_to_file(%Actor{} = actor, page_id, params, local_path) when is_map(params) do
    index = Ankole.Attrs.get(params, :page) || Ankole.Attrs.get(params, :slide) || 1
    scale = Ankole.Attrs.get(params, :scale) || 1.5

    with true <- is_integer(index) and index >= 1,
         true <- is_number(scale) and scale >= 0.25 and scale <= 4.0,
         {:ok, page} <- Pages.authorize(actor, page_id, "node_view"),
         {:ok, format} when format in [:word, :presentation] <- require_office_file(page),
         {:ok, limits} <- Config.office_limits(),
         {:ok, {revision, ^format, doc}} <- latest(page.id, limits.max_file_bytes),
         {:ok, rendered} <- Ankole.Kernel.office_render(doc, index, scale * 1.0),
         :ok <- File.write(local_path, rendered.png_bytes) do
      {:ok,
       %{
         page_id: page.id,
         format: format,
         revision: revision,
         index: index,
         count: rendered.count,
         width: rendered.width,
         height: rendered.height,
         bytes: byte_size(rendered.png_bytes)
       }}
    else
      false -> {:error, :invalid_request}
      {:ok, :spreadsheet} -> {:error, :invalid_page_type}
      {:ok, _other} -> {:error, :office_busy}
      {:error, message} when is_binary(message) -> {:error, {:invalid_operation, message}}
      error -> error
    end
  end

  @doc "Lists supported headless engine commands and parameter schemas for Word and Presentation Pages."
  def commands(%Actor{} = actor, page_id, query \\ nil) do
    with {:ok, page} <- Pages.authorize(actor, page_id, "node_view"),
         {:ok, format} when format in [:word, :presentation] <- require_office_file(page),
         {:ok, list} <- Ankole.Kernel.office_commands(format, query) do
      {:ok, %{page_id: page.id, format: format, commands: list}}
    else
      {:ok, :spreadsheet} -> {:error, :invalid_page_type}
      error -> error
    end
  end

  @doc """
  Applies an Agent batch of headless engine commands (Word/Presentation) or
  canonical operations (Spreadsheet).

  Command execution and diff derivation run on `DirtyCpu` outside any database
  transaction; only the final unit change set commits under `Pages.lock`.
  """
  def apply_agent(actor, page_id, params, authority \\ nil)

  def apply_agent(%Actor{} = actor, page_id, params, authority) when is_map(params) do
    authority = authority || actor.turn_authority

    expected_revision =
      Ankole.Attrs.get(params, :expected_revision) || Ankole.Attrs.get(params, :base_revision)

    with :ok <- valid_expected_revision(expected_revision),
         {:ok, page} <- Pages.authorize(actor, page_id, "node_edit"),
         {:ok, format} <- require_office_file(page),
         {:ok, limits} <- Config.office_limits() do
      case format do
        :spreadsheet ->
          apply_agent_spreadsheet(
            actor,
            page.id,
            expected_revision,
            Ankole.Attrs.get(params, :ops),
            limits,
            authority
          )

        format when format in [:word, :presentation] ->
          apply_agent_commands(
            actor,
            page.id,
            format,
            expected_revision,
            Ankole.Attrs.get(params, :commands),
            limits,
            authority
          )
      end
    end
  end

  defp valid_expected_revision(nil), do: :ok
  defp valid_expected_revision(rev) when is_integer(rev) and rev >= 0, do: :ok
  defp valid_expected_revision(_), do: {:error, :invalid_request}

  defp apply_agent_commands(
         actor,
         page_id,
         format,
         expected_revision,
         commands,
         limits,
         authority
       )
       when is_list(commands) and commands != [] do
    if Enum.all?(commands, &is_map/1) do
      do_apply_agent_commands(
        actor,
        page_id,
        format,
        expected_revision,
        commands,
        limits,
        authority
      )
    else
      {:error, :invalid_request}
    end
  end

  defp apply_agent_commands(_actor, _id, _fmt, _exp, _cmds, _limits, _auth),
    do: {:error, :invalid_request}

  defp do_apply_agent_commands(
         actor,
         page_id,
         format,
         expected_revision,
         commands,
         limits,
         authority
       ) do
    actor_name = Ankole.Principals.display_name(actor.principal)

    with {:ok, {read_revision, ^format, doc} = document} <-
           latest(page_id, limits.max_file_bytes),
         :ok <- check_expected_revision(read_revision, expected_revision),
         {:ok, batch} <- Ankole.Kernel.office_apply_commands(doc, commands, actor_name) do
      if Map.get(batch.change_set, "edits", []) == [] do
        verify_noop_agent_batch(actor, page_id, format, expected_revision, batch.results)
      else
        commit_agent_change_set(
          actor,
          page_id,
          format,
          expected_revision,
          read_revision,
          actor_name,
          document,
          batch,
          limits,
          authority
        )
      end
    else
      {:ok, _other_format} -> {:error, :office_busy}
      {:error, message} when is_binary(message) -> {:error, {:invalid_operation, message}}
      error -> error
    end
  end

  defp verify_noop_agent_batch(actor, page_id, format, expected_revision, results) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _} <- Access.authorize(actor, page, "node_edit"),
           {:ok, ^format} <- require_office_file(page),
           :ok <- check_expected_revision(page.revision, expected_revision) do
        {:ok,
         %{
           page_id: page.id,
           format: format,
           revision: page.revision,
           results: results
         }}
      else
        {:ok, _other} -> {:error, :office_busy}
        error -> error
      end
    end)
  end

  defp commit_agent_change_set(
         actor,
         page_id,
         format,
         expected_revision,
         read_revision,
         actor_name,
         document,
         batch,
         limits,
         authority
       ) do
    encoded = Torque.encode!(batch.change_set)

    if byte_size(encoded) > @max_op_wire_bytes do
      {:error, :invalid_request}
    else
      request = %{
        base: read_revision,
        client: "agent:" <> Ankole.Ecto.UUIDv7.autogenerate(),
        seq: 1,
        op: batch.change_set,
        digest: :crypto.hash(:sha256, encoded),
        actor_name: actor_name
      }

      authority
      |> Access.write(
        fn ->
          commit_agent_change_set_in_tx(
            actor,
            page_id,
            format,
            expected_revision,
            request,
            document,
            batch.results,
            limits
          )
        end,
        after_commit: &committed/1
      )
      |> unwrap_agent_reply()
    end
  end

  defp commit_agent_change_set_in_tx(
         actor,
         page_id,
         format,
         expected_revision,
         request,
         document,
         results,
         limits
       ) do
    with {:ok, page} <- Pages.lock(page_id),
         {:ok, _} <- Access.authorize(actor, page, "node_edit"),
         {:ok, ^format} <- require_office_file(page),
         :ok <- check_expected_revision(page.revision, expected_revision),
         {:ok, committed} <- commit_op(actor, page, format, request, document, limits) do
      if committed.result.reset_required do
        {:error, {:revision_conflict, committed.result.revision}}
      else
        {:ok,
         Map.put(committed, :agent_reply, %{
           page_id: page.id,
           format: format,
           revision: committed.result.revision,
           results: results
         })}
      end
    else
      {:ok, _other} -> {:error, :office_busy}
      error -> error
    end
  end

  defp apply_agent_spreadsheet(actor, page_id, expected_revision, ops, limits, authority)
       when is_list(ops) and ops != [] do
    if Enum.all?(ops, &is_map/1) do
      do_apply_agent_spreadsheet(actor, page_id, expected_revision, ops, limits, authority)
    else
      {:error, :invalid_request}
    end
  end

  defp apply_agent_spreadsheet(_actor, _id, _exp, _ops, _limits, _auth),
    do: {:error, :invalid_request}

  defp do_apply_agent_spreadsheet(actor, page_id, expected_revision, ops, limits, authority) do
    actor_name = Ankole.Principals.display_name(actor.principal)
    client_id = "agent:" <> Ankole.Ecto.UUIDv7.autogenerate()

    with {:ok, prepared_ops} <- prepare_agent_spreadsheet_ops(ops),
         {:ok, {read_revision, :spreadsheet, _doc} = document} <-
           latest(page_id, limits.max_file_bytes),
         :ok <- check_expected_revision(read_revision, expected_revision) do
      authority
      |> Access.write(
        fn ->
          commit_agent_spreadsheet_in_tx(
            actor,
            page_id,
            expected_revision,
            prepared_ops,
            client_id,
            actor_name,
            document,
            read_revision,
            limits
          )
        end,
        after_commit: &committed/1
      )
      |> unwrap_agent_reply()
    end
  end

  defp prepare_agent_spreadsheet_ops(ops) do
    ops
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {op, seq}, {:ok, acc} ->
      encoded = Torque.encode!(op)

      if byte_size(encoded) > @max_op_wire_bytes do
        {:halt, {:error, :invalid_request}}
      else
        {:cont, {:ok, [%{seq: seq, op: op, digest: :crypto.hash(:sha256, encoded)} | acc]}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp commit_agent_spreadsheet_in_tx(
         actor,
         page_id,
         expected_revision,
         prepared_ops,
         client_id,
         actor_name,
         document,
         read_revision,
         limits
       ) do
    with {:ok, page} <- Pages.lock(page_id),
         {:ok, _} <- Access.authorize(actor, page, "node_edit"),
         {:ok, :spreadsheet} <- require_office_file(page),
         :ok <- check_expected_revision(page.revision, expected_revision),
         {:ok, final_page, final_doc} <-
           batch_agent_spreadsheet_ops_in_tx(
             prepared_ops,
             actor,
             page,
             document,
             read_revision,
             client_id,
             actor_name,
             limits
           ) do
      {:ok,
       %{
         page_id: final_page.id,
         document: {:spreadsheet, final_page.revision, final_doc},
         agent_reply: %{
           page_id: final_page.id,
           format: :spreadsheet,
           revision: final_page.revision,
           results: Enum.map(prepared_ops, fn _ -> %{"ok" => true} end)
         }
       }}
    else
      {:ok, _other} -> {:error, :office_busy}
      error -> error
    end
  end

  defp batch_agent_spreadsheet_ops_in_tx(
         prepared_ops,
         actor,
         page,
         document,
         read_revision,
         client_id,
         actor_name,
         limits
       ) do
    case replay(page, read_revision) do
      %{reset_required: true, revision: current_rev} ->
        {:error, {:revision_conflict, current_rev}}

      %{changes: prior} ->
        with {:ok, base_doc} <- catch_up(document, page, :spreadsheet),
             {:ok, final_doc, committed_ops, carries_media?, last_structural_edit} <-
               apply_agent_spreadsheet_memory(
                 prepared_ops,
                 page,
                 base_doc,
                 prior,
                 actor_name,
                 limits
               ) do
          persist_agent_spreadsheet_batch(
            actor,
            page,
            client_id,
            committed_ops,
            final_doc,
            carries_media?,
            last_structural_edit,
            limits
          )
        end
    end
  end

  defp apply_agent_spreadsheet_memory(prepared_ops, page, base_doc, prior, actor_name, limits) do
    init = {:ok, base_doc, [], false, nil, nil}

    Enum.reduce_while(prepared_ops, init, fn item,
                                             {:ok, cur_doc, acc, any_media?, last_struct,
                                              used_bytes} ->
      op = own_comment(actor_name, item.op)
      op_prior = if item.seq == 1, do: prior, else: []

      with {:ok, applied} <- rebase(cur_doc, op, op_prior, actor_name, page),
           {:ok, next_used} <- check_batch_media_room(page, applied, used_bytes, limits) do
        next_struct = applied.structural_edit || last_struct

        {:cont,
         {:ok, applied.doc_ref, [Map.put(item, :committed_op, applied.committed_op) | acc],
          any_media? or applied.carries_media, next_struct, next_used}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, final_doc, rev_ops, any_media?, last_struct, _used} ->
        {:ok, final_doc, Enum.reverse(rev_ops), any_media?, last_struct}

      error ->
        error
    end
  end

  defp check_batch_media_room(page, %{carries_media: true, committed_op: op}, used_bytes, limits)
       when is_integer(limits.max_file_bytes) do
    added = added_media_bytes(:spreadsheet, op)

    if added > 0 do
      with {:ok, current} <-
             if(is_integer(used_bytes), do: {:ok, used_bytes}, else: current_office_bytes(page)) do
        next = current + added
        if next <= limits.max_file_bytes, do: {:ok, next}, else: {:error, :office_full}
      end
    else
      {:ok, used_bytes}
    end
  end

  defp check_batch_media_room(_page, _applied, used_bytes, _limits), do: {:ok, used_bytes}

  defp persist_agent_spreadsheet_batch(
         actor,
         page,
         client_id,
         committed_ops,
         final_doc,
         carries_media?,
         last_structural_edit,
         limits
       ) do
    now = DateTime.utc_now(:microsecond)
    author = ActorRef.from_actor(actor)
    start_rev = page.revision
    count = length(committed_ops)

    entries =
      Enum.map(committed_ops, fn item ->
        %{
          page_id: page.id,
          revision: start_rev + item.seq,
          kind: :op,
          client_id: client_id,
          client_seq: item.seq,
          request_sha256: item.digest,
          op: item.committed_op,
          author: author,
          created_at: now
        }
      end)

    summary = %{carries_media: carries_media?, structural_edit: last_structural_edit}

    with {:ok, updated_page} <-
           Pages.update_properties_in_tx(page, :advance_revision, %{
             updated_at: now,
             delta: count
           }),
         {:ok, _inserted} <- Ankole.Ash.create_all(entries, OfficeOp, :append),
         :ok <- schedule_compaction_in_tx(page.id, :spreadsheet, now, limits, summary) do
      {:ok, updated_page, final_doc}
    end
  end

  defp unwrap_agent_reply({:ok, %{agent_reply: reply}}), do: {:ok, reply}
  defp unwrap_agent_reply(error), do: error

  defp check_expected_revision(_current, nil), do: :ok
  defp check_expected_revision(same, same), do: :ok
  defp check_expected_revision(current, _expected), do: {:error, {:revision_conflict, current}}

  # --- Document Loading & Replay ---

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp latest(page_id, max_bytes) do
    with {:ok, id} <- cast_id(page_id),
         key = {Repo.tenant_id!(), id},
         cached = NodeCache.fetch(key),
         {:ok, plan} <- Repo.transact_top_level(fn -> plan_in_tx(id, cached) end),
         {:ok, revision, format, doc} <- load(plan, max_bytes) do
      if not match?({:cached, _revision, _format, _doc}, plan),
        do: NodeCache.put(key, format, revision, doc)

      {:ok, {revision, format, doc}}
    end
  end

  defp plan_in_tx(page_id, cached) do
    with {:ok, page} <- Pages.lock(page_id, :share),
         {:ok, file} <- page_file(page) do
      tail = uncompacted(page.id)
      format = kind(file.path) || infer_kind_from_entries(tail)

      if is_nil(format) do
        {:error, :invalid_page_type}
      else
        case cached do
          {:ok, ^format, revision, doc} when revision == page.revision ->
            {:ok, {:cached, revision, format, doc}}

          {:ok, ^format, revision, doc} when revision < page.revision ->
            entries = entries_after(page, revision)

            if contiguous?(entries, revision, page.revision),
              do: {:ok, {:replay, page.revision, format, doc, entries}},
              else:
                {:ok,
                 {:open, page.revision, format, file, tail,
                  open_checkpoint_in_tx(page.id, format, file.object_id)}}

          _miss ->
            {:ok,
             {:open, page.revision, format, file, tail,
              open_checkpoint_in_tx(page.id, format, file.object_id)}}
        end
      end
    end
  end

  defp open_checkpoint_in_tx(page_id, format, object_id)
       when format in [:word, :presentation],
       do: checkpoint_for_object(page_id, object_id)

  defp open_checkpoint_in_tx(_page_id, _format, _object_id), do: nil

  defp checkpoint_for_object(page_id, object_id) do
    case OfficeCheckpoint
         |> Ash.Query.filter(page_id == ^page_id and object_id == ^object_id)
         |> Ankole.Ash.read_one!() do
      %OfficeCheckpoint{checkpoint: checkpoint} -> checkpoint
      nil -> nil
    end
  end

  defp put_checkpoint_in_tx(page_id, _object_id, nil, _now) do
    with {:ok, _purged} <-
           OfficeCheckpoint
           |> Ash.Query.filter(page_id == ^page_id)
           |> Ankole.Ash.destroy_where(:purge),
         do: :ok
  end

  defp put_checkpoint_in_tx(page_id, object_id, checkpoint, now) when is_binary(checkpoint) do
    with {:ok, _saved} <-
           Ankole.Ash.create(OfficeCheckpoint, :put, %{
             page_id: page_id,
             object_id: object_id,
             checkpoint: checkpoint,
             updated_at: now
           }),
         do: :ok
  end

  defp infer_kind_from_entries([%{op: %{"type" => _}} | _]), do: :spreadsheet

  defp infer_kind_from_entries([%{op: %{"edits" => [%{"kind" => edit_kind} | _]}} | _])
       when is_binary(edit_kind) do
    if String.starts_with?(edit_kind, ["slide.", "slides.", "media.", "deck."]),
      do: :presentation,
      else: :word
  end

  defp infer_kind_from_entries(_), do: nil

  defp load({:cached, revision, format, doc}, _max_bytes), do: {:ok, revision, format, doc}

  defp load({:replay, revision, format, doc, entries}, _max_bytes) do
    with {:ok, doc} <- replay_entries(doc, entries), do: {:ok, revision, format, doc}
  end

  defp load({:open, revision, format, file, entries, checkpoint}, max_bytes) do
    with :ok <- within(file.size, max_bytes),
         {:ok, bytes} <- Drive.read_object(file.object_id) do
      case Ankole.Kernel.office_open(format, bytes, Enum.map(entries, & &1.op), checkpoint) do
        {:ok, opened} -> {:ok, revision, format, opened.doc_ref}
        {:busy, _reason} -> {:error, :office_busy}
        {:error, message} -> {:error, {:invalid_office_file, message}}
      end
    end
  end

  defp catch_up({revision, format, doc}, %{revision: revision}, format), do: {:ok, doc}

  defp catch_up({revision, format, doc}, page, format) when revision < page.revision do
    entries = entries_after(page, revision)

    if contiguous?(entries, revision, page.revision),
      do: replay_entries(doc, entries),
      else: {:error, :office_busy}
  end

  defp catch_up(_document, _page, _format), do: {:error, :office_busy}

  # Committed operations are already rebased and author-stamped, so they replay with empty priors.
  defp replay_entries(doc, entries) do
    Enum.reduce_while(entries, {:ok, doc}, fn entry, {:ok, doc} ->
      case Ankole.Kernel.office_apply(doc, entry.op, [], nil) do
        {:ok, applied} -> {:cont, {:ok, applied.doc_ref}}
        {:busy, _reason} -> {:halt, {:error, :office_busy}}
        {_failure, reason} -> {:halt, {:error, {:invalid_office_file, to_string(reason)}}}
      end
    end)
  end

  defp entries_after(page, revision) do
    OfficeOp
    |> Ash.Query.filter(
      page_id == ^page.id and revision > ^revision and revision <= ^page.revision
    )
    |> Ash.Query.sort(revision: :asc)
    |> Ankole.Ash.read!()
  end

  defp uncompacted(page_id) do
    OfficeOp
    |> Ash.Query.filter(page_id == ^page_id and not compacted)
    |> Ash.Query.sort(revision: :asc)
    |> Ankole.Ash.read!()
  end

  defp office_file(page) do
    with {:ok, format} <- require_office_file(page),
         {:ok, file} <- page_file(page),
         do: {:ok, format, file}
  end

  defp page_file(%Page{type: :file, object_id: id} = page) when not is_nil(id) do
    case Files.list_files(page.id) do
      {:ok, [file]} -> {:ok, file}
      {:ok, _files} -> {:error, :invalid_page_type}
      error -> error
    end
  end

  defp page_file(_page), do: {:error, :invalid_page_type}

  defp require_office_file(page) do
    case kind(page) do
      nil -> {:error, :invalid_page_type}
      format -> {:ok, format}
    end
  end

  defp require_kind(page, expected) do
    if kind(page) == expected, do: :ok, else: {:error, :invalid_page_type}
  end

  defp within(_size, nil), do: :ok
  defp within(nil, _max), do: :ok
  defp within(size, max) when size <= max, do: :ok
  defp within(_size, _max), do: {:error, :file_too_large}

  defp result({:ok, %{result: result}}), do: {:ok, result}
  defp result(error), do: error
end
