defmodule Ankole.Pod.Documents.History do
  @moduledoc """
  Owns durable page checkpoints and their retention under the page row lock.

  A document snapshot keeps the document XML, and this module also restores
  it. A spreadsheet snapshot names the file object that held the workbook;
  `Ankole.Pod.Spreadsheets` lists and restores those. Both kinds share one
  checkpoint interval, retention period, and per-page limit.
  """
  require Ash.Query
  alias Ankole.{AuthZ, Kernel, Repo}
  alias Ankole.Files.Access
  alias Ankole.Pod.{Documents, PageContent, Pages, PageSnapshot, Serialization}

  @checkpoint_seconds 300
  @retention_days 30
  @max_snapshots 200
  @summary_fields [
    :id,
    :page_id,
    :revision,
    :title,
    :icon,
    :author,
    :document_updated_at,
    :created_at,
    :reason
  ]

  def list(actor, id, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- authorized_page(actor, id, :share) do
        limit = Ankole.Attrs.get(opts, :limit, 50)
        cursor = Ankole.Attrs.get(opts, :cursor)
        pagination = if cursor, do: [limit: limit, after: cursor], else: [limit: limit]

        query =
          PageSnapshot
          |> Ash.Query.for_read(:list)
          |> Ash.Query.filter(page_id == ^page.id and created_at >= ^cutoff())
          |> Ash.Query.sort(created_at: :desc, id: :desc)
          |> Ash.Query.select(@summary_fields)

        with {:ok, result} <- Ankole.Ash.read(query, page: pagination) do
          profiles = Serialization.author_profiles(Enum.map(result.results, & &1.author))

          {:ok,
           %{
             snapshots: Enum.map(result.results, &present(&1, profiles)),
             next_cursor: if(result.more?, do: List.last(result.results).__metadata__.keyset),
             current_revision: page.revision,
             current_updated_at: page.updated_at
           }}
        end
      end
    end)
  end

  def read(actor, id, snapshot_id) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- authorized_page(actor, id, :share),
           {:ok, snapshot} <- fetch(page.id, snapshot_id) do
        profiles = Serialization.author_profiles([snapshot.author])
        {:ok, %{snapshot: Map.put(present(snapshot, profiles), :content, snapshot.content)}}
      end
    end)
  end

  def restore(%Ankole.AuthZ.Actor{} = actor, id, snapshot_id, base_revision, updated_at) do
    Access.write(
      actor.turn_authority,
      fn ->
        with {:ok, page} <- authorized_page(actor, id, :update),
             :ok <- current(page, base_revision, updated_at),
             {:ok, snapshot} <- fetch(page.id, snapshot_id) do
          content = content!(page.id)

          with {:ok, parsed} <- Kernel.page_restore_comments(content.content, snapshot.content),
               :ok <-
                 checkpoint_in_tx(page, content, DateTime.utc_now(:microsecond), :before_restore),
               {:ok, page} <-
                 Ankole.Pod.Pages.update_properties_in_tx(
                   page,
                   :edit,
                   restored_metadata(page, snapshot)
                 ),
               {:ok, %{page: restored, content: content} = result} <-
                 Documents.commit_parsed_in_tx(page, content, actor, parsed, force: true),
               :ok <-
                 checkpoint_in_tx(restored, content, DateTime.utc_now(:microsecond), :restored) do
            {:ok, result}
          end
        end
      end,
      after_commit: fn %{page: page} -> Pages.committed_page(page) end
    )
  end

  @doc "Captures the current document before a write; the caller holds the page update lock."
  def checkpoint_in_tx(page, content, now, reason \\ :checkpoint) do
    latest = latest_in_tx(page.id, now)

    if reason != :checkpoint or due?(latest, now) do
      with {:ok, info} <- Kernel.page_comment_info(content.content) do
        duplicate =
          reason == :checkpoint and same_checkpoint?(latest, page, info.stripped_xml, now)

        if duplicate do
          :ok
        else
          with {:ok, _} <-
                 Ankole.Ash.create(PageSnapshot, :append, %{
                   page_id: page.id,
                   revision: page.revision,
                   title: page.title,
                   icon: page.icon,
                   content: info.stripped_xml,
                   author: content.updated_by,
                   document_updated_at: page.updated_at,
                   created_at: now,
                   reason: reason
                 }),
               :ok <- prune_in_tx(page.id, now),
               do: :ok
        end
      end
    else
      :ok
    end
  end

  @doc """
  Records a periodic spreadsheet checkpoint; the caller holds the page update lock.

  A file checkpoint follows the document rule: it is due once the newest
  snapshot is older than the checkpoint interval, and it is skipped when that
  snapshot already holds the same bytes. `object` carries `id` and `sha256`.
  """
  def file_checkpoint_in_tx(page, object, revision, author, now) do
    latest = latest_in_tx(page.id, now)

    if due?(latest, now) and not same_file?(latest, object),
      do: append_file_in_tx(page, object, revision, :checkpoint, author, now),
      else: :ok
  end

  @doc """
  Appends a snapshot that names a spreadsheet's file object; the caller holds the page update lock.

  The snapshot takes the page's current file name as its title, and the
  page's history limit applies afterwards.
  """
  def append_file_in_tx(page, object, revision, reason, author, now) do
    with {:ok, _} <-
           Ankole.Ash.create(PageSnapshot, :append, %{
             page_id: page.id,
             revision: revision,
             title: page.name,
             object_id: object.id,
             author: author,
             document_updated_at: now,
             created_at: now,
             reason: reason
           }),
         do: prune_in_tx(page.id, now)
  end

  @doc "Whether a retained snapshot of the page names the object."
  def file_kept_in_tx?(page_id, object_id),
    do:
      PageSnapshot
      |> Ash.Query.filter(
        page_id == ^page_id and object_id == ^object_id and created_at >= ^cutoff()
      )
      |> Ankole.Ash.exists?()

  @doc "Whether the page keeps any retained snapshot."
  def kept_in_tx?(page_id),
    do:
      PageSnapshot
      |> Ash.Query.filter(page_id == ^page_id and created_at >= ^cutoff())
      |> Ankole.Ash.exists?()

  @doc "Lists the retained spreadsheet snapshots of a page, newest first, with their object digests and sizes."
  def file_snapshots_in_tx(page_id),
    do:
      PageSnapshot
      |> file_query(page_id)
      |> Ash.Query.sort(created_at: :desc, id: :desc)
      |> Ankole.Ash.read!()

  @doc "Returns one retained spreadsheet snapshot of a page."
  def fetch_file_in_tx(page_id, id) do
    case PageSnapshot
         |> file_query(page_id)
         |> Ash.Query.filter(id == ^id)
         |> Ankole.Ash.read_one!() do
      nil -> {:error, :not_found}
      snapshot -> {:ok, snapshot}
    end
  end

  defp file_query(query, page_id),
    do:
      query
      |> Ash.Query.filter(
        page_id == ^page_id and not is_nil(object_id) and created_at >= ^cutoff()
      )
      |> Ash.Query.load([:sha256, :size])

  defp latest_in_tx(page_id, now),
    do:
      PageSnapshot
      |> Ash.Query.filter(page_id == ^page_id and created_at >= ^cutoff(now))
      |> Ash.Query.sort(created_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:id, :created_at, :object_id])
      |> Ash.Query.load(:sha256)
      |> Ankole.Ash.read_one!()

  defp due?(latest, now),
    do: is_nil(latest) or DateTime.diff(now, latest.created_at, :second) >= @checkpoint_seconds

  defp same_file?(nil, _object), do: false

  defp same_file?(latest, object),
    do: latest.object_id == object.id or latest.sha256 == object.sha256

  defp cutoff(now \\ DateTime.utc_now(:microsecond)),
    do: DateTime.add(now, -@retention_days * 86_400, :second)

  defp prune_in_tx(page_id, now) do
    keep =
      PageSnapshot
      |> Ash.Query.filter(page_id == ^page_id and created_at >= ^cutoff(now))
      |> Ash.Query.sort(created_at: :desc, id: :desc)
      |> Ash.Query.limit(@max_snapshots)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)

    with {:ok, _} <-
           PageSnapshot
           |> Ash.Query.filter(page_id == ^page_id and id not in ^keep)
           |> Ash.Query.select([:id])
           |> Ankole.Ash.destroy_where(:purge),
         do: :ok
  end

  @doc "Removes expired snapshots in bounded batches for the current tenant."
  def expire(now) do
    result =
      PageSnapshot
      |> Ash.Query.filter(created_at < ^cutoff(now))
      |> Ash.Query.limit(1000)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.destroy_where(:purge)

    case result do
      {:ok, []} -> :ok
      {:ok, _} -> expire(now)
      error -> error
    end
  end

  defp same_checkpoint?(nil, _page, _xml, _now), do: false

  defp same_checkpoint?(latest, page, xml, now) do
    case fetch(page.id, latest.id, now) do
      {:ok, snapshot} ->
        snapshot.content == xml and snapshot.title == page.title and snapshot.icon == page.icon

      {:error, :not_found} ->
        false
    end
  end

  defp authorized_page(actor, id, mode) do
    with {:ok, page} <- Pages.lock(id, mode),
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "node_edit", trash: false),
         true <- page.type == :doc,
         do: {:ok, page},
         else: (
           false -> {:error, :invalid_page_type}
           error -> error
         )
  end

  defp current(page, revision, updated_at) do
    if page.revision == revision and DateTime.compare(page.updated_at, updated_at) == :eq do
      :ok
    else
      {:error,
       {:document_conflict,
        %{revision: page.revision, updated_at: DateTime.to_iso8601(page.updated_at)}}}
    end
  end

  defp fetch(page_id, id, now \\ DateTime.utc_now(:microsecond)) do
    case PageSnapshot
         |> Ash.Query.filter(page_id == ^page_id and id == ^id and created_at >= ^cutoff(now))
         |> Ankole.Ash.read_one!() do
      nil -> {:error, :not_found}
      snapshot -> {:ok, snapshot}
    end
  end

  defp content!(page_id),
    do:
      PageContent
      |> Ash.Query.filter(page_id == ^page_id)
      |> Ankole.Ash.read_one!(not_found_error?: true)

  defp present(snapshot, profiles) do
    snapshot
    |> Map.take(@summary_fields -- [:page_id])
    |> Map.put(:author, Serialization.author_json(snapshot.author, profiles))
  end

  # An unchanged title is not written again, so a title saved before the 255-character limit stays.
  defp restored_metadata(%{title: title}, %{title: title, icon: icon}), do: %{icon: icon}

  defp restored_metadata(_page, snapshot),
    do: %{title: String.slice(snapshot.title, 0, 255), icon: snapshot.icon}
end
