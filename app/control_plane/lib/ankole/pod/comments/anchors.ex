defmodule Ankole.Pod.Comments.Anchors do
  @moduledoc """
  Validates, rebases, persists, cleans up, and presents multimodal comment anchors
  across document XML marks, file coordinates, and Applet UI element selectors.
  """
  require Ash.Query

  alias Ankole.Files.Path, as: FilePath
  alias Ankole.JSON
  alias Ankole.Pod.Comments.Activity
  alias Ankole.Pod.{Documents, OfficeFiles, PageChange, PageComment, PageContent}

  @max_anchor_bytes 1_024
  @max_quote_chars 1_000
  @max_quote_bytes 4_096
  @selection_keys [:anchor, :base_revision, :from, :to, :quote]

  @doc "Checks that native marks refer to live root discussions on their owning page."
  def validate_marks_in_tx(_id, []), do: :ok

  def validate_marks_in_tx(id, ids) do
    existing =
      id
      |> Activity.roots_in_tx()
      |> Ash.Query.filter(id in ^ids)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)

    if MapSet.new(existing) == MapSet.new(ids), do: :ok, else: {:error, :invalid_comment_anchor}
  end

  def anchor_ids_in_tx(%{type: :doc, id: id}) do
    with {:ok, info} <- Ankole.Kernel.page_comment_info(content!(id).content),
         do: {:ok, info.ids}
  end

  def anchor_ids_in_tx(%{type: type}) when type in [:knowledge, :file, :applet, :base],
    do: {:ok, []}

  def present(comment, page, ids, office_file?) do
    root = is_nil(comment.root_id)

    case page.type do
      :doc ->
        {nil, comment.id in ids, false}

      type when type in [:knowledge, :base] ->
        {nil, false, false}

      :applet ->
        outdated =
          root and is_map(comment.anchor) and comment.anchor["revision"] != page.revision

        {comment.anchor, root and is_map(comment.anchor) and not outdated, outdated}

      :file when office_file? ->
        {nil, false, false}

      :file ->
        outdated =
          root and is_map(comment.anchor) and comment.anchor["object_id"] != page.object_id

        present? = root and is_map(comment.anchor) and not outdated
        {comment.anchor, present?, outdated}
    end
  end

  def preview_for_wakeup_in_tx(_page, _comment_id, _body, root, _attrs)
      when not is_nil(root),
      do: {:ok, root}

  def preview_for_wakeup_in_tx(page, comment_id, body, nil, attrs) do
    case resolve_selection(page, comment_id, attrs, :optional, nil) do
      :none ->
        {:ok, %{id: comment_id, body: body, quote: nil, anchor: nil}}

      {:doc, _content, parsed} ->
        {:ok, %{id: comment_id, body: body, quote: parsed.quote, anchor: nil}}

      {:json_anchor, anchor, quote} ->
        {:ok, %{id: comment_id, body: body, quote: quote, anchor: anchor}}

      {:error, _} = error ->
        error
    end
  end

  def maybe_apply_in_tx(actor, page, comment, attrs, change_fn) do
    case resolve_selection(page, comment.id, attrs, :optional, nil) do
      :none -> {:ok, comment, page}
      selection -> apply_selection_in_tx(selection, actor, page, comment, change_fn)
    end
  end

  def put_in_tx(actor, page, comment, attrs, change_fn) do
    page
    |> resolve_selection(comment.id, attrs, :required, comment.quote)
    |> apply_selection_in_tx(actor, page, comment, change_fn)
  end

  def remove_if_empty_in_tx(actor, %{type: :doc} = page, comment, _change_fn) do
    root_id = comment.root_id || comment.id
    root = fetch_root!(page.id, root_id)

    if root.deleted_at && !live_replies?(page.id, root_id) do
      content = content!(page.id)

      with {:ok, parsed} <- Ankole.Kernel.page_comment_remove(content.content, root.id),
           {:ok, %{page: updated}} <-
             Documents.commit_parsed_in_tx(page, content, actor, parsed, attribution: false),
           do: {:ok, updated}
    else
      {:ok, page}
    end
  end

  def remove_if_empty_in_tx(_actor, %{type: type} = page, _comment, _change_fn)
      when type in [:knowledge, :base],
      do: {:ok, page}

  def remove_if_empty_in_tx(actor, %{type: type} = page, comment, change_fn)
      when type in [:file, :applet] do
    root_id = comment.root_id || comment.id
    root = fetch_root!(page.id, root_id)

    if root.deleted_at && !live_replies?(page.id, root_id) &&
         (not is_nil(root.anchor) || not is_nil(root.quote)) do
      with {:ok, _} <- change_fn.(root, actor, %{anchor: nil, quote: nil}), do: {:ok, page}
    else
      {:ok, page}
    end
  end

  defp apply_selection_in_tx({:doc, content, parsed}, actor, page, comment, change_fn) do
    with {:ok, %{page: updated_page}} <-
           Documents.commit_parsed_in_tx(page, content, actor, parsed, attribution: false),
         {:ok, updated} <-
           change_fn.(comment, actor, %{
             quote: comment.quote || parsed.quote,
             anchor_revision: comment.anchor_revision || updated_page.revision
           }) do
      {:ok, updated, updated_page}
    end
  end

  defp apply_selection_in_tx({:json_anchor, anchor, quote}, actor, page, comment, change_fn) do
    with {:ok, updated} <- change_fn.(comment, actor, %{anchor: anchor, quote: quote}),
         do: {:ok, updated, page}
  end

  defp apply_selection_in_tx({:error, _} = error, _actor, _page, _comment, _change_fn),
    do: error

  defp resolve_selection(%{type: :doc} = page, target_id, attrs, mode, _default_quote) do
    cond do
      not is_nil(Ankole.Attrs.get(attrs, :anchor)) ->
        if mode == :optional,
          do: {:error, :invalid_comment_anchor},
          else: {:error, :invalid_request}

      has_any_attr?(attrs, [:base_revision, :from, :to]) ->
        resolve_doc_selection(page, target_id, attrs)

      mode == :required ->
        {:error, :invalid_request}

      not is_nil(Ankole.Attrs.get(attrs, :quote)) ->
        {:error, :invalid_comment_anchor}

      true ->
        :none
    end
  end

  defp resolve_selection(%{type: type}, _target_id, attrs, mode, _default_quote)
       when type in [:knowledge, :base] do
    if mode == :required or has_any_attr?(attrs, @selection_keys),
      do: {:error, :invalid_comment_anchor},
      else: :none
  end

  defp resolve_selection(%{type: :file} = page, _target_id, attrs, mode, default_quote) do
    cond do
      OfficeFiles.office_file?(page) ->
        if mode == :required or has_any_attr?(attrs, @selection_keys),
          do: {:error, :invalid_comment_anchor},
          else: :none

      has_any_attr?(attrs, [:base_revision, :from, :to]) ->
        {:error, :invalid_comment_anchor}

      mode == :required or not is_nil(Ankole.Attrs.get(attrs, :anchor)) ->
        raw_anchor = Ankole.Attrs.get(attrs, :anchor)
        raw_quote = Ankole.Attrs.get(attrs, :quote, default_quote)

        with {:ok, normalized_anchor} <- normalize_file_anchor(raw_anchor, page.object_id),
             {:ok, normalized_quote} <- normalize_file_quote(raw_quote) do
          {:json_anchor, normalized_anchor, normalized_quote}
        end

      not is_nil(Ankole.Attrs.get(attrs, :quote)) ->
        {:error, :invalid_comment_anchor}

      true ->
        :none
    end
  end

  defp resolve_selection(%{type: :applet} = page, _target_id, attrs, mode, default_quote) do
    case applet_selection(page, attrs, default_quote) do
      {:ok, nil, nil} ->
        if mode == :required, do: {:error, :invalid_comment_anchor}, else: :none

      {:ok, anchor, quote} ->
        {:json_anchor, anchor, quote}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_doc_selection(page, target_id, attrs) do
    base = Ankole.Attrs.get(attrs, :base_revision)
    from = Ankole.Attrs.get(attrs, :from)
    to = Ankole.Attrs.get(attrs, :to)

    with true <-
           is_integer(base) and is_integer(from) and is_integer(to) and from >= 0 and to > from,
         {:ok, {mapped_from, mapped_to}} <- resolve_anchor_range(page, base, from, to),
         content = content!(page.id),
         {:ok, parsed} <-
           Ankole.Kernel.page_comment_annotate(content.content, target_id, mapped_from, mapped_to) do
      {:doc, content, parsed}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp applet_selection(page, attrs, default_quote) do
    raw = Ankole.Attrs.get(attrs, :anchor)
    explicit_quote = Ankole.Attrs.get(attrs, :quote)

    cond do
      has_any_attr?(attrs, [:base_revision, :from, :to]) ->
        {:error, :invalid_comment_anchor}

      is_nil(raw) and is_nil(explicit_quote) ->
        {:ok, nil, nil}

      is_map(raw) ->
        anchor = Map.new(raw, fn {key, value} -> {to_string(key), value} end)

        with true <- anchor["kind"] == "applet_element" and anchor["revision"] == page.revision,
             true <-
               Map.keys(anchor) -- ~w(kind revision source component selector text_fingerprint) ==
                 [],
             true <-
               Enum.all?(~w(source component selector text_fingerprint), &is_binary(anchor[&1])),
             true <-
               anchor["selector"] != "" and byte_size(JSON.encode!(anchor)) <= @max_anchor_bytes,
             {:ok, quote} <- normalize_file_quote(Ankole.Attrs.get(attrs, :quote, default_quote)) do
          {:ok, anchor, quote}
        else
          _ -> {:error, :invalid_comment_anchor}
        end

      true ->
        {:error, :invalid_comment_anchor}
    end
  end

  defp normalize_file_anchor(raw, object_id) when is_map(raw) and is_binary(object_id) do
    normalized = Map.new(raw, fn {key, value} -> {to_string(key), value} end)
    kind = Map.get(normalized, "kind")

    with {:ok, fields} <- validate_file_anchor_kind(to_string(kind), normalized),
         true <- Map.get(normalized, "object_id") == object_id do
      anchor = Map.put(fields, "object_id", object_id)

      if byte_size(JSON.encode!(anchor)) <= @max_anchor_bytes do
        {:ok, anchor}
      else
        {:error, :invalid_comment_anchor}
      end
    else
      false -> {:error, :file_anchor_outdated}
      error -> error
    end
  end

  defp normalize_file_anchor(_raw, _object_id), do: {:error, :invalid_comment_anchor}

  defp validate_file_anchor_kind("lines", raw) do
    start_line = Map.get(raw, "start_line")
    end_line = Map.get(raw, "end_line")

    if is_integer(start_line) and start_line >= 1 and is_integer(end_line) and
         end_line >= start_line and end_line <= 1_000_000 do
      {:ok, %{"kind" => "lines", "start_line" => start_line, "end_line" => end_line}}
    else
      {:error, :invalid_comment_anchor}
    end
  end

  defp validate_file_anchor_kind("csv_rows", raw) do
    start_row = Map.get(raw, "start_row")
    end_row = Map.get(raw, "end_row")
    column = Map.get(raw, "column")

    valid_col? =
      is_nil(column) or
        (is_binary(column) and String.trim(column) != "" and String.length(column) <= 128)

    if is_integer(start_row) and start_row >= 1 and is_integer(end_row) and
         end_row >= start_row and end_row <= 1_000_000 and valid_col? do
      base = %{"kind" => "csv_rows", "start_row" => start_row, "end_row" => end_row}

      {:ok,
       if(is_binary(column),
         do: Map.put(base, "column", FilePath.sanitize_inline_text(column)),
         else: base
       )}
    else
      {:error, :invalid_comment_anchor}
    end
  end

  defp validate_file_anchor_kind("md_section", raw) do
    heading = Map.get(raw, "heading")
    level = Map.get(raw, "level") || 1
    start_line = Map.get(raw, "start_line")

    valid_line? = is_nil(start_line) or (is_integer(start_line) and start_line >= 1)

    if is_binary(heading) and String.trim(heading) != "" and String.length(heading) <= 256 and
         is_integer(level) and level in 1..6 and valid_line? do
      cleaned_heading = FilePath.sanitize_inline_text(heading)

      if cleaned_heading == "" do
        {:error, :invalid_comment_anchor}
      else
        base = %{"kind" => "md_section", "heading" => cleaned_heading, "level" => level}
        {:ok, if(is_integer(start_line), do: Map.put(base, "start_line", start_line), else: base)}
      end
    else
      {:error, :invalid_comment_anchor}
    end
  end

  defp validate_file_anchor_kind("media_timestamp", raw) do
    time_sec = Map.get(raw, "time_sec")
    end_sec = Map.get(raw, "end_time_sec")

    valid_end? =
      is_nil(end_sec) or (is_number(end_sec) and end_sec >= time_sec and end_sec <= 864_000)

    if is_number(time_sec) and time_sec >= 0 and time_sec <= 864_000 and valid_end? do
      base = %{"kind" => "media_timestamp", "time_sec" => Float.round(time_sec * 1.0, 3)}

      {:ok,
       if(is_number(end_sec),
         do: Map.put(base, "end_time_sec", Float.round(end_sec * 1.0, 3)),
         else: base
       )}
    else
      {:error, :invalid_comment_anchor}
    end
  end

  defp validate_file_anchor_kind(_kind, _raw), do: {:error, :invalid_comment_anchor}

  defp normalize_file_quote(nil), do: {:ok, nil}

  defp normalize_file_quote(value) when is_binary(value) do
    cleaned = FilePath.strip_bidi(value)

    cond do
      cleaned == "" ->
        {:ok, nil}

      String.length(cleaned) <= @max_quote_chars and byte_size(cleaned) <= @max_quote_bytes ->
        {:ok, cleaned}

      true ->
        {:error, :invalid_comment_quote}
    end
  end

  defp normalize_file_quote(_value), do: {:error, :invalid_comment_quote}

  defp resolve_anchor_range(%{revision: rev}, rev, from, to), do: {:ok, {from, to}}

  defp resolve_anchor_range(%{id: page_id, revision: rev}, base, from, to)
       when is_integer(base) and base >= 0 and base < rev and rev - base <= 1_000 do
    rows =
      PageChange
      |> Ash.Query.filter(page_id == ^page_id and revision > ^base and revision <= ^rev)
      |> Ash.Query.sort(revision: :asc)
      |> Ankole.Ash.read!()

    if length(rows) == rev - base and
         Enum.all?(rows, &(&1.kind == :change and is_list(&1.changes))) do
      case Ankole.Kernel.document_map_range(Enum.map(rows, & &1.changes), from, to) do
        {:ok, {mapped_from, mapped_to}} -> {:ok, {mapped_from, mapped_to}}
        _ -> {:error, {:revision_conflict, rev}}
      end
    else
      {:error, {:revision_conflict, rev}}
    end
  end

  defp resolve_anchor_range(page, _base, _from, _to),
    do: {:error, {:revision_conflict, page.revision}}

  defp has_any_attr?(attrs, keys),
    do: Enum.any?(keys, &(not is_nil(Ankole.Attrs.get(attrs, &1))))

  defp content!(id),
    do:
      PageContent
      |> Ash.Query.filter(page_id == ^id)
      |> Ankole.Ash.read_one!(not_found_error?: true)

  defp fetch_root!(page_id, root_id),
    do:
      PageComment
      |> Ash.Query.filter(page_id == ^page_id and id == ^root_id)
      |> Ankole.Ash.read_one!(not_found_error?: true)

  defp live_replies?(page_id, root_id) do
    PageComment
    |> Ash.Query.filter(page_id == ^page_id and root_id == ^root_id and is_nil(deleted_at))
    |> Ankole.Ash.exists?()
  end
end
