defmodule Ankole.Pod.Documents.History do
  @moduledoc "Owns durable document checkpoints and restores under the page row lock."
  require Ash.Query
  alias Ankole.{AuthZ, Kernel, Repo}
  alias Ankole.Pod.{Access, Documents, PageContent, Pages, PageSnapshot, Serialization}

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
          profiles = Serialization.author_profiles(Enum.map(result.results, & &1.author.uid))

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
        profiles = Serialization.author_profiles([snapshot.author.uid])
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
                 Ankole.Ash.update(page, :edit, %{title: snapshot.title, icon: snapshot.icon}),
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
    latest =
      PageSnapshot
      |> Ash.Query.filter(page_id == ^page.id and created_at >= ^cutoff(now))
      |> Ash.Query.sort(created_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:id, :created_at])
      |> Ankole.Ash.read_one!()

    due = is_nil(latest) or DateTime.diff(now, latest.created_at, :second) >= @checkpoint_seconds

    if reason != :checkpoint or due do
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
         {:ok, _} <- AuthZ.authorize_locked_in_tx(actor, page, "page_edit", trash: false),
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
end
