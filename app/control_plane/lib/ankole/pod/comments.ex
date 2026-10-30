defmodule Ankole.Pod.Comments do
  @moduledoc "Owns document discussions and their atomic native text anchors."
  import Bitwise
  require Ash.Query
  alias Ankole.{ActorRef, AuthZ, Repo}
  alias Ankole.Pod.{Access, Documents, PageComment, PageContent, Pages, Serialization}
  alias Ankole.Pod.Comments.Activity

  def list(%AuthZ.Actor{} = actor, id, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      with {:ok, page} <- Pages.lock(id, :share),
           {:ok, _} <- Access.authorize(actor, page, "page_view"),
           :ok <- document(page),
           {:ok, info} <- Ankole.Kernel.page_comment_info(content!(id).content) do
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
          threads = present_threads(result.results, actor, page, info.ids)

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
           {:ok, _} <- Access.authorize(actor, page, "page_view"),
           :ok <- document(page),
           {:ok, root} when not is_nil(root) <- Ankole.Ash.read_one(query),
           {:ok, info} <- Ankole.Kernel.page_comment_info(content!(id).content) do
        {:ok,
         %{thread: hd(present_threads([root], actor, page, info.ids)), revision: page.revision}}
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

    profiles = Serialization.author_profiles(Enum.map(roots ++ replies, & &1.author.uid))
    replies = Enum.group_by(replies, & &1.root_id)
    caps = capabilities(actor, page)
    read_at = Activity.read_at_in_tx(actor, page.id)

    Enum.map(roots, fn root ->
      root
      |> present(actor, caps, anchor_ids, profiles)
      |> Map.put(:unread, Activity.unread?(root, actor, read_at))
      |> Map.put(
        :replies,
        Enum.map(replies[root.id] || [], &present(&1, actor, caps, anchor_ids, profiles))
      )
    end)
  end

  def create(%AuthZ.Actor{} = actor, id, attrs) do
    mutate(actor, id, fn page, caps ->
      with :ok <- require_capability(caps.comment),
           {:ok, body} <- body(Ankole.Attrs.get(attrs, :body)),
           {:ok, root} <- reply_root(page.id, Ankole.Attrs.get(attrs, :root_id)),
           :ok <- reply_selection(root, attrs) do
        now = DateTime.utc_now(:microsecond)
        author = ActorRef.from_actor(actor)

        values = %{
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
             :ok <- Ankole.Pod.Documents.Insights.record_in_tx(page.id, :comments, now) do
          {:ok, page, comment}
        end
      end
    end)
  end

  def update(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mutate(actor, id, fn page, caps ->
      with {:ok, comment} <- fetch(id, comment_id),
           :ok <- current(comment, attrs),
           :ok <- require_capability(caps.manage or (caps.comment and own?(actor, comment))),
           :ok <- live(comment),
           {:ok, body} <- body(Ankole.Attrs.get(attrs, :body)),
           {:ok, updated} <- change(comment, actor, %{body: body}) do
        {:ok, page, updated}
      end
    end)
  end

  def delete(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mutate(actor, id, fn page, caps ->
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
        {:ok, page, deleted}
      end
    end)
  end

  def resolve(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mutate(actor, id, fn page, caps ->
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
        {:ok, page, updated}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_request}
      end
    end)
  end

  def anchor(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mutate(actor, id, fn page, caps ->
      with {:ok, comment} <- fetch(id, comment_id),
           :ok <- current(comment, attrs),
           :ok <- root_comment(comment),
           :ok <- require_capability(caps.edit or (caps.comment and own?(actor, comment))),
           {:ok, updated, page} <- put_anchor(actor, page, comment, attrs) do
        {:ok, page, updated}
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

  defp mutate(actor, id, fun) do
    result =
      Access.write(
        actor.turn_authority,
        fn ->
          with {:ok, page} <- Pages.lock(id),
               {:ok, caps} <- live_capabilities_in_tx(actor, page),
               :ok <- require_any_mutation_capability(caps),
               :ok <- document(page),
               {:ok, updated_page, comment} <- fun.(page, caps),
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
               do: {:ok, Map.put(presented, :page_id, id)}
        end,
        after_commit: fn %{page_id: id} ->
          Pages.broadcast(id)
          Pages.broadcast_comments(id)
        end
      )

    case result do
      {:ok, result} -> {:ok, Map.delete(result, :page_id)}
      error -> error
    end
  end

  defp maybe_anchor(actor, page, comment, attrs) do
    if Enum.any?([:base_revision, :from, :to], &(not is_nil(Ankole.Attrs.get(attrs, &1)))),
      do: put_anchor(actor, page, comment, attrs),
      else: {:ok, comment, page}
  end

  defp put_anchor(actor, page, comment, attrs) do
    base = Ankole.Attrs.get(attrs, :base_revision)
    from = Ankole.Attrs.get(attrs, :from)
    to = Ankole.Attrs.get(attrs, :to)

    with true <-
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

  defp remove_empty_anchor(actor, page, comment) do
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

  defp result(actor, page, comment, caps) do
    with {:ok, info} <- Ankole.Kernel.page_comment_info(content!(page.id).content),
         do:
           {:ok,
            %{
              comment:
                present(
                  comment,
                  actor,
                  caps,
                  info.ids,
                  Serialization.author_profiles([comment.author.uid])
                ),
              revision: page.revision
            }}
  end

  defp present(comment, actor, caps, ids, profiles) do
    own = own?(actor, comment)
    root = is_nil(comment.root_id)

    profile = Serialization.author_json(comment.author, profiles)

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
      author: profile,
      anchor_present: comment.id in ids,
      can_edit: is_nil(comment.deleted_at) && (caps.manage || (caps.comment && own)),
      can_delete: is_nil(comment.deleted_at) && (caps.manage || (caps.comment && own)),
      can_resolve: root && (caps.edit || (caps.comment && own)),
      can_reanchor: root && (caps.edit || (caps.comment && own))
    })
  end

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
      view: band(bits, Access.action_bit("page_view")) != 0,
      comment: band(bits, Access.action_bit("page_comment")) != 0,
      edit: band(bits, Access.action_bit("page_edit")) != 0,
      manage: band(bits, Access.action_bit("page_manage")) != 0
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
  defp document(%{type: :doc}), do: :ok
  defp document(_), do: {:error, :invalid_page_type}

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
      if(Enum.any?([:base_revision, :from, :to], &(not is_nil(Ankole.Attrs.get(attrs, &1)))),
        do: {:error, :invalid_comment_reply},
        else: :ok
      )
end
