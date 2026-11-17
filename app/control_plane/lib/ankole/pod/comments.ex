defmodule Ankole.Pod.Comments do
  @moduledoc "Owns document and file discussions, multimodal versioned anchors, and @agent wakeups."
  import Bitwise
  require Ash.Query

  alias Ankole.{ActorRef, AuthZ, Principals, Repo}
  alias Ankole.Pod.Access
  alias Ankole.Pod.Comments.{Activity, Anchors, Wakeups}
  alias Ankole.Pod.{Documents, OfficeFiles, PageComment, Pages, Serialization}
  alias Ankole.Pod.Pages.Tree, as: Nodes

  @principal_md_mention_regex ~r/@\[[^\]]*\]\(principal:([^)\s]+)\)/

  defdelegate wakeup_signal_type(), to: Wakeups

  @doc "Unread and open counts, latest activity, and resolved anchored threads for one Page."
  defdelegate summary(actor, id), to: Activity

  @doc "Whether a Page type supports discussions and read acknowledgments."
  def commentable_type?(type), do: type in [:doc, :knowledge, :file, :applet, :base]

  @doc "Checks that native marks refer to live root discussions on their owning page."
  defdelegate validate_marks_in_tx(id, ids), to: Anchors

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
           {:ok, anchor_ids} <- Anchors.anchor_ids_in_tx(page) do
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
           {:ok, anchor_ids} <- Anchors.anchor_ids_in_tx(page) do
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
    own_uids = own_uids(actor)

    Enum.map(roots, fn root ->
      root
      |> present(own_uids, page, caps, anchor_ids, profiles)
      |> Map.put(:unread, Activity.unread?(root, actor, read_at))
      |> Map.put(
        :replies,
        Enum.map(replies[root.id] || [], &present(&1, own_uids, page, caps, anchor_ids, profiles))
      )
    end)
  end

  def create(%AuthZ.Actor{} = actor, id, attrs) do
    mention_candidates = Wakeups.preflight_candidates(actor, attrs)

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
               Anchors.preview_for_wakeup_in_tx(page_preview, comment_id, body, root, attrs),
             {:ok, woken} <-
               Wakeups.maybe_wake_in_tx(
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
               {:ok, comment, page} <-
                 Anchors.maybe_apply_in_tx(actor, page, comment, attrs, &change/3),
               :ok <- maybe_record_comment_insight_in_tx(page, now) do
            {:ok, page, comment, woken}
          end
        end
      end
    )
  end

  def update(%AuthZ.Actor{} = actor, id, comment_id, attrs) do
    mention_candidates = Wakeups.preflight_candidates(actor, attrs)

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
             previous_uids = Wakeups.extract_body_agent_uids(comment.body, wakeup_plan.agents),
             {:ok, woken} <-
               Wakeups.maybe_wake_in_tx(
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
           {:ok, page} <- Anchors.remove_if_empty_in_tx(actor, page, deleted, &change/3) do
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
           {:ok, updated, page} <- Anchors.put_in_tx(actor, page, comment, attrs, &change/3) do
        {:ok, page, updated, []}
      end
    end)
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
      Wakeups.publish_committed(woken)
    end

    result =
      if actor.turn_authority == nil and mention_candidates != [] and is_function(prepare_fun, 3) do
        Access.write_tree(
          nil,
          fn ->
            # Enforce strict outermost lock order:
            # 2 (page-tree) -> 2.5 (page-root) -> 3 (principals) -> 9/10 (sessions)
            # -> [conversations] -> 11 (signals) -> 12 (pages).
            with {:ok, page_preview} <- Pages.fetch(id),
                 {:ok, preview_caps} <- live_capabilities_in_tx(actor, page_preview),
                 :ok <- require_any_mutation_capability(preview_caps),
                 :ok <- commentable(page_preview),
                 wakeup_plan = Wakeups.prepare_locks_in_tx(actor, id, mention_candidates),
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

  defp wakeup_root_in_tx(_page_id, %{root_id: nil} = root), do: {:ok, root}
  defp wakeup_root_in_tx(page_id, %{root_id: root_id}), do: fetch(page_id, root_id)

  defp maybe_record_comment_insight_in_tx(%{type: :doc, id: id}, now),
    do: Documents.Insights.record_in_tx(id, :comments, now)

  defp maybe_record_comment_insight_in_tx(_page, _now), do: :ok

  defp result(actor, page, comment, caps) do
    with {:ok, anchor_ids} <- Anchors.anchor_ids_in_tx(page),
         do:
           {:ok,
            %{
              comment:
                present(
                  comment,
                  own_uids(actor),
                  page,
                  caps,
                  anchor_ids,
                  Serialization.author_profiles([comment.author])
                ),
              revision: page.revision
            }}
  end

  defp present(comment, own_uids, page, caps, ids, profiles) do
    own = own?(own_uids, comment)
    root = is_nil(comment.root_id)
    can_edit = is_nil(comment.deleted_at) && (caps.manage || (caps.comment && own))
    can_resolve = root && (caps.edit || (caps.comment && own))

    profile = Serialization.author_json(comment.author, profiles)
    office_file? = OfficeFiles.office_file?(page)

    {anchor_value, anchor_present, anchor_outdated} =
      Anchors.present(comment, page, ids, office_file?)

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
      can_edit: can_edit,
      can_delete: can_edit,
      can_resolve: can_resolve,
      can_reanchor: page.type not in [:knowledge, :base] && not office_file? && can_resolve
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
      view: band(bits, Access.action_bit("node_view")) != 0,
      comment: band(bits, Access.action_bit("node_comment")) != 0,
      edit: band(bits, Access.action_bit("node_edit")) != 0,
      manage: band(bits, Access.action_bit("node_manage")) != 0
    }
  end

  # A Human and their personal assistant own each other's comments.
  defp own_uids(actor), do: Principals.equivalent_uids(AuthZ.Actor.uid(actor))

  defp own?(%AuthZ.Actor{} = actor, comment), do: own?(own_uids(actor), comment)
  defp own?(own_uids, comment), do: MapSet.member?(own_uids, comment.author.uid)

  defp require_any_mutation_capability(caps) do
    if caps.comment or caps.edit or caps.manage, do: :ok, else: {:error, :forbidden}
  end

  defp require_capability(true), do: :ok
  defp require_capability(false), do: {:error, :forbidden}

  defp change(comment, actor, attrs) do
    Ankole.Ash.update(
      comment,
      :change_in_tx,
      Map.merge(attrs, %{
        updated_at: DateTime.utc_now(:microsecond),
        updated_by: ActorRef.from_actor(actor)
      })
    )
  end

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

  defp commentable(%{type: type}),
    do: if(commentable_type?(type), do: :ok, else: {:error, :invalid_page_type})

  defp body(value) when is_binary(value),
    do:
      if(String.trim(value) != "" and String.length(value) <= 20_000,
        do: {:ok, value},
        else: {:error, :invalid_comment_body}
      )

  defp body(_), do: {:error, :invalid_comment_body}

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
