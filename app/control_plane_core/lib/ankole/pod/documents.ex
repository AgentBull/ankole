defmodule Ankole.Pod.Documents do
  @moduledoc """
  Commits complete documents and idempotent OT batches under the page row lock.

  A write runs in a top-level transaction; the page channel gets the commit
  after the transaction ends.
  """
  require Ash.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.Pod.{Access, PageChange, PageContent, Pages}

  def write(uid, id, base_revision, xml, authority \\ nil)

  def write(uid, id, base_revision, xml, authority)
      when is_integer(base_revision) and is_binary(xml) do
    # Validate before the transaction; the page lock decides which error applies.
    validation = Ankole.Kernel.page_validate(xml)

    authority
    |> Access.write(fn -> write_in_tx(uid, id, base_revision, validation) end,
      after_commit: &committed/1
    )
    |> result()
  end

  def write(_uid, _id, _revision, _xml, _authority), do: {:error, :invalid_request}

  @doc false
  def write_in_tx(uid, id, base_revision, validation) do
    commit_in_tx(uid, id, fn page ->
      with :ok <- current_revision(page, base_revision),
           {:ok, parsed} <- validation,
           do: save(page, content!(page), uid, parsed, %{kind: :reset})
    end)
  end

  def apply(uid, id, attrs, authority \\ nil)

  def apply(uid, id, attrs, authority) when is_map(attrs) do
    batch = %{
      base: Ankole.Attrs.get(attrs, :base_revision),
      client: Ankole.Attrs.get(attrs, :client_id),
      seq: Ankole.Attrs.get(attrs, :client_seq),
      changes: Ankole.Attrs.get(attrs, :changes)
    }

    if is_integer(batch.base) and batch.base >= 0 and is_binary(batch.client) and
         byte_size(batch.client) in 1..255 and is_integer(batch.seq) and batch.seq > 0 and
         is_list(batch.changes) do
      authority
      |> Access.write(fn -> apply_in_tx(uid, id, batch) end, after_commit: &committed/1)
      |> result()
    else
      {:error, :invalid_request}
    end
  end

  def apply(_uid, _id, _attrs, _authority), do: {:error, :invalid_request}

  @doc false
  def apply_in_tx(uid, id, %{base: base, client: client, seq: seq, changes: changes}) do
    commit_in_tx(uid, id, fn page ->
      previous =
        PageChange
        |> Ash.Query.filter(page_id == ^page.id and client_id == ^client and client_seq == ^seq)
        |> Ankole.Ash.read_one!()

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
          content = content!(page)

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
  end

  def since(uid, id, revision) when is_integer(revision) and revision >= 0,
    do: Repo.transact_top_level(fn -> since_in_tx(uid, id, revision) end)

  def since(_uid, _id, _revision), do: {:error, :invalid_request}

  @doc false
  def since_in_tx(uid, id, revision) do
    with {:ok, page} <- Pages.lock(id, :share),
         {:ok, _} <- Access.authorize(uid, page, "page_view"),
         true <- page.type == :doc,
         do: {:ok, replay(page, revision)},
         else: (
           false -> {:error, :invalid_page_type}
           error -> error
         )
  end

  @doc "Publishes a committed document change to the page channel."
  def committed(%{page_id: id}), do: Pages.broadcast(id)

  defp replay(page, base) do
    query =
      Ash.Query.filter(
        PageChange,
        page_id == ^page.id and revision > ^base and revision <= ^page.revision
      )

    # Count the stored batches in PostgreSQL before loading any of them. The
    # stored JSON includes more fields and whitespace than the Channel DTO.
    bytes = Ankole.Ash.aggregate!(query, [{:bytes, :sum, field: :wire_bytes}]).bytes || 0

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
      changes = query |> Ash.Query.sort(revision: :asc) |> Ankole.Ash.read!()

      reset_required =
        base > page.revision or
          (base < page.revision and (changes == [] or hd(changes).revision != base + 1))

      %{revision: page.revision, changes: changes, reset_required: reset_required}
    end
  end

  defp commit_in_tx(uid, id, fun) do
    with {:ok, page} <- Pages.lock(id),
         {:ok, _} <- Access.authorize(uid, page, "page_edit"),
         true <- page.type == :doc,
         {:ok, result} <- fun.(page) do
      {:ok, %{page_id: page.id, result: result}}
    else
      false -> {:error, :invalid_page_type}
      error -> error
    end
  end

  defp result({:ok, %{result: result}}), do: {:ok, result}
  defp result(error), do: error

  defp content!(page) do
    PageContent
    |> Ash.Query.filter(page_id == ^page.id)
    |> Ankole.Ash.read_one!(not_found_error?: true)
  end

  defp save(page, content, uid, parsed, change) do
    now = DateTime.utc_now(:microsecond)
    author = ActorRef.from_writer(uid, Repo.tenant_id!(), [])

    with {:ok, window} <- Ankole.Pod.Config.ot_replay_window(),
         {:ok, content} <-
           Ankole.Ash.update(content, :replace, %{
             content: parsed.xml,
             plain_text: parsed.plain_text,
             updated_by: author,
             updated_at: now
           }),
         {:ok, page} <- Ankole.Ash.update(page, :advance_revision, %{updated_at: now}),
         {:ok, _} <-
           Ankole.Ash.create(
             PageChange,
             :append,
             Map.merge(change, %{
               page_id: page.id,
               revision: page.revision,
               author: author,
               created_at: now
             })
           ),
         {:ok, _pruned} <-
           PageChange
           |> Ash.Query.filter(page_id == ^page.id and revision <= ^(page.revision - window))
           |> Ankole.Ash.destroy_where(:prune) do
      {:ok, %{page: page, content: content}}
    end
  end

  defp current_revision(%{revision: revision}, revision), do: :ok
  defp current_revision(page, _base), do: {:error, {:revision_conflict, page.revision}}
end
