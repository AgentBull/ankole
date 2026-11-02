defmodule Ankole.Pod.Spreadsheets do
  @moduledoc """
  Owns spreadsheet pages: their operation log, compaction, and search cache.

  A spreadsheet page is a file page whose file name ends in `.xlsx` or
  `.xlsm` (`spreadsheet?/1`). Its logical state is the page's Drive object
  plus the operations in `pod_spreadsheet_ops` that are not `compacted`. An
  editor commits one operation at a time under the page row lock: the kernel
  rebases the operation over the operations committed after the author's base
  revision, or rejects it with an explicit conflict. Compaction exports the
  document, names the new object at the page, and marks the exported
  operations `compacted`; a reader that needs the latest bytes calls
  `flush_if_dirty/1` first. Drive reports every other object that a writer
  names at a file page (an upload, an Agent Drive write, or a restore) to
  `object_committed_in_tx/3`, which marks every earlier operation `compacted`
  and appends a `reset` entry. Spreadsheet versions are snapshots in the page
  history (`Ankole.Pod.Documents.History`).

  `NodeCache` keeps opened documents on each node. It never owns state: a miss
  reopens the page's object and replays the uncompacted operations. Writes run
  in top-level transactions; the `*_in_tx` functions run in the caller's
  transaction and do not publish.
  """
  require Ash.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.AuthZ.Actor
  alias Ankole.Files, as: Drive
  alias Ankole.Files.Access
  alias Ankole.Pod.{Config, FileCache, Files, Page, Pages, Serialization, SpreadsheetOp}
  alias Ankole.Pod.Documents.History
  alias Ankole.Pod.Jobs.CompactSpreadsheet
  alias __MODULE__.NodeCache

  # Drive appends ` (n)` to a name that a sibling already holds, so a second
  # `Budget.xlsx` in one folder is named `Budget.xlsx (1)`.
  @name ~r/\.xls[xm](?: \(\d+\))?$/i
  # The operations that move cells, so that replaying them recalculates the whole workbook.
  @structural ~w(line.insert line.delete cells.insert cells.delete range.move)
  # The operations that carry picture bytes. The log holds the bytes only until compaction
  # writes the picture into the file.
  @picture_ops ~w(image.insert cell.picture)

  @doc """
  Whether a file name, or a page through its file, is a spreadsheet.

  A spreadsheet page is a file page with an object whose name ends in `.xlsx`
  or `.xlsm`, ignoring case, optionally followed by the ` (n)` that Drive adds
  to a duplicate name.
  """
  def spreadsheet?(name) when is_binary(name), do: Regex.match?(@name, name)

  def spreadsheet?(%Page{type: :file, object_id: id, name: name}) when not is_nil(id),
    do: spreadsheet?(name)

  def spreadsheet?(_page), do: false

  @doc """
  Creates a file page with a blank workbook named after `title` (default `Untitled`).

  `attrs` place the page like `Ankole.Pod.Pages.create/3`. The page, its file,
  its search cache, and its `created` version commit in one transaction.
  """
  def create_blank(%Actor{} = actor, attrs) when is_map(attrs) do
    title = String.trim(Ankole.Attrs.get(attrs, :title) || "")

    name =
      cond do
        title == "" -> "Untitled.xlsx"
        spreadsheet?(title) -> title
        true -> title <> ".xlsx"
      end

    place = Map.take(attrs, [:parent_id, :private_owner_uid, "parent_id", "private_owner_uid"])

    with {:ok, blank} <- Ankole.Kernel.spreadsheet_create_blank(Path.rootname(name)),
         do: Files.create_from_upload(actor, place, name, blank.xlsx_bytes, nil)
  end

  @doc """
  Returns what an editor loads: the current file, the uncompacted operations, and the cached metadata.

  The editor downloads the file pinned to its digest and replays `ops` in
  order to reach `revision`. A file larger than `max_file_bytes` returns
  `{:error, :file_too_large}`; the browser then offers the download only.
  """
  def bootstrap(%Actor{} = actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _page} <- Access.authorize(actor, page, "node_view"),
           {:ok, file} <- spreadsheet_file(page),
           {:ok, limits} <- Config.spreadsheet_limits(),
           :ok <- within(file.size, limits.max_file_bytes) do
        cache =
          FileCache
          |> Ash.Query.filter(page_id == ^page.id and object_id == ^file.object_id)
          |> Ankole.Ash.read_one!()

        {:ok,
         %{
           page_id: page.id,
           revision: page.revision,
           file: Files.entry(file),
           ops:
             page.id
             |> uncompacted()
             |> Enum.map(&Map.take(&1, [:revision, :client_id, :client_seq, :op])),
           metadata: cache && cache.metadata
         }}
      end
    end)
  end

  @doc """
  Commits one operation against the author's base revision.

  `attrs` carry `base_revision`, `client_id`, `client_seq`, and `op`. The
  result carries the page `revision`, the entries committed after
  `base_revision` (`changes`), `reset_required`, and, once the operation is
  committed, `acknowledged_revision`. A retry with the same client sequence
  acknowledges the earlier commit, and a different operation under that
  sequence is a `:client_sequence_conflict`. An operation that the kernel
  cannot rebase returns `{:spreadsheet_conflict, %{reason, revision, changes}}`
  so that the editor can replay the missing changes and let the author confirm
  the edit again.
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

    if valid_request?(request) do
      request =
        Map.merge(request, %{
          digest: :crypto.hash(:sha256, Torque.encode!(request.op)),
          op: own_comment(actor, request.op)
        })

      # Opening a document reads the object store, so it happens before the row lock.
      with {:ok, page} <- Pages.authorize(actor, page_id, "node_edit"),
           :ok <- require_spreadsheet(page),
           {:ok, limits} <- Config.spreadsheet_limits(),
           {:ok, document} <- latest(page_id, limits.max_file_bytes) do
        authority
        |> Access.write(fn -> apply_in_tx(actor, page_id, request, document, limits) end,
          after_commit: &committed/1
        )
        |> result()
      end
    else
      {:error, :invalid_request}
    end
  end

  def apply_op(_actor, _page_id, _attrs, _authority), do: {:error, :invalid_request}

  defp valid_request?(%{base: base, client: client, seq: seq, op: op}) do
    is_integer(base) and base >= 0 and is_binary(client) and byte_size(client) in 1..255 and
      is_integer(seq) and seq > 0 and is_map(op)
  end

  # The server names the author of a note; the client's value is never trusted.
  defp own_comment(actor, %{"type" => "comment.set"} = op),
    do: Map.put(op, "author", Ankole.Principals.display_name(actor.principal))

  defp own_comment(_actor, op), do: op

  @doc false
  def apply_in_tx(%Actor{} = actor, page_id, request, document, limits) do
    with {:ok, page} <- Pages.lock(page_id),
         {:ok, _page} <- Access.authorize(actor, page, "node_edit"),
         :ok <- require_spreadsheet(page) do
      previous =
        SpreadsheetOp
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
          commit_op(actor, page, request, document, limits)
      end
    end
  end

  defp commit_op(actor, page, request, document, limits) do
    case replay(page, request.base) do
      # A reset, a pruned entry, or a base ahead of the page cannot be rebased.
      %{reset_required: true} = replayed ->
        {:ok, %{page_id: page.id, result: replayed}}

      %{changes: prior} ->
        with :ok <- picture_room(page, request.op, limits),
             {:ok, doc} <- catch_up(document, page),
             {:ok, applied} <- rebase(doc, request.op, prior, page) do
          save(actor, page, request, prior, applied, limits)
        end
    end
  end

  # A picture must leave the workbook editable, so the file, the pending log, and the
  # picture together stay within the editing limit.
  defp picture_room(page, %{"type" => type, "picture" => %{"data" => data}}, limits)
       when type in @picture_ops and is_binary(data) and is_integer(limits.max_file_bytes) do
    with {:ok, file} <- page_file(page) do
      pending =
        SpreadsheetOp
        |> Ash.Query.filter(page_id == ^page.id and not compacted)
        |> Ankole.Ash.aggregate!([{:bytes, :sum, field: :wire_bytes}])
        |> Map.fetch!(:bytes)

      picture = div(byte_size(data) * 3, 4)

      if (file.size || 0) + (pending || 0) + picture <= limits.max_file_bytes,
        do: :ok,
        else: {:error, :spreadsheet_full}
    end
  end

  defp picture_room(_page, _op, _limits), do: :ok

  defp rebase(doc, op, prior, page) do
    case Ankole.Kernel.spreadsheet_apply(doc, op, Enum.map(prior, & &1.op)) do
      {:ok, applied} ->
        {:ok, applied}

      {:conflict, reason} ->
        {:error,
         {:spreadsheet_conflict,
          %{
            reason: reason,
            revision: page.revision,
            changes: Enum.map(prior, &Serialization.spreadsheet_op_json/1)
          }}}

      {:error, message} ->
        {:error, {:invalid_operation, message}}
    end
  end

  defp save(actor, page, request, prior, applied, limits) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, page} <- Pages.update_properties_in_tx(page, :advance_revision, %{updated_at: now}),
         {:ok, entry} <-
           Ankole.Ash.create(SpreadsheetOp, :append, %{
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
         :ok <- schedule_compaction_in_tx(page.id, now, limits, applied) do
      {:ok,
       %{
         page_id: page.id,
         document: {page.revision, applied.doc_ref},
         result: %{
           revision: page.revision,
           changes: prior ++ [entry],
           reset_required: false,
           acknowledged_revision: page.revision
         }
       }}
    end
  end

  # Every commit postpones the idle compaction. A picture, enough pending
  # operations, or enough structural ones, which recalculate the whole workbook
  # on replay, wake it now.
  defp schedule_compaction_in_tx(page_id, now, limits, applied) do
    args = %{page_id: page_id}
    due = DateTime.add(now, limits.compaction_idle_seconds, :second)

    with :ok <- Ankole.Job.schedule_in_tx(CompactSpreadsheet, args, due) do
      if compaction_due?(page_id, limits, applied),
        do: Ankole.Job.schedule_in_tx(CompactSpreadsheet, args, now, only_earlier: true),
        else: :ok
    end
  end

  defp compaction_due?(_page_id, _limits, %{committed_op: %{"type" => type}})
       when type in @picture_ops,
       do: true

  defp compaction_due?(page_id, limits, %{structural_edit: structural_edit}) do
    pending = Ash.Query.filter(SpreadsheetOp, page_id == ^page_id and not compacted)

    Ankole.Ash.count!(pending) >= limits.compaction_op_threshold or
      (not is_nil(structural_edit) and
         pending
         |> Ash.Query.filter(op[:type] in ^@structural)
         |> Ankole.Ash.count!() >= limits.compaction_structural_threshold)
  end

  @doc "Caches the committed document on this node and publishes the commit to the page channel."
  def committed(%{page_id: id, document: {revision, doc}}) do
    NodeCache.put({Repo.tenant_id!(), id}, revision, doc)
    Pages.broadcast(id)
  end

  def committed(_result), do: :ok

  @doc """
  Returns the entries committed after `revision`, for an editor that catches up.

  `reset_required` asks the editor to bootstrap again: the file was replaced,
  the log no longer holds an entry it needs, or the entries exceed one channel
  message.
  """
  def since(%Actor{} = actor, page_id, revision) when is_integer(revision) and revision >= 0 do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _page} <- Access.authorize(actor, page, "node_view"),
           :ok <- require_spreadsheet(page),
           do: {:ok, replay(page, revision)}
    end)
  end

  def since(_actor, _page_id, _revision), do: {:error, :invalid_request}

  defp replay(page, base) do
    query =
      Ash.Query.filter(
        SpreadsheetOp,
        page_id == ^page.id and revision > ^base and revision <= ^page.revision
      )

    # Count the stored entries in PostgreSQL before loading any of them.
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

  # The entries continue `from` without a gap up to `to`, and none replaced the file.
  defp contiguous?(entries, from, to) do
    Enum.map(entries, & &1.revision) == Enum.to_list((from + 1)..to//1) and
      Enum.all?(entries, &(&1.kind == :op))
  end

  @doc """
  Writes the uncompacted operations of a page into its file before a reader takes the bytes.

  Nothing happens, at the cost of one index probe, when every operation is
  compacted. Otherwise the export runs outside any transaction and the commit
  names the new object at the page without advancing the page revision.
  Operations committed during the export stay uncompacted for the next flush.
  The call must run outside a transaction.
  """
  def flush_if_dirty(page_id) do
    with {:ok, id} <- Ecto.UUID.cast(page_id),
         true <- pending?(id),
         {:ok, {revision, doc}} <- latest(id, nil),
         {:ok, export} <- Ankole.Kernel.spreadsheet_export_xlsx(doc),
         {:ok, stored} <- Drive.store(export.xlsx_bytes),
         {:ok, _flushed} <-
           Repo.transact_top_level(fn -> compact_in_tx(id, revision, stored, export) end) do
      :ok
    else
      :error -> :ok
      false -> :ok
      error -> error
    end
  end

  defp pending?(page_id),
    do:
      SpreadsheetOp
      |> Ash.Query.filter(page_id == ^page_id and not compacted)
      |> Ankole.Ash.exists?()

  @doc "Wakes compaction now when the page has uncompacted operations, as when its last editor leaves."
  def compact_now(page_id) do
    if pending?(page_id),
      do:
        Ankole.Job.schedule(
          CompactSpreadsheet,
          %{page_id: page_id},
          DateTime.utc_now(:microsecond),
          only_earlier: true
        ),
      else: :ok
  end

  @doc false
  def compact_in_tx(page_id, revision, stored, export) do
    with {:ok, page} <- Pages.lock(page_id) do
      exported =
        SpreadsheetOp
        |> Ash.Query.filter(page_id == ^page.id and not compacted and revision <= ^revision)

      # Without uncompacted operations up to the export, another flush or a
      # replaced file already covers this revision.
      if Ankole.Ash.exists?(exported) do
        compact_exported_in_tx(page, exported, revision, stored, export)
      else
        {:ok, :current}
      end
    end
  end

  defp compact_exported_in_tx(page, exported, revision, stored, export) do
    now = DateTime.utc_now(:microsecond)

    [first] =
      exported |> Ash.Query.sort(revision: :asc) |> Ash.Query.limit(1) |> Ankole.Ash.read!()

    [last] =
      exported |> Ash.Query.sort(revision: :desc) |> Ash.Query.limit(1) |> Ankole.Ash.read!()

    with {:ok, window} <- Config.ot_replay_window(),
         {:ok, current} <- Drive.fetch_object(page.object_id),
         :ok <- keep_original_in_tx(page, current, first.revision - 1, first.author, now),
         {:ok, file} <- Drive.rewrite_node_object_in_tx(page.id, stored),
         {:ok, _compacted} <- Ankole.Ash.update_where(exported, :compact),
         :ok <- put_cache_in_tx(page.id, file.object_id, export, now),
         :ok <-
           History.file_checkpoint_in_tx(
             page,
             %{id: file.object_id, sha256: file.sha256},
             revision,
             last.author,
             now
           ),
         {:ok, _pruned} <-
           SpreadsheetOp
           |> Ash.Query.filter(
             page_id == ^page.id and compacted and revision <= ^(page.revision - window)
           )
           |> Ankole.Ash.destroy_where(:prune) do
      {:ok, :compacted}
    end
  end

  # A workbook that reached its page without a history keeps its original
  # file as its `created` version before the first compaction replaces it.
  defp keep_original_in_tx(page, object, revision, author, now) do
    if History.kept_in_tx?(page.id),
      do: :ok,
      else: History.append_file_in_tx(page, object, revision, :created, author, now)
  end

  @doc """
  Keeps a spreadsheet page's current object in its history before a Pod upload replaces it.

  The upload renames the page to the uploaded file before Drive names the new
  object, so the replaced version takes its own name here, in the caller's
  transaction; `object_committed_in_tx/3` then finds it kept.
  """
  def keep_replaced_in_tx(%Actor{} = actor, %Page{type: :file, object_id: id} = page)
      when not is_nil(id) do
    if logged?(page.id),
      do:
        keep_previous_in_tx(
          page,
          id,
          page.revision,
          ActorRef.from_actor(actor),
          DateTime.utc_now(:microsecond)
        ),
      else: :ok
  end

  def keep_replaced_in_tx(_actor, _page), do: :ok

  @doc """
  Records an object that a writer named at a file page, in the caller's transaction.

  `Ankole.Pod.ContentOwner` calls this after Drive names `node.object_id` at
  the page; `previous` is the node before the write. A page that is a
  spreadsheet now, or that kept an operation log before, compacts every
  pending operation and appends a `reset` entry at a new revision. Its history
  keeps the replaced object as a `checkpoint` and the new spreadsheet as
  `created` or `uploaded` unless a retained snapshot already names that
  object, so a restore that records its own `before_restore` and `restored`
  snapshots adds none here. The search cache follows the new object.
  """
  def object_committed_in_tx(%Actor{} = actor, previous, node) do
    logged? = logged?(node.id)

    if logged? or spreadsheet?(node.name) do
      now = DateTime.utc_now(:microsecond)
      author = ActorRef.from_actor(actor)

      with {:ok, page} <-
             Pages.update_properties_in_tx(node, :advance_revision, %{updated_at: now}),
           {:ok, _compacted} <-
             SpreadsheetOp
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
             Ankole.Ash.create(SpreadsheetOp, :append, %{
               page_id: page.id,
               revision: page.revision,
               kind: :reset,
               compacted: true,
               author: author,
               created_at: now
             }),
           {:ok, object} <- Drive.fetch_object(node.object_id),
           :ok <- keep_new_in_tx(page, object, previous.object_id, author, now),
           {:ok, derived} <- derive(node.name, object),
           do: put_cache_in_tx(page.id, object.id, derived, now)
    else
      :ok
    end
  end

  defp logged?(page_id),
    do: SpreadsheetOp |> Ash.Query.filter(page_id == ^page_id) |> Ankole.Ash.exists?()

  # A page that kept a log was a spreadsheet, so its replaced object stays in
  # the history unless a retained snapshot names it already.
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

    if not spreadsheet?(page.name) or History.file_kept_in_tx?(page.id, object.id),
      do: :ok,
      else: History.append_file_in_tx(page, object, page.revision, reason, author, now)
  end

  # A workbook that the kernel can read within `max_file_bytes` gets search
  # text and metadata. Any other file stays an ordinary file: its page offers
  # the download, and an edit fails with `:invalid_spreadsheet`.
  defp derive(name, object) do
    with true <- spreadsheet?(name),
         {:ok, limits} <- Config.spreadsheet_limits(),
         :ok <- within(object.size, limits.max_file_bytes),
         {:ok, bytes} <- Drive.read_object(object.id),
         {:ok, opened} <- Ankole.Kernel.spreadsheet_open(bytes, []) do
      {:ok, Map.take(opened, [:plain_text, :metadata])}
    else
      false -> {:ok, nil}
      {:error, :file_too_large} -> {:ok, nil}
      {:error, message} when is_binary(message) -> {:ok, nil}
      error -> error
    end
  end

  defp put_cache_in_tx(page_id, _object_id, nil, _now) do
    with {:ok, _purged} <-
           FileCache |> Ash.Query.filter(page_id == ^page_id) |> Ankole.Ash.destroy_where(:purge),
         do: :ok
  end

  defp put_cache_in_tx(page_id, object_id, derived, now) do
    with {:ok, _cache} <-
           Ankole.Ash.create(FileCache, :put, %{
             page_id: page_id,
             subtype: :spreadsheet,
             object_id: object_id,
             plain_text: derived.plain_text,
             metadata: derived.metadata,
             updated_at: now
           }),
         do: :ok
  end

  @doc """
  Lists a spreadsheet page's versions from the page history, newest first.

  Like document history, the list requires `node_edit`, so sharing the current
  workbook with a viewer does not expose earlier ones.
  """
  def versions(%Actor{} = actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(page_id, :share),
           {:ok, _page} <- Access.authorize(actor, page, "node_edit"),
           :ok <- require_spreadsheet(page),
           do: {:ok, History.file_snapshots_in_tx(page.id)}
    end)
  end

  @doc """
  Makes a version the page's file again.

  Pending operations are written into the current file first, so its
  `before_restore` version holds everything editors committed. The restored
  object takes the version's file name and resets the log like an upload, and
  the page history records it as `restored`.
  """
  def restore(actor, page_id, version_id, authority \\ nil)

  def restore(%Actor{} = actor, page_id, version_id, authority) do
    authority = authority || actor.turn_authority

    with {:ok, _page} <- Pages.authorize(actor, page_id, "node_edit"),
         {:ok, version_id} <- cast_id(version_id),
         :ok <- flush_if_dirty(page_id) do
      Access.write_tree(authority, fn -> restore_in_tx(actor, page_id, version_id) end,
        root_ids: fn -> Drive.root_ids([page_id]) end,
        after_commit: &Files.committed/1
      )
    end
  end

  @doc false
  def restore_in_tx(%Actor{} = actor, page_id, version_id) do
    author = ActorRef.from_actor(actor)

    with {:ok, page} <- Pages.lock(page_id),
         {:ok, _page} <- Access.authorize(actor, page, "node_edit"),
         {:ok, current} <- spreadsheet_file(page),
         {:ok, version} <- History.fetch_file_in_tx(page.id, version_id),
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
         {:ok, file} <- spreadsheet_file(page) do
      {:ok, %{page_id: page.id, revision: page.revision, file: Files.entry(file)}}
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  # Returns the document at the latest committed revision: the node's cached
  # document brought forward by the entries committed since, or the page's
  # object reopened with its uncompacted operations. `max_bytes` bounds the
  # file that an editor may open; compaction opens any size.
  defp latest(page_id, max_bytes) do
    with {:ok, id} <- cast_id(page_id),
         key = {Repo.tenant_id!(), id},
         cached = NodeCache.fetch(key),
         {:ok, plan} <- Repo.transact_top_level(fn -> plan_in_tx(id, cached) end),
         {:ok, revision, doc} <- load(plan, max_bytes) do
      if not match?({:cached, _revision, _doc}, plan), do: NodeCache.put(key, revision, doc)
      {:ok, {revision, doc}}
    end
  end

  # The log replays on the page's current object whatever its name, so a page
  # renamed away from `.xlsx` still flushes the edits it took as a spreadsheet.
  defp plan_in_tx(page_id, cached) do
    with {:ok, page} <- Pages.lock(page_id, :share),
         {:ok, file} <- page_file(page) do
      case cached do
        {:ok, revision, doc} when revision == page.revision ->
          {:ok, {:cached, revision, doc}}

        {:ok, revision, doc} when revision < page.revision ->
          entries = entries_after(page, revision)

          if contiguous?(entries, revision, page.revision),
            do: {:ok, {:replay, page.revision, doc, entries}},
            else: {:ok, {:open, page.revision, file, uncompacted(page.id)}}

        _miss ->
          {:ok, {:open, page.revision, file, uncompacted(page.id)}}
      end
    end
  end

  defp load({:cached, revision, doc}, _max_bytes), do: {:ok, revision, doc}

  defp load({:replay, revision, doc, entries}, _max_bytes) do
    with {:ok, doc} <- replay_entries(doc, entries), do: {:ok, revision, doc}
  end

  defp load({:open, revision, file, entries}, max_bytes) do
    with :ok <- within(file.size, max_bytes),
         {:ok, bytes} <- Drive.read_object(file.object_id) do
      case Ankole.Kernel.spreadsheet_open(bytes, Enum.map(entries, & &1.op)) do
        {:ok, opened} -> {:ok, revision, opened.doc_ref}
        {:error, message} -> {:error, {:invalid_spreadsheet, message}}
      end
    end
  end

  # Brings a document forward inside the row lock. Another editor may have
  # committed since this request opened the document; a reset in between
  # makes the request retry.
  defp catch_up({revision, doc}, %{revision: revision}), do: {:ok, doc}

  defp catch_up({revision, doc}, page) when revision < page.revision do
    entries = entries_after(page, revision)

    if contiguous?(entries, revision, page.revision),
      do: replay_entries(doc, entries),
      else: {:error, :spreadsheet_busy}
  end

  defp catch_up(_document, _page), do: {:error, :spreadsheet_busy}

  # Committed operations are already rebased, so they replay without prior operations.
  defp replay_entries(doc, entries) do
    Enum.reduce_while(entries, {:ok, doc}, fn entry, {:ok, doc} ->
      case Ankole.Kernel.spreadsheet_apply(doc, entry.op, []) do
        {:ok, applied} -> {:cont, {:ok, applied.doc_ref}}
        {_failure, reason} -> {:halt, {:error, {:invalid_spreadsheet, to_string(reason)}}}
      end
    end)
  end

  defp entries_after(page, revision) do
    SpreadsheetOp
    |> Ash.Query.filter(
      page_id == ^page.id and revision > ^revision and revision <= ^page.revision
    )
    |> Ash.Query.sort(revision: :asc)
    |> Ankole.Ash.read!()
  end

  defp uncompacted(page_id) do
    SpreadsheetOp
    |> Ash.Query.filter(page_id == ^page_id and not compacted)
    |> Ash.Query.sort(revision: :asc)
    |> Ankole.Ash.read!()
  end

  defp spreadsheet_file(page) do
    with :ok <- require_spreadsheet(page), do: page_file(page)
  end

  defp page_file(%Page{type: :file, object_id: id} = page) when not is_nil(id) do
    case Files.list_files(page.id) do
      {:ok, [file]} -> {:ok, file}
      {:ok, _files} -> {:error, :invalid_page_type}
      error -> error
    end
  end

  defp page_file(_page), do: {:error, :invalid_page_type}

  defp require_spreadsheet(page),
    do: if(spreadsheet?(page), do: :ok, else: {:error, :invalid_page_type})

  defp within(_size, nil), do: :ok
  defp within(nil, _max), do: :ok
  defp within(size, max) when size <= max, do: :ok
  defp within(_size, _max), do: {:error, :file_too_large}

  defp result({:ok, %{result: result}}), do: {:ok, result}
  defp result(error), do: error
end
