defmodule Ankole.Pod.Documents do
  @moduledoc "Commits complete documents and idempotent OT batches under the page row lock."
  import Ecto.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.Pod.{Access, Page, PageChange, PageContent, Pages}

  def write(uid, id, base_revision, xml, authority \\ nil)

  def write(uid, id, base_revision, xml, authority)
      when is_integer(base_revision) and is_binary(xml) do
    validation = Ankole.Kernel.page_validate(xml)

    commit(uid, id, authority, fn page ->
      with :ok <- current_revision(page, base_revision),
           {:ok, parsed} <- validation,
           do: save(page, Repo.get!(PageContent, page.id), uid, parsed, %{kind: :reset})
    end)
  end

  def write(_uid, _id, _revision, _xml, _authority), do: {:error, :invalid_request}

  def apply(uid, id, attrs, authority \\ nil)

  def apply(uid, id, attrs, authority) when is_map(attrs) do
    base = Ankole.Attrs.get(attrs, :base_revision)
    client = Ankole.Attrs.get(attrs, :client_id)
    seq = Ankole.Attrs.get(attrs, :client_seq)
    changes = Ankole.Attrs.get(attrs, :changes)

    if is_integer(base) and base >= 0 and is_binary(client) and byte_size(client) in 1..255 and
         is_integer(seq) and seq > 0 and is_list(changes) do
      commit(uid, id, authority, fn page ->
        previous = Repo.get_by(PageChange, page_id: page.id, client_id: client, client_seq: seq)

        cond do
          previous && previous.changes !== changes ->
            {:error, :client_sequence_conflict}

          previous ->
            {:ok, Map.put(replay(page, base), :acknowledged_revision, previous.revision)}

          base != page.revision ->
            # Retries keep their original base even after their log entry is pruned.
            # A committed batch advanced the revision and cannot reach apply again.
            {:ok, replay(page, base)}

          true ->
            content = Repo.get!(PageContent, page.id)

            with {:ok, parsed} <- Ankole.Kernel.page_apply(content.content, changes),
                 {:ok, %{page: page}} <-
                   save(page, content, uid, parsed, %{
                     kind: :change,
                     client_id: client,
                     client_seq: seq,
                     changes: changes
                   }) do
              {:ok, Map.put(replay(page, base), :acknowledged_revision, page.revision)}
            end
        end
      end)
    else
      {:error, :invalid_request}
    end
  end

  def apply(_uid, _id, _attrs, _authority), do: {:error, :invalid_request}

  def since(uid, id, revision) when is_integer(revision) and revision >= 0 do
    Repo.transact(fn _repo ->
      with {:ok, page} <- Pages.lock(id, :share),
           {:ok, _} <- Access.authorize(uid, page, "page_view"),
           true <- page.type == :doc,
           do: {:ok, replay(page, revision)},
           else: (
             false -> {:error, :invalid_page_type}
             error -> error
           )
    end)
  end

  def since(_uid, _id, _revision), do: {:error, :invalid_request}

  defp replay(page, base) do
    query =
      from(c in PageChange,
        where: c.page_id == ^page.id and c.revision > ^base and c.revision <= ^page.revision
      )

    # Count the complete stored rows in PostgreSQL before loading any batches.
    # row_to_json includes more metadata and whitespace than the Channel DTO.
    bytes =
      Repo.one(
        from c in query,
          select: coalesce(sum(fragment("octet_length(row_to_json(?)::text)", c)), 0)
      )

    envelope_bytes =
      byte_size(
        Torque.encode!(%{
          revision: page.revision,
          changes: [],
          reset_required: false,
          reload_required: false,
          acknowledged_revision: page.revision
        })
      )

    if bytes + envelope_bytes > Ankole.Pod.DocumentWire.max_bytes() do
      %{revision: page.revision, changes: [], reset_required: true, reload_required: true}
    else
      changes = Repo.all(from c in query, order_by: c.revision)

      reset_required =
        base > page.revision or
          (base < page.revision and (changes == [] or hd(changes).revision != base + 1))

      %{revision: page.revision, changes: changes, reset_required: reset_required}
    end
  end

  defp commit(uid, id, authority, fun) do
    nested? = Repo.in_transaction?()

    result =
      Access.write_transaction(authority, fn _repo ->
        with {:ok, page} <- Pages.lock(id),
             {:ok, _} <- Access.authorize(uid, page, "page_edit"),
             true <- page.type == :doc do
          fun.(page)
        else
          false -> {:error, :invalid_page_type}
          error -> error
        end
      end)

    case result do
      {:ok, result} ->
        if not nested?,
          do: Phoenix.PubSub.broadcast(Ankole.PubSub, "pod-page:" <> id, {:page_committed, id})

        {:ok, result}

      error ->
        error
    end
  end

  defp save(page, content, uid, parsed, change) do
    now = DateTime.utc_now(:microsecond)
    author = ActorRef.from_writer(uid, Repo.tenant_id!(), [])

    with {:ok, window} <- Ankole.Pod.Config.ot_replay_window(),
         {:ok, content} <-
           Repo.update(
             PageContent.changeset(content, %{
               content: parsed.xml,
               plain_text: parsed.plain_text,
               updated_by: author,
               updated_at: now
             })
           ),
         {:ok, page} <-
           Repo.update(Page.changeset(page, %{revision: page.revision + 1, updated_at: now})),
         {:ok, _} <-
           Repo.insert(
             PageChange.changeset(
               %PageChange{},
               Map.merge(change, %{
                 page_id: page.id,
                 revision: page.revision,
                 author: author,
                 created_at: now
               })
             )
           ) do
      Repo.delete_all(
        from(change in PageChange,
          where: change.page_id == ^page.id and change.revision <= ^(page.revision - window)
        )
      )

      {:ok, %{page: page, content: content}}
    end
  end

  defp current_revision(%{revision: revision}, revision), do: :ok
  defp current_revision(page, _base), do: {:error, {:revision_conflict, page.revision}}
end
