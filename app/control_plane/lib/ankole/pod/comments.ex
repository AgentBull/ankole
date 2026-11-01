defmodule Ankole.Pod.Comments do
  @moduledoc "Owns document and file discussions, multimodal versioned anchors, and @agent wakeups."
  import Bitwise
  require Ash.Query

  alias Ankole.{ActorRef, AuthZ, Conversations, JSON, Principals, Repo, Signals}
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Files.Path, as: FilePath
  alias Ankole.Pod.{Documents, PageComment, PageContent, Pages, Serialization}
  alias Ankole.Pod.Comments.Activity
  alias Ankole.Principals.Principal
  alias Ankole.Sessions.{Key, Queue}

  @wakeup_signal_type "pod.page_comment.addressed"
  @principal_xml_mention_regex ~r/<mention\s+principal="([^"]+)"\s*\/>/
  @principal_md_mention_regex ~r/@\[[^\]]*\]\(principal:([^)\s]+)\)/
  @max_anchor_bytes 1_024
  @max_quote_chars 1_000
  @max_quote_bytes 4_096

  def wakeup_signal_type, do: @wakeup_signal_type

  @doc false
  def rename_markdown_mentions(body, old_uid, new_uid) do
    Regex.replace(@principal_md_mention_regex, body, fn mention, uid ->
      if uid == old_uid,
        do: String.replace_suffix(mention, "(principal:#{old_uid})", "(principal:#{new_uid})"),
        else: mention
    end)
  end

  def list(%AuthZ.Actor{} = actor, id, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(id, :share),
           {:ok, _} <- Access.authorize(actor, page, "node_view"),
           :ok <- commentable(page),
           {:ok, anchor_ids} <- comment_anchor_ids_in_tx(page) do
        query = live_roots(id)
        status = Ankole.Attrs.get(opts, :status, :open)
        query = status_filter(query, status)

        query =
          if status == :unread, do: Activity.unread_query_in_tx(query, actor, id), else: query

        cursor = Ankole.Attrs.get(opts, :cursor)
        limit = min(max(Ankole.Attrs.get(opts, :limit, 25), 1), 100)
        pagination = if cursor, do: [limit: limit, after: cursor], else: [limit: limit]

        query =
          query
          |> Ash.Query.for_read(:list)
          |> Ash.Query.sort(activity_at: :desc, id: :desc)

        with {:ok, result} <- Ankole.Ash.read(query, page: pagination) do
          threads = present_threads(result.results, actor, page, anchor_ids)

          {:ok,
           %{
             threads: threads,
             revision: page.revision,
             next_cursor: if(result.more?, do: List.last(result.results).__metadata__.keyset)
           }}
        end
      end
    end)
  end

  def read(actor, id, comment_id) do
    Repo.transact_top_level(fn ->
      query = live_roots(id) |> Ash.Query.filter(id == ^comment_id)

      with {:ok, page} <- Pages.lock(id, :share),
           {:ok, _} <- Access.authorize(actor, page, "node_view"),
           :ok <- commentable(page),
           {:ok, root} when not is_nil(root) <- Ankole.Ash.read_one(query),
           {:ok, anchor_ids} <- comment_anchor_ids_in_tx(page) do
        {:ok,
         %{
           thread: hd(present_threads([root], actor, page, anchor_ids)),
           revision: page.revision
         }}
      else
        {:ok, nil} -> {:error, :not_found}
        error -> error
      end
    end)
  end

  defp present_threads(roots, actor, page, anchor_ids) do
    ids = Enum.map(roots, & &1.id)

    replies =
      PageComment
      |> Ash.Query.filter(page_id == ^page.id and root_id in ^ids and is_nil(deleted_at))
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read!()

    profiles = Serialization.author_profiles(Enum.map(roots ++ replies, & &1.author))
    replies = Enum.group_by(replies, & &1.root_id)
    caps = capabilities(actor, page)
    read_at = Activity.read_at_in_tx(actor, page.id)

    Enum.map(roots, fn root ->
      root
      |> present(actor, page, caps, anchor_ids, profiles)
      |> Map.put(:unread, Activity.unread?(root, actor, read_at))
      |> Map.put(
        :replies,
        Enum.map(replies[root.id] || [], &present(&1, actor, page, caps, anchor_ids, profiles))
      )
    end)
  end

  def create(%AuthZ.Actor{} = actor, id, attrs) do
    mention_candidates = preflight_mention_candidates(actor, attrs)

    mutate(
      actor,
      id,
      mention_candidates,
      fn page_preview, caps, wakeup_plan ->
        with :ok <- require_capability(caps.comment),
             {:ok, body} <- body(Ankole.Attrs.get(attrs, :body)),
             {:ok, root} <- reply_root(page_preview.id, Ankole.Attrs.get(attrs, :root_id)),
             :ok <- reply_selection(root, attrs),
             now = DateTime.utc_now(:microsecond),
             comment_id = Ankole.Ecto.UUIDv7.autogenerate(),
             {:ok, wake_root} <-
               preview_root_for_wakeup_in_tx(page_preview, comment_id, body, root, attrs),
             {:ok, woken} <-
               maybe_wake_mentioned_agents_in_tx(
                 actor,
                 page_preview,
                 %{id: comment_id, body: body},
                 wake_root,
                 wakeup_plan,
                 [],
                 now
               ) do
          {:ok, %{comment_id: comment_id, body: body, root: root, now: now, woken: woken}}
        end
      end,
      fn page, caps, prepared ->
        with :ok <- require_capability(caps.comment),
             {:ok, body, root, now, comment_id, woken} <-
               resolve_create_state_in_tx(page, attrs, prepared) do
          author = ActorRef.from_actor(actor)

          values = %{
            id: comment_id,
            page_id: id,
            root_id: root && root.id,
            body: body,
            author: author,
            updated_by: author,
            activity_at: now,
            activity_by: author,
            created_at: now,
            updated_at: now
          }

          with {:ok, comment} <- Ankole.Ash.create(PageComment, :create_in_tx, values),
               {:ok, comment, page} <- maybe_anchor(actor, page, comment, attrs),
               :ok <- maybe_record_comment_insight_in_tx(page, now) do
            {:ok, page, comment, woken}
          end
        end
      end
    )
  end

  def update(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mention_candidates = preflight_mention_candidates(actor, attrs)

    mutate(
      actor,
      id,
      mention_candidates,
      fn page_preview, caps, wakeup_plan ->
        with {:ok, comment} <- fetch(id, comment_id),
             :ok <- current(comment, attrs),
             :ok <- require_capability(caps.manage or (caps.comment and own?(actor, comment))),
             :ok <- live(comment),
             {:ok, body} <- body(Ankole.Attrs.get(attrs, :body)),
             {:ok, root_for_wake} <- wakeup_root_in_tx(page_preview.id, comment),
             now = DateTime.utc_now(:microsecond),
             previous_uids = extract_body_agent_uids(comment.body, wakeup_plan.agents),
             {:ok, woken} <-
               maybe_wake_mentioned_agents_in_tx(
                 actor,
                 page_preview,
                 %{comment | body: body},
                 root_for_wake,
                 wakeup_plan,
                 previous_uids,
                 now
               ) do
          {:ok, %{body: body, woken: woken}}
        end
      end,
      fn page, caps, prepared ->
        with {:ok, comment} <- fetch(id, comment_id),
             :ok <- current(comment, attrs),
             :ok <- require_capability(caps.manage or (caps.comment and own?(actor, comment))),
             :ok <- live(comment),
             {:ok, body} <-
               (case prepared do
                  %{body: validated} -> {:ok, validated}
                  nil -> body(Ankole.Attrs.get(attrs, :body))
                end),
             {:ok, updated} <- change(comment, actor, %{body: body}) do
          {:ok, page, updated, if(prepared, do: prepared.woken, else: [])}
        end
      end
    )
  end

  def delete(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mutate(actor, id, [], nil, fn page, caps, _prepared ->
      with {:ok, comment} <- fetch(id, comment_id),
           :ok <- current(comment, attrs),
           :ok <- require_capability(caps.manage or (caps.comment and own?(actor, comment))),
           :ok <- live(comment),
           {:ok, deleted} <-
             change(comment, actor, %{
               body: nil,
               deleted_at: DateTime.utc_now(:microsecond),
               deleted_by: ActorRef.from_actor(actor)
             }),
           {:ok, page} <- remove_empty_anchor(actor, page, deleted) do
        {:ok, page, deleted, []}
      end
    end)
  end

  def resolve(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mutate(actor, id, [], nil, fn page, caps, _prepared ->
      with {:ok, comment} <- fetch(id, comment_id),
           :ok <- current(comment, attrs),
           :ok <- root_comment(comment),
           :ok <- require_capability(caps.edit or (caps.comment and own?(actor, comment))),
           resolved when is_boolean(resolved) <- Ankole.Attrs.get(attrs, :resolved),
           {:ok, updated} <-
             change(comment, actor, %{
               resolved_at: if(resolved, do: DateTime.utc_now(:microsecond)),
               resolved_by: if(resolved, do: ActorRef.from_actor(actor))
             }) do
        {:ok, page, updated, []}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_request}
      end
    end)
  end

  def anchor(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mutate(actor, id, [], nil, fn page, caps, _prepared ->
      with {:ok, comment} <- fetch(id, comment_id),
           :ok <- current(comment, attrs),
           :ok <- root_comment(comment),
           :ok <- require_capability(caps.edit or (caps.comment and own?(actor, comment))),
           {:ok, updated, page} <- put_anchor(actor, page, comment, attrs) do
        {:ok, page, updated, []}
      end
    end)
  end

  @doc "Checks that native marks refer to live root discussions on their owning page."
  def validate_marks_in_tx(_id, []), do: :ok

  def validate_marks_in_tx(id, ids) do
    existing =
      live_roots(id) |> Ash.Query.filter(id in ^ids) |> Ankole.Ash.read!() |> Enum.map(& &1.id)

    if MapSet.new(existing) == MapSet.new(ids), do: :ok, else: {:error, :invalid_comment_anchor}
  end

  defp mutate(actor, id, mention_candidates, prepare_fun, write_fun) do
    commit_node_write = fn prepared ->
      with {:ok, page} <- Pages.lock(id),
           {:ok, caps} <- live_capabilities_in_tx(actor, page),
           :ok <- require_any_mutation_capability(caps),
           :ok <- commentable(page),
           {:ok, updated_page, comment, woken} <- write_fun.(page, caps, prepared),
           {:ok, touched_root} <- Activity.touch_in_tx(actor, id, comment),
           comment =
             if(is_nil(comment.root_id),
               do: %{
                 comment
                 | activity_at: touched_root.activity_at,
                   activity_by: touched_root.activity_by
               },
               else: comment
             ),
           {:ok, presented} <- result(actor, updated_page, comment, caps),
           do: {:ok, Map.merge(presented, %{page_id: id, woken: woken})}
    end

    after_commit = fn %{page_id: id, woken: woken} ->
      Pages.broadcast(id)
      Pages.broadcast_comments(id)
      publish_woken_agents(woken)
    end

    result =
      if actor.turn_authority == nil and mention_candidates != [] and is_function(prepare_fun, 3) do
        Access.write_tree(
          nil,
          fn ->
            # Enforce strict outermost lock order:
            # 2 (drive-tree) -> 2.5 (drive-root) -> 3 (principals) -> 9/10 (sessions)
            # -> [conversations] -> 11 (signals) -> 12 (drive_nodes / pages).
            with {:ok, page_preview} <- Pages.fetch(id),
                 {:ok, preview_caps} <- live_capabilities_in_tx(actor, page_preview),
                 :ok <- require_any_mutation_capability(preview_caps),
                 :ok <- commentable(page_preview),
                 wakeup_plan = prepare_wakeup_locks_in_tx(actor, id, mention_candidates),
                 {:ok, prepared} <- prepare_fun.(page_preview, preview_caps, wakeup_plan) do
              commit_node_write.(prepared)
            end
          end,
          root_ids: fn -> Nodes.root_ids([id]) end,
          after_commit: after_commit
        )
      else
        Access.write(
          actor.turn_authority,
          fn -> commit_node_write.(nil) end,
          after_commit: after_commit
        )
      end

    case result do
      {:ok, result} -> {:ok, Map.drop(result, [:page_id, :woken])}
      error -> error
    end
  end

  defp resolve_create_state_in_tx(_page, _attrs, %{
         comment_id: comment_id,
         body: body,
         root: root,
         now: now,
         woken: woken
       }) do
    {:ok, body, root, now, comment_id, woken}
  end

  defp resolve_create_state_in_tx(page, attrs, nil) do
    with {:ok, body} <- body(Ankole.Attrs.get(attrs, :body)),
         {:ok, root} <- reply_root(page.id, Ankole.Attrs.get(attrs, :root_id)),
         :ok <- reply_selection(root, attrs) do
      {:ok, body, root, DateTime.utc_now(:microsecond), Ankole.Ecto.UUIDv7.autogenerate(), []}
    end
  end

  defp preview_root_for_wakeup_in_tx(_page, _comment_id, _body, root, _attrs)
       when not is_nil(root),
       do: {:ok, root}

  defp preview_root_for_wakeup_in_tx(%{type: :doc} = page, comment_id, body, nil, attrs) do
    cond do
      not is_nil(Ankole.Attrs.get(attrs, :anchor)) ->
        {:error, :invalid_comment_anchor}

      Enum.any?([:base_revision, :from, :to], &(not is_nil(Ankole.Attrs.get(attrs, &1)))) ->
        base = Ankole.Attrs.get(attrs, :base_revision)
        from = Ankole.Attrs.get(attrs, :from)
        to = Ankole.Attrs.get(attrs, :to)

        with true <-
               is_integer(base) and is_integer(from) and is_integer(to) and from >= 0 and
                 to > from,
             :ok <- revision(page, base),
             content = content!(page.id),
             {:ok, parsed} <-
               Ankole.Kernel.page_comment_annotate(content.content, comment_id, from, to) do
          {:ok, %{id: comment_id, body: body, quote: parsed.quote, anchor: nil}}
        else
          false -> {:error, :invalid_request}
          error -> error
        end

      not is_nil(Ankole.Attrs.get(attrs, :quote)) ->
        {:error, :invalid_comment_anchor}

      true ->
        {:ok, %{id: comment_id, body: body, quote: nil, anchor: nil}}
    end
  end

  defp preview_root_for_wakeup_in_tx(%{type: :file} = page, comment_id, body, nil, attrs) do
    cond do
      Enum.any?([:base_revision, :from, :to], &(not is_nil(Ankole.Attrs.get(attrs, &1)))) ->
        {:error, :invalid_comment_anchor}

      not is_nil(Ankole.Attrs.get(attrs, :anchor)) ->
        with {:ok, normalized_anchor} <-
               normalize_file_anchor(Ankole.Attrs.get(attrs, :anchor), page.object_id),
             {:ok, normalized_quote} <- normalize_file_quote(Ankole.Attrs.get(attrs, :quote)) do
          {:ok, %{id: comment_id, body: body, quote: normalized_quote, anchor: normalized_anchor}}
        end

      not is_nil(Ankole.Attrs.get(attrs, :quote)) ->
        {:error, :invalid_comment_anchor}

      true ->
        {:ok, %{id: comment_id, body: body, quote: nil, anchor: nil}}
    end
  end

  defp maybe_record_comment_insight_in_tx(%{type: :doc, id: id}, now),
    do: Documents.Insights.record_in_tx(id, :comments, now)

  defp maybe_record_comment_insight_in_tx(_page, _now), do: :ok

  defp maybe_anchor(actor, %{type: :doc} = page, comment, attrs) do
    cond do
      not is_nil(Ankole.Attrs.get(attrs, :anchor)) ->
        {:error, :invalid_comment_anchor}

      Enum.any?([:base_revision, :from, :to], &(not is_nil(Ankole.Attrs.get(attrs, &1)))) ->
        put_anchor(actor, page, comment, attrs)

      not is_nil(Ankole.Attrs.get(attrs, :quote)) ->
        {:error, :invalid_comment_anchor}

      true ->
        {:ok, comment, page}
    end
  end

  defp maybe_anchor(actor, %{type: :file} = page, comment, attrs) do
    cond do
      Enum.any?([:base_revision, :from, :to], &(not is_nil(Ankole.Attrs.get(attrs, &1)))) ->
        {:error, :invalid_comment_anchor}

      not is_nil(Ankole.Attrs.get(attrs, :anchor)) ->
        put_anchor(actor, page, comment, attrs)

      not is_nil(Ankole.Attrs.get(attrs, :quote)) ->
        {:error, :invalid_comment_anchor}

      true ->
        {:ok, comment, page}
    end
  end

  defp put_anchor(actor, %{type: :doc} = page, comment, attrs) do
    base = Ankole.Attrs.get(attrs, :base_revision)
    from = Ankole.Attrs.get(attrs, :from)
    to = Ankole.Attrs.get(attrs, :to)

    with true <-
           is_nil(Ankole.Attrs.get(attrs, :anchor)) and
             is_integer(base) and is_integer(from) and is_integer(to) and from >= 0 and to > from,
         :ok <- revision(page, base),
         content = content!(page.id),
         {:ok, parsed} <-
           Ankole.Kernel.page_comment_annotate(content.content, comment.id, from, to),
         {:ok, %{page: updated_page}} <-
           Documents.commit_parsed_in_tx(page, content, actor, parsed, attribution: false),
         {:ok, updated} <-
           change(comment, actor, %{
             quote: comment.quote || parsed.quote,
             anchor_revision: comment.anchor_revision || updated_page.revision
           }) do
      {:ok, updated, updated_page}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp put_anchor(actor, %{type: :file} = page, comment, attrs) do
    raw_anchor = Ankole.Attrs.get(attrs, :anchor)
    raw_quote = Ankole.Attrs.get(attrs, :quote, comment.quote)

    with true <-
           Enum.all?([:base_revision, :from, :to], &is_nil(Ankole.Attrs.get(attrs, &1))),
         {:ok, normalized_anchor} <- normalize_file_anchor(raw_anchor, page.object_id),
         {:ok, normalized_quote} <- normalize_file_quote(raw_quote),
         {:ok, updated} <-
           change(comment, actor, %{
             anchor: normalized_anchor,
             quote: normalized_quote
           }) do
      {:ok, updated, page}
    else
      false -> {:error, :invalid_comment_anchor}
      error -> error
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

  defp remove_empty_anchor(actor, %{type: :doc} = page, comment) do
    root_id = comment.root_id || comment.id
    {:ok, root} = fetch(page.id, root_id)

    replies =
      PageComment
      |> Ash.Query.filter(page_id == ^page.id and root_id == ^root_id and is_nil(deleted_at))
      |> Ankole.Ash.exists?()

    if root.deleted_at && !replies do
      content = content!(page.id)

      with {:ok, parsed} <- Ankole.Kernel.page_comment_remove(content.content, root.id),
           {:ok, %{page: updated}} <-
             Documents.commit_parsed_in_tx(page, content, actor, parsed, attribution: false),
           do: {:ok, updated}
    else
      {:ok, page}
    end
  end

  defp remove_empty_anchor(actor, %{type: :file} = page, comment) do
    root_id = comment.root_id || comment.id
    {:ok, root} = fetch(page.id, root_id)

    replies =
      PageComment
      |> Ash.Query.filter(page_id == ^page.id and root_id == ^root_id and is_nil(deleted_at))
      |> Ankole.Ash.exists?()

    if root.deleted_at && !replies && (not is_nil(root.anchor) || not is_nil(root.quote)) do
      with {:ok, _} <- change(root, actor, %{anchor: nil, quote: nil}), do: {:ok, page}
    else
      {:ok, page}
    end
  end

  defp result(actor, page, comment, caps) do
    with {:ok, anchor_ids} <- comment_anchor_ids_in_tx(page),
         do:
           {:ok,
            %{
              comment:
                present(
                  comment,
                  actor,
                  page,
                  caps,
                  anchor_ids,
                  Serialization.author_profiles([comment.author])
                ),
              revision: page.revision
            }}
  end

  defp comment_anchor_ids_in_tx(%{type: :doc, id: id}) do
    with {:ok, info} <- Ankole.Kernel.page_comment_info(content!(id).content),
         do: {:ok, info.ids}
  end

  defp comment_anchor_ids_in_tx(%{type: :file}), do: {:ok, []}

  defp present(comment, actor, page, caps, ids, profiles) do
    own = own?(actor, comment)
    root = is_nil(comment.root_id)

    profile = Serialization.author_json(comment.author, profiles)

    {anchor_value, anchor_present, anchor_outdated} =
      case page.type do
        :doc ->
          {nil, comment.id in ids, false}

        :file ->
          outdated =
            root and is_map(comment.anchor) and comment.anchor["object_id"] != page.object_id

          present? = root and is_map(comment.anchor) and not outdated
          {comment.anchor, present?, outdated}
      end

    comment
    |> Map.take([
      :id,
      :root_id,
      :body,
      :version,
      :created_at,
      :updated_at,
      :activity_at,
      :deleted_at,
      :resolved_at,
      :resolved_by,
      :quote,
      :anchor_revision
    ])
    |> Map.merge(%{
      anchor: anchor_value,
      anchor_present: anchor_present,
      anchor_outdated: anchor_outdated,
      author: profile,
      can_edit: is_nil(comment.deleted_at) && (caps.manage || (caps.comment && own)),
      can_delete: is_nil(comment.deleted_at) && (caps.manage || (caps.comment && own)),
      can_resolve: root && (caps.edit || (caps.comment && own)),
      can_reanchor: root && (caps.edit || (caps.comment && own))
    })
  end

  # --- @agent Mention Detection, Lock Ordering & Triple AuthZ Gate ---

  defp preflight_mention_candidates(
         %AuthZ.Actor{turn_authority: nil, principal: %{type: :human, uid: author_uid}},
         attrs
       ) do
    body_text = Ankole.Attrs.get(attrs, :body) || ""
    explicit_uids = Ankole.Attrs.get(attrs, :mentioned_agent_uids) || []

    if not is_binary(body_text) or
         (explicit_uids == [] and not String.contains?(body_text, "@") and
            not String.contains?(body_text, "<mention")) do
      []
    else
      active_agents =
        Principals.list_principals!(
          query: [filter: [type: :agent, status: :active], load: [:agent]]
        )

      explicit =
        explicit_uids
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      in_body = MapSet.new(extract_body_agent_uids(body_text, active_agents, author_uid))
      wanted = MapSet.union(explicit, in_body)

      Enum.filter(active_agents, &MapSet.member?(wanted, &1.uid))
    end
  end

  defp preflight_mention_candidates(_actor, _attrs), do: []

  defp extract_body_agent_uids(body, agents, author_uid \\ nil)
  defp extract_body_agent_uids(nil, _agents, _author_uid), do: []

  defp extract_body_agent_uids(body_text, agents, author_uid)
       when is_binary(body_text) and is_list(agents) do
    xml_uids =
      @principal_xml_mention_regex
      |> Regex.scan(body_text, capture: :all_but_first)
      |> List.flatten()

    md_uids =
      @principal_md_mention_regex
      |> Regex.scan(body_text, capture: :all_but_first)
      |> List.flatten()

    direct_matches =
      Enum.flat_map(agents, fn agent ->
        uid_mentioned? = token_mentioned?(body_text, agent.uid)

        personal_name? =
          case agent.agent do
            %Ankole.Principals.Agent{type: :personal_assistant, owner_principal_uid: owner_uid} ->
              is_nil(author_uid) or owner_uid == author_uid

            _ ->
              true
          end

        name_mentioned? =
          personal_name? and is_binary(agent.display_name) and
            String.trim(agent.display_name) != "" and
            token_mentioned?(body_text, String.trim(agent.display_name))

        if uid_mentioned? or name_mentioned?, do: [agent.uid], else: []
      end)

    Enum.uniq(xml_uids ++ md_uids ++ direct_matches)
  end

  defp token_mentioned?(body_text, token) do
    escaped = Regex.escape(token)

    case Regex.compile("(?<![\\p{L}\\p{N}_-])@" <> escaped <> "(?![\\p{L}\\p{N}_-])", "iu") do
      {:ok, regex} -> Regex.match?(regex, body_text)
      _ -> false
    end
  end

  defp prepare_wakeup_locks_in_tx(actor, page_id, candidate_agents) do
    human_uid = AuthZ.Actor.uid(actor)
    agent_uids = Enum.map(candidate_agents, & &1.uid)

    targets =
      Enum.map(candidate_agents, fn agent ->
        conv_id =
          Conversations.find_anchor_page_conversation_id(page_id, agent.uid) ||
            Ankole.Ecto.UUIDv7.autogenerate()

        %{agent: agent, agent_uid: agent.uid, conversation_id: conv_id}
      end)

    {:ok, locked_principals} =
      Principals.lock_principals_in_tx(Enum.sort(Enum.uniq([human_uid | agent_uids])))

    principal_by_uid = Map.new(locked_principals, &{&1.uid, &1})

    :ok =
      Queue.lock_sessions_in_tx(
        Enum.map(targets, &{&1.agent_uid, Key.conversation(&1.conversation_id)})
      )

    refreshed_targets =
      Enum.flat_map(targets, fn target ->
        case Map.get(principal_by_uid, target.agent_uid) do
          %Principal{type: :agent, status: :active} = locked_agent ->
            [%{target | agent: locked_agent}]

          _ ->
            []
        end
      end)

    %{
      targets: refreshed_targets,
      agents: Enum.map(refreshed_targets, & &1.agent)
    }
  end

  defp wakeup_root_in_tx(_page_id, %{root_id: nil} = root), do: {:ok, root}
  defp wakeup_root_in_tx(page_id, %{root_id: root_id}), do: fetch(page_id, root_id)

  defp maybe_wake_mentioned_agents_in_tx(
         _actor,
         _page,
         _comment,
         _root,
         %{targets: []},
         _previous_uids,
         _now
       ),
       do: {:ok, []}

  defp maybe_wake_mentioned_agents_in_tx(
         actor,
         page,
         comment,
         root,
         %{targets: targets},
         previous_uids,
         now
       ) do
    previous_set = MapSet.new(previous_uids)
    effective_root = root || comment

    targets
    |> Enum.reject(&MapSet.member?(previous_set, &1.agent_uid))
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      if authorized_comment_wakeup?(actor, target.agent, page) do
        with {:ok, conversation, created?} <-
               ensure_anchor_conversation_in_tx(
                 actor,
                 target.agent,
                 target.conversation_id,
                 page,
                 now
               ),
             {:ok, signal} <-
               accept_comment_wakeup_signal_in_tx(
                 actor,
                 target.agent,
                 conversation,
                 page,
                 comment,
                 effective_root,
                 now
               ) do
          next_acc =
            if DateTime.compare(signal.occurred_at, now) == :eq do
              [
                %{
                  signal: signal,
                  conversation_id: conversation.id,
                  created_conversation?: created?,
                  agent_uid: target.agent.uid,
                  session_id: signal.session_id
                }
                | acc
              ]
            else
              acc
            end

          {:cont, {:ok, next_acc}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, woken} -> {:ok, Enum.reverse(woken)}
      error -> error
    end
  end

  defp authorized_comment_wakeup?(actor, %Principal{uid: agent_uid} = agent_principal, page) do
    human_can_chat? =
      AuthZ.authorize(actor, "agent:#{agent_uid}", "chat", AuthZ.Actor.request_context(actor)) ==
        :ok

    primary_ready? =
      match?(
        {:ok, %{"provider_id" => provider_id, "model" => model}}
        when is_binary(provider_id) and is_binary(model),
        ModelProfiles.get_model_profile(agent_uid, "primary")
      )

    agent_can_view_node? =
      match?({:ok, _}, Access.authorize(AuthZ.Actor.new(agent_principal), page, "node_view"))

    human_can_chat? and primary_ready? and agent_can_view_node?
  end

  defp ensure_anchor_conversation_in_tx(actor, agent, conv_id, page, now) do
    Conversations.ensure_anchor_page_conversation_in_tx(
      actor,
      agent,
      conv_id,
      page.id,
      page.title || page.name || "",
      now
    )
  end

  defp accept_comment_wakeup_signal_in_tx(actor, agent, conversation, page, comment, root, now) do
    human_uid = AuthZ.Actor.uid(actor)
    root_id = root.id

    Signals.accept_in_tx(%{
      producer: :kernel,
      source: "control-plane://pod-comments",
      id: "pod-comment:#{comment.id}:#{agent.uid}",
      type: @wakeup_signal_type,
      subject: page.id,
      target: %{agent_uid: agent.uid, conversation_id: conversation.id},
      sender: human_uid,
      time: now,
      data: %{
        "conversation_id" => conversation.id,
        "node_id" => page.id,
        "page_id" => page.id,
        "node_type" => to_string(page.type),
        "node_title" => page.title || page.name || "",
        "comment_id" => comment.id,
        "root_id" => root_id,
        "author_uid" => human_uid,
        "author_name" => principal_display_name(actor.principal),
        "quote" => root.quote,
        "anchor" => root.anchor,
        "body_markdown" => comment.body
      }
    })
  end

  defp principal_display_name(principal) do
    name = principal.display_name
    if is_binary(name) and String.trim(name) != "", do: name, else: principal.uid
  end

  defp publish_woken_agents([]), do: :ok

  defp publish_woken_agents(woken) when is_list(woken) do
    Signals.publish_committed(Enum.map(woken, & &1.signal))

    Enum.each(woken, fn item ->
      if item.created_conversation? do
        Ankole.Conversations.Events.publish_committed([{item.conversation_id, :message}])
      end

      Ankole.Sessions.Events.publish_status(item.agent_uid, item.session_id)
    end)
  end

  # --- Capabilities & Validation Helpers ---

  defp capabilities(actor, page) do
    case live_capabilities_in_tx(actor, page) do
      {:ok, caps} -> caps
      _ -> capabilities_from_bits(0)
    end
  end

  defp live_capabilities_in_tx(actor, page) do
    with {:ok, path} <- Access.path(page),
         false <- Enum.any?(path, & &1.deleted_at),
         {:ok, reachable} <- Access.reachable_anchors(actor, target_ids: [page.acl_anchor_id]) do
      {:ok, capabilities_from_bits(Access.page_bits(page, reachable))}
    else
      true -> {:error, :not_found}
      error -> error
    end
  end

  defp capabilities_from_bits(bits) do
    %{
      view: band(bits, Access.action_bit("node_view")) != 0,
      comment: band(bits, Access.action_bit("node_comment")) != 0,
      edit: band(bits, Access.action_bit("node_edit")) != 0,
      manage: band(bits, Access.action_bit("node_manage")) != 0
    }
  end

  defp own?(actor, comment), do: comment.author.uid == AuthZ.Actor.uid(actor)

  defp require_any_mutation_capability(caps) do
    if caps.comment or caps.edit or caps.manage, do: :ok, else: {:error, :forbidden}
  end

  defp require_capability(true), do: :ok
  defp require_capability(false), do: {:error, :forbidden}

  defp change(comment, actor, attrs),
    do:
      Ankole.Ash.update(
        comment,
        :change_in_tx,
        Map.merge(attrs, %{
          updated_at: DateTime.utc_now(:microsecond),
          updated_by: ActorRef.from_actor(actor)
        })
      )

  defp current(comment, attrs),
    do:
      if(comment.version == Ankole.Attrs.get(attrs, :version),
        do: :ok,
        else: {:error, :comment_conflict}
      )

  defp live(%{deleted_at: nil}), do: :ok
  defp live(_), do: {:error, :not_found}
  defp root_comment(%{root_id: nil}), do: :ok
  defp root_comment(_), do: {:error, :invalid_comment_reply}
  defp revision(%{revision: value}, value), do: :ok
  defp revision(page, _), do: {:error, {:revision_conflict, page.revision}}
  defp commentable(%{type: type}) when type in [:doc, :file], do: :ok
  defp commentable(_), do: {:error, :invalid_page_type}

  defp body(value) when is_binary(value),
    do:
      if(String.trim(value) != "" and String.length(value) <= 20_000,
        do: {:ok, value},
        else: {:error, :invalid_comment_body}
      )

  defp body(_), do: {:error, :invalid_comment_body}

  defp content!(id),
    do:
      PageContent
      |> Ash.Query.filter(page_id == ^id)
      |> Ankole.Ash.read_one!(not_found_error?: true)

  defp live_roots(id), do: Activity.roots_in_tx(id)

  defp status_filter(query, :open), do: Ash.Query.filter(query, is_nil(resolved_at))
  defp status_filter(query, :resolved), do: Ash.Query.filter(query, not is_nil(resolved_at))
  defp status_filter(query, _), do: query

  defp fetch(id, comment_id) do
    case PageComment
         |> Ash.Query.filter(page_id == ^id and id == ^comment_id)
         |> Ankole.Ash.read_one() do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp reply_root(_id, nil), do: {:ok, nil}

  defp reply_root(id, root_id) do
    case live_roots(id) |> Ash.Query.filter(id == ^root_id) |> Ankole.Ash.read_one() do
      {:ok, nil} -> {:error, :invalid_comment_reply}
      result -> result
    end
  end

  defp reply_selection(nil, _attrs), do: :ok

  defp reply_selection(_root, attrs),
    do:
      if(
        Enum.any?(
          [:base_revision, :from, :to, :anchor, :quote],
          &(not is_nil(Ankole.Attrs.get(attrs, &1)))
        ),
        do: {:error, :invalid_comment_reply},
        else: :ok
      )
end
