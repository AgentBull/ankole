defmodule Ankole.Conversations.NativeRoom do
  @moduledoc false
  require Ash.Query
  require Ash.Expr
  alias Ankole.{AIGateway, Conversations, Repo}

  alias Ankole.Conversations.{
    Conversation,
    Message,
    ModelPreferences,
    Native,
    Participant,
    Queries
  }

  def list(actor, opts) do
    if Native.active_human?(actor) do
      {:ok, rows} = Repo.transact_top_level(fn -> {:ok, list_in_tx(actor, opts)} end)
      rows
    else
      []
    end
  end

  defp list_in_tx(actor, opts) do
    uid = Ankole.AuthZ.Actor.uid(actor)
    {:ok, reachable} = Ankole.Files.Access.reachable_anchors(actor)
    pages = Ankole.Files.visible_node_ids(reachable)
    pattern = if opts[:query], do: "%" <> Repo.escape_like(opts[:query]) <> "%"
    order = Keyword.get(opts, :order, :pinned)

    query =
      Conversation
      |> Ash.Query.filter(
        kind == :native and
          ((native_access_scope == :participants and
              exists(
                Participant,
                conversation_id == parent(id) and principal_uid == ^uid and role != :observer
              )) or
             (native_access_scope == :anchor_page and
                page_id in ^pages))
      )
      |> order_rooms(order, uid)

    query =
      if opts[:page_id] do
        Ash.Query.filter(query, page_id == ^opts[:page_id])
      else
        Ash.Query.filter(
          query,
          exists(Participant, conversation_id == parent(id) and principal_uid == ^uid)
        )
      end

    query =
      if pattern,
        do:
          Ash.Query.filter(
            query,
            ilike(title, ^pattern) or
              exists(
                Message,
                conversation_id == parent(id) and not withdrawn and ilike(text, ^pattern)
              )
          ),
        else: query

    cursor = if opts[:cursor], do: cursor_row(opts[:cursor], uid)

    query
    |> after_cursor(cursor, order)
    |> Ash.Query.limit(opts[:limit] || 100)
    |> Ankole.Ash.read!()
    |> project_rooms(actor, reachable)
  end

  defp cursor_row(id, uid) do
    case Conversations.get_conversation!(id) do
      nil ->
        nil

      conversation ->
        member = participant(id, uid)

        %{
          id: id,
          last_activity_at: conversation.last_activity_at,
          pin: member && member.pinned_at
        }
    end
  end

  defp order_rooms(query, :recent, _uid),
    do: Ash.Query.sort(query, last_activity_at: :desc, id: :desc)

  defp order_rooms(query, :pinned, uid) do
    query =
      Ash.Query.aggregate(query, :viewer_pin, :first, :participants,
        field: :pinned_at,
        query: [filter: [principal_uid: uid]],
        authorize?: false
      )

    Ash.Query.sort(query, [
      {query.aggregates.viewer_pin, :desc_nils_last},
      {:last_activity_at, :desc},
      {:id, :desc}
    ])
  end

  defp after_cursor(query, nil, _order), do: query

  defp after_cursor(query, %{id: id, last_activity_at: activity}, :recent),
    do:
      Ash.Query.filter(
        query,
        last_activity_at < ^activity or (last_activity_at == ^activity and id < ^id)
      )

  defp after_cursor(query, %{id: id, last_activity_at: activity, pin: nil}, :pinned) do
    viewer_pin = %Ash.Query.Ref{attribute: query.aggregates.viewer_pin, resource: Conversation}

    Ash.Query.filter(
      query,
      is_nil(^viewer_pin) and
        (last_activity_at < ^activity or (last_activity_at == ^activity and id < ^id))
    )
  end

  defp after_cursor(query, %{id: id, last_activity_at: activity, pin: pin}, :pinned) do
    viewer_pin = %Ash.Query.Ref{attribute: query.aggregates.viewer_pin, resource: Conversation}

    Ash.Query.filter(
      query,
      is_nil(^viewer_pin) or ^viewer_pin < ^pin or
        (^viewer_pin == ^pin and
           (last_activity_at < ^activity or (last_activity_at == ^activity and id < ^id)))
    )
  end

  defp project_rooms([], _actor, _reachable), do: []

  defp project_rooms(conversations, actor, reachable) do
    ids = Enum.map(conversations, & &1.id)

    members =
      Participant
      |> Ash.Query.filter(conversation_id in ^ids)
      |> Ash.Query.sort(principal_uid: :asc)
      |> Ankole.Ash.read!()

    principals =
      Ankole.Principals.list_principals!(
        query: [
          filter: [uid: [in: Enum.map(members, & &1.principal_uid)]],
          load: [agent: :owner_principal]
        ]
      )
      |> Map.new(&{&1.uid, &1})

    grouped = Enum.group_by(members, & &1.conversation_id)
    names = Map.new(principals, fn {uid, principal} -> {uid, display_name(principal)} end)
    callable = callable_agents(actor, Map.values(principals))
    uid = Ankole.AuthZ.Actor.uid(actor)
    admin? = Ankole.AuthZ.pod_admin?(uid)
    page_ids = conversations |> Enum.map(& &1.page_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    manageable = Ankole.Pod.Pages.manageable_ids(page_ids, reachable)

    details =
      for conversation <- conversations do
        participants = Map.get(grouped, conversation.id, [])

        agents =
          for member <- participants,
              member.role == :agent,
              do: Map.fetch!(principals, member.principal_uid)

        %{
          actor: actor,
          conversation: conversation,
          agent: List.first(agents),
          agents: agents,
          participants: participants,
          member_principals: principals,
          member_names: names,
          callable_agents: callable,
          owner?:
            conversation.created_by == uid or admin? or
              (conversation.native_access_scope == :anchor_page and
                 MapSet.member?(manageable, conversation.page_id)),
          viewer: Enum.find(participants, &(&1.principal_uid == Ankole.AuthZ.Actor.uid(actor))),
          viewer_uid: Ankole.AuthZ.Actor.uid(actor)
        }
      end

    Native.read_states(details)
  end

  def visible(actor, id, opts \\ []) do
    if Native.active_human?(actor) do
      conversation =
        if opts[:lock],
          do: Queries.lock_conversation(id),
          else: Conversations.get_conversation!(id)

      case conversation do
        %Conversation{kind: :native, native_access_scope: :anchor_page, page_id: page} ->
          if Native.authorize_page(actor, page) == :ok, do: conversation

        %Conversation{kind: :native} ->
          case participant(id, Ankole.AuthZ.Actor.uid(actor)) do
            %Participant{role: role} when role != :observer -> conversation
            _ -> nil
          end

        _ ->
          nil
      end
    end
  end

  def participants(id) do
    Participant
    |> Ash.Query.filter(conversation_id == ^id)
    |> Ash.Query.sort(principal_uid: :asc)
    |> Ankole.Ash.read!()
  end

  def callable_agents(actor, principals) do
    uids = for %{type: :agent, uid: uid} <- principals, do: uid
    checks = Enum.map(uids, &%{resource: "agent:#{&1}", action: "chat"})
    context = Map.put(Ankole.AuthZ.Actor.request_context(actor), "surface", "conversation")

    case Ankole.AuthZ.authorize_checks(actor, checks, context) do
      {:ok, allowed} ->
        uids |> Enum.zip(allowed) |> Enum.filter(&elem(&1, 1)) |> MapSet.new(&elem(&1, 0))

      {:error, _} ->
        MapSet.new()
    end
  end

  def assistant_names(messages) do
    uids =
      messages
      |> Enum.flat_map(fn message ->
        [message.author_uid | Enum.map(message.mentions, & &1["uid"])]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Ankole.Principals.list_principals!(
      query: [
        filter: Ash.Expr.expr(uid in ^uids and agent.type == :personal_assistant),
        load: [agent: :owner_principal]
      ]
    )
    |> Map.new(&{&1.uid, display_name(&1)})
  end

  def participant(id, uid), do: Conversations.get_participant!(id, uid)

  def agents(id) do
    ids = for member <- participants(id), member.role == :agent, do: member.principal_uid

    if ids == [],
      do: [],
      else:
        Ankole.Principals.list_principals!(query: [filter: [uid: [in: ids]], sort: [uid: :asc]])
  end

  def teammates(actor, query \\ nil) do
    if Native.active_human?(actor) do
      filter =
        if query in [nil, ""], do: [type: :human, status: :active], else: teammate_filter(query)

      Ankole.Principals.list_principals!(
        query: [filter: filter, sort: [display_name: :asc, uid: :asc], limit: 50]
      )
    else
      []
    end
  end

  defp teammate_filter(query) do
    pattern = "%" <> Repo.escape_like(query) <> "%"
    Ash.Expr.expr(type == :human and status == :active and ilike(display_name, ^pattern))
  end

  def join(id, uid, role, intervene \\ false) do
    with {:ok, participant} <-
           Ankole.Ash.create(Participant, :join, %{
             conversation_id: id,
             principal_uid: uid,
             role: role,
             may_intervene: intervene
           }) do
      if participant.role == :observer and role != :observer,
        do: Ankole.Ash.update(participant, :participate, %{}),
        else: {:ok, participant}
    end
  end

  def join_speaker(conversation, actor) do
    join(conversation.id, Ankole.AuthZ.Actor.uid(actor), :member)
  end

  def ensure_members(actor, conversation, uids) when is_list(uids) do
    Enum.reduce_while(Enum.uniq(uids), {:ok, []}, fn uid, {:ok, added} ->
      with {:ok, principal} <- Ankole.Principals.get_principal(uid),
           true <- principal.status == :active and principal.type in [:human, :agent],
           :ok <- if(principal.type == :agent, do: Native.authorize_agent(actor, uid), else: :ok),
           existing = participant(conversation.id, uid),
           {:ok, _} <-
             join(conversation.id, uid, if(principal.type == :agent, do: :agent, else: :member)) do
        {:cont,
         {:ok, if(existing && existing.role != :observer, do: added, else: [principal | added])}}
      else
        false -> {:halt, {:error, :participant_unavailable}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def ensure_members(_, _, _), do: {:error, :invalid_request}

  def promote(conversation) do
    counts =
      Enum.frequencies_by(
        Enum.reject(participants(conversation.id), &(&1.role == :observer)),
        &if(&1.role == :agent, do: :agent, else: :human)
      )

    if conversation.room_mode == :dm and
         (Map.get(counts, :agent, 0) > 1 or Map.get(counts, :human, 0) > 1),
       do: Ankole.Ash.update(conversation, :promote_to_group, %{}),
       else: {:ok, conversation}
  end

  def target_uids(actor, id, attrs) do
    explicit = explicit_agents(attrs)
    active_agents = Enum.filter(agents(id), &(&1.status == :active))

    invited =
      if explicit == [],
        do: Enum.map(active_agents, & &1.uid),
        else: explicit

    Enum.reduce_while(Enum.uniq(invited), {:ok, []}, fn uid, {:ok, targets} ->
      case Ankole.Principals.get_principal(uid) do
        {:ok, %{type: :agent, status: :active} = agent} ->
          if Native.authorize_agent(actor, uid) == :ok do
            {:cont, {:ok, [agent | targets]}}
          else
            if explicit == [], do: {:cont, {:ok, targets}}, else: {:halt, {:error, :forbidden}}
          end

        _ ->
          if explicit == [],
            do: {:cont, {:ok, targets}},
            else: {:halt, {:error, :agent_unavailable}}
      end
    end)
    |> case do
      {:ok, candidates} ->
        candidates = Enum.sort_by(candidates, & &1.uid)
        conversation = Conversations.get_conversation!(id)

        targets =
          if explicit != [] or match?(%Conversation{room_mode: :dm}, conversation),
            do: candidates,
            else: Enum.filter(candidates, &participant(id, &1.uid).may_intervene)

        case conversation do
          %Conversation{room_mode: :dm, native_access_scope: :anchor_page}
          when targets == [] and explicit == [] and active_agents != [] ->
            {:ok, []}

          %Conversation{room_mode: :dm} when targets == [] ->
            if active_agents == [], do: {:error, :agent_unavailable}, else: {:error, :forbidden}

          _ ->
            {:ok, targets}
        end

      error ->
        error
    end
  end

  def explicit_agents(attrs) do
    mentions = Ankole.Attrs.get(attrs, :mentions) || []

    uids =
      for mention <- mentions,
          Ankole.Attrs.get(mention, :type) in ["agent", :agent],
          do: Ankole.Attrs.get(mention, :uid)

    ([Ankole.Attrs.get(attrs, :target_agent_uid)] ++ uids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def update(actor, id, attrs) do
    Repo.transact_top_level(
      fn ->
        with {:ok, id} <- Queries.cast_id(id),
             %Conversation{} = visible <- Native.visible_conversation(actor, id),
             {:ok, _} <-
               Ankole.Principals.lock_principals_in_tx([
                 Ankole.AuthZ.Actor.uid(actor),
                 visible.created_by
               ]),
             %Conversation{} = conversation <- Native.visible_conversation(actor, id, lock: true),
             {:ok, conversation} <- update_title(actor, conversation, attrs),
             {:ok, conversation} <- update_scope(actor, conversation, attrs),
             {:ok, member} <- join(conversation.id, Ankole.AuthZ.Actor.uid(actor), :observer),
             :ok <- update_preferences(member, conversation, attrs) do
          {:ok, id}
        else
          nil -> {:error, :conversation_not_found}
          error -> error
        end
      end,
      after_commit: &Conversations.Events.publish_status/1
    )
    |> case do
      {:ok, id} -> Native.get(actor, id)
      error -> error
    end
  end

  def manage(actor, id, attrs) do
    add = Ankole.Attrs.get(attrs, :add_uids) || []
    remove = Ankole.Attrs.get(attrs, :remove_uids) || []

    Repo.transact_top_level(
      fn ->
        with {:ok, id} <- Queries.cast_id(id),
             %Conversation{} = visible <- Native.visible_conversation(actor, id),
             {:ok, _} <-
               Ankole.Principals.lock_principals_in_tx(
                 Enum.uniq([Ankole.AuthZ.Actor.uid(actor), visible.created_by | add ++ remove])
               ),
             %Conversation{} = conversation <- Native.visible_conversation(actor, id, lock: true),
             :ok <- require_member_or_owner(actor, conversation),
             {:ok, added} <- ensure_members(actor, conversation, add),
             :ok <- remove_members(actor, conversation, remove),
             :ok <- set_intervention(actor, conversation, attrs),
             {:ok, conversation} <- promote(conversation),
             :ok <- notice_added(actor, conversation, added) do
          {:ok, id}
        else
          nil -> {:error, :conversation_not_found}
          error -> error
        end
      end,
      after_commit: &Conversations.Events.publish_status/1
    )
    |> case do
      {:ok, id} ->
        if Ankole.AuthZ.Actor.uid(actor) in remove, do: {:ok, nil}, else: Native.get(actor, id)

      error ->
        error
    end
  end

  def owner?(actor, conversation),
    do:
      conversation.created_by == Ankole.AuthZ.Actor.uid(actor) or
        Ankole.AuthZ.pod_admin?(Ankole.AuthZ.Actor.uid(actor)) or
        (conversation.native_access_scope == :anchor_page and
           match?(
             {:ok, _},
             Ankole.Files.authorize_node(actor, conversation.page_id, "node_manage")
           ))

  defp require_member_or_owner(actor, conversation) do
    if participant(conversation.id, Ankole.AuthZ.Actor.uid(actor)) || owner?(actor, conversation),
      do: :ok,
      else: {:error, :forbidden_room_operation}
  end

  def notice(actor, conversation, type, targets, detail \\ "") do
    now = DateTime.utc_now(:microsecond)

    with {:ok, seq} <- Queries.next_sequence_in_tx(conversation),
         {:ok, _} <-
           Ankole.Ash.create(Message, :record, %{
             id: Ankole.Ecto.UUIDv7.autogenerate(),
             conversation_id: conversation.id,
             seq: seq,
             author_type: :human,
             author_uid: Ankole.AuthZ.Actor.uid(actor),
             author_display_name: display_name(actor.principal),
             kind: :notice,
             text: detail || type,
             origin: :native,
             created_at: now,
             rich_content: %{
               "event" => %{
                 "type" => type,
                 "actor_uid" => Ankole.AuthZ.Actor.uid(actor),
                 "actor_name" => display_name(actor.principal),
                 "targets" =>
                   Enum.map(
                     targets,
                     &%{"uid" => &1.uid, "name" => display_name(&1), "type" => to_string(&1.type)}
                   ),
                 "detail" => detail
               }
             }
           }),
         {:ok, _} <- Ankole.Ash.update(conversation, :touch, %{last_activity_at: now}) do
      :ok
    end
  end

  defdelegate display_name(principal), to: Ankole.Principals

  def find_anchor_page_conversation_id(page_id, agent_uid)
      when is_binary(page_id) and is_binary(agent_uid) do
    Conversation
    |> Ash.Query.filter(
      kind == :native and page_id == ^page_id and native_access_scope == :anchor_page and
        exists(
          Participant,
          conversation_id == parent(id) and principal_uid == ^agent_uid and role == :agent
        )
    )
    |> Ash.Query.sort(last_activity_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read_one!()
    |> case do
      %Conversation{id: id} -> id
      nil -> nil
    end
  end

  def ensure_anchor_page_conversation_in_tx(actor, agent, conv_id, page_id, title_hint, now) do
    :ok = Repo.require_transaction()
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    existing =
      Conversation
      |> Ash.Query.filter(id == ^conv_id)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read_one!()

    if existing do
      conversation = Queries.lock_conversation(conv_id)
      {:ok, _} = join_speaker(conversation, actor)
      {:ok, conversation} = promote(conversation)
      {:ok, conversation, false}
    else
      title =
        case String.trim(title_hint || "") do
          "" -> "Page discussion"
          text -> String.slice(text, 0, 80)
        end

      with {:ok, _} <-
             Ankole.Ash.create(
               Conversation,
               :ensure_native,
               %{
                 id: conv_id,
                 title: title,
                 created_by: human_uid,
                 page_id: page_id,
                 last_activity_at: now
               },
               touch_update_defaults?: false
             ),
           %Conversation{} = conversation <- Queries.lock_conversation(conv_id),
           {:ok, conversation} <-
             Ankole.Ash.update(conversation, :set_access_scope, %{
               native_access_scope: :anchor_page
             }),
           {:ok, _} <- join(conv_id, human_uid, :owner),
           {:ok, _} <- join(conv_id, agent.uid, :agent, true),
           {:ok, conversation} <- ModelPreferences.initialize(conversation, agent.uid, nil),
           {:ok, _} <-
             AIGateway.ensure_conversation_in_tx(
               agent.uid,
               Ankole.Sessions.Key.conversation(conv_id)
             ) do
        {:ok, conversation, true}
      end
    end
  end

  def notice_added(_actor, _conversation, []), do: :ok

  def notice_added(actor, conversation, added),
    do: notice(actor, conversation, "participants_added", added, "Participants joined")

  defp update_title(actor, conversation, attrs) do
    case Ankole.Attrs.get(attrs, :title) do
      nil ->
        {:ok, conversation}

      title when is_binary(title) ->
        customized = String.trim(title) != ""
        title = if customized, do: String.trim(title), else: default_title(conversation)

        with :ok <- require_member_or_owner(actor, conversation),
             {:ok, conversation} <-
               Ankole.Ash.update(conversation, :rename_title, %{
                 title: title,
                 title_customized: customized
               }),
             :ok <- notice(actor, conversation, "title_renamed", [], title),
             do: {:ok, conversation}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp default_title(conversation) do
    first =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and author_type == :human and kind == :message
      )
      |> Ash.Query.sort(seq: :asc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    Native.conversation_title(first.text, first.attachments)
  end

  defp update_scope(actor, conversation, attrs) do
    case Ankole.Attrs.get(attrs, :access_scope) do
      nil ->
        {:ok, conversation}

      scope when scope in [:participants, "participants", :anchor_page, "anchor_page"] ->
        scope = if to_string(scope) == "anchor_page", do: :anchor_page, else: :participants

        cond do
          not owner?(actor, conversation) ->
            {:error, :forbidden_room_operation}

          scope == :anchor_page and is_nil(conversation.page_id) ->
            {:error, :anchor_page_required}

          scope == :anchor_page and Native.authorize_page(actor, conversation.page_id) != :ok ->
            {:error, :page_unavailable}

          true ->
            with {:ok, conversation} <-
                   Ankole.Ash.update(conversation, :set_access_scope, %{
                     native_access_scope: scope
                   }),
                 :ok <- notice(actor, conversation, "access_scope_changed", [], to_string(scope)),
                 do: {:ok, conversation}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp update_preferences(member, conversation, attrs) do
    updates = %{}

    updates =
      case Ankole.Attrs.get(attrs, :pinned) do
        nil -> updates
        true -> Map.put(updates, :pinned_at, member.pinned_at || DateTime.utc_now(:microsecond))
        false -> Map.put(updates, :pinned_at, nil)
      end

    updates =
      case Ankole.Attrs.get(attrs, :muted) do
        nil -> updates
        value when is_boolean(value) -> Map.put(updates, :muted, value)
      end

    updates =
      case Ankole.Attrs.get(attrs, :last_read_seq) do
        nil ->
          updates

        seq when is_integer(seq) and seq >= 0 ->
          Map.put(
            updates,
            :last_read_seq,
            min(max(seq, member.last_read_seq), conversation.sequence_high_water)
          )
      end

    with {:ok, _} <- Ankole.Ash.update(member, :update_preferences, updates), do: :ok
  end

  defp remove_members(actor, conversation, uids) do
    Enum.reduce_while(uids, :ok, fn uid, :ok ->
      member = participant(conversation.id, uid)

      cond do
        is_nil(member) ->
          {:cont, :ok}

        not owner?(actor, conversation) and uid != Ankole.AuthZ.Actor.uid(actor) ->
          {:halt, {:error, :forbidden_room_operation}}

        member.role == :agent and length(agents(conversation.id)) <= 1 ->
          {:halt, {:error, :cannot_remove_last_participant}}

        member.role == :owner ->
          {:halt, {:error, :forbidden_room_operation}}

        true ->
          with {:ok, principal} <- Ankole.Principals.get_principal(uid),
               {:ok, _} <- Ankole.Ash.destroy(member, :leave),
               :ok <-
                 notice(
                   actor,
                   conversation,
                   "participant_removed",
                   [principal],
                   "Participant left"
                 ) do
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
      end
    end)
  end

  defp set_intervention(actor, conversation, attrs) do
    case Ankole.Attrs.get(attrs, :agent_uid) do
      nil ->
        :ok

      uid ->
        case participant(conversation.id, uid) do
          %Participant{role: :agent} = member ->
            with :ok <- Native.authorize_agent(actor, uid),
                 {:ok, _} <-
                   Ankole.Ash.update(member, :set_may_intervene, %{
                     may_intervene: Ankole.Attrs.get(attrs, :may_intervene)
                   }),
                 do: :ok

          _ ->
            {:error, :participant_unavailable}
        end
    end
  end
end
