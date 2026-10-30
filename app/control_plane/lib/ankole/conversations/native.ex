defmodule Ankole.Conversations.Native do
  @moduledoc false

  require Ash.Query

  alias Ankole.{AIGateway, Repo, Signals}

  alias Ankole.Conversations.{
    Conversation,
    Message,
    ModelPreferences,
    NativeQueue,
    NativeRoom,
    Participant,
    Queries
  }

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.Principals.WorkAccess
  alias Ankole.Signals.Signal

  @addressed "conversation.message.addressed"

  @doc "Returns trusted browser facts from the work's native input."
  def request_context(signal), do: request_context(signal, MapSet.new())

  defp request_context(
         %Signal{
           producer: :kernel,
           type: @addressed,
           conversation_id: id,
           source: source,
           session_id: session,
           data: %{"request_context" => context}
         },
         _visited
       )
       when is_binary(id) and is_map(context) do
    if source == Ankole.Sessions.Key.conversation(id) and session == source,
      do: Map.take(context, ["ip", "authn"]),
      else: %{}
  end

  defp request_context(%Signal{producer: :kernel, authorization_kind: "human"} = signal, visited) do
    if MapSet.member?(visited, signal.id) do
      %{}
    else
      signal
      |> Ankole.Conversations.Route.authorization_source()
      |> request_context(MapSet.put(visited, signal.id))
    end
  end

  defp request_context(_signal, _visited), do: %{}

  def agents(%Ankole.AuthZ.Actor{} = actor) do
    if active_human?(actor) do
      Ankole.Principals.list_principals!(
        query: [
          filter: [type: :agent, status: :active],
          sort: [display_name: :asc, uid: :asc]
        ]
      )
      |> Enum.filter(&(authorize_agent(actor, &1.uid) == :ok))
    else
      []
    end
  end

  def model_profiles(%Ankole.AuthZ.Actor{} = actor, agent_uid) do
    with true <- active_human?(actor),
         :ok <- authorize_agent(actor, agent_uid) do
      ModelPreferences.catalog(agent_uid)
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  @doc """
  Returns a native room that the current Human can read.

  This read takes no lock and opens no transaction, so a caller can use it in
  its own transaction. `get/3` gives the complete detail.
  """
  def visible_native_conversation(%Ankole.AuthZ.Actor{} = actor, id) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} = conversation <- visible_conversation(actor, id) do
      {:ok, conversation}
    else
      {:error, _} = error -> error
      nil -> {:error, :conversation_not_found}
    end
  end

  def model_preferences(%Ankole.AuthZ.Actor{} = actor, id, agent_uid \\ nil) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} = conversation <- visible_conversation(actor, id),
         %{} = agent <- selected_agent(id, agent_uid),
         :ok <- authorize_agent(actor, agent.uid) do
      ModelPreferences.selection(conversation, agent.uid)
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def set_model_profile(actor, id, profile, agent_uid \\ nil) do
    Repo.transact_top_level(
      fn -> set_model_profile_in_tx(actor, id, profile, agent_uid) end,
      after_commit: fn _ -> Ankole.Conversations.Events.publish_status(id) end
    )
  end

  def set_model_profile_in_tx(actor, id, profile, agent_uid \\ nil) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} <- visible_conversation(actor, id),
         %{} = agent <- selected_agent(id, agent_uid),
         :ok <- lock_participants_in_tx(actor, agent.uid, id),
         :ok <-
           Signals.lock_target_in_tx(%{
             agent_uid: agent.uid,
             session_id: Ankole.Sessions.Key.conversation(id)
           }),
         :ok <- check_human_in_tx(actor),
         {:ok, agent} <- active_agent_in_tx(agent.uid),
         :ok <- authorize_agent(actor, agent.uid),
         %Conversation{} = conversation <- visible_conversation(actor, id, lock: true),
         {:ok, profile} <- ModelPreferences.validate(agent.uid, profile),
         {:ok, conversation} <- ModelPreferences.put(conversation, agent.uid, profile) do
      ModelPreferences.selection(conversation, agent.uid)
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def selected_agent(id, nil), do: conversation_agent(id)
  def selected_agent(id, uid), do: Enum.find(room_agents(id), &(&1.uid == uid))

  def list(%Ankole.AuthZ.Actor{} = actor) do
    list_native(actor, nil)
  end

  @doc "Lists visible conversations attached to a Page."
  def list_for_page(%Ankole.AuthZ.Actor{} = actor, page_id) do
    with {:ok, page_id} <- Queries.cast_id(page_id),
         :ok <- authorize_page(actor, page_id) do
      {:ok, list_native(actor, page_id)}
    end
  end

  defp list_native(actor, page_id), do: list_rooms(actor, page_id: page_id)

  def list_rooms(actor, opts \\ []), do: NativeRoom.list(actor, opts)

  def get(%Ankole.AuthZ.Actor{} = actor, id, opts \\ []) do
    Repo.transact_repeatable_read_only(fn ->
      detail_in_tx(actor, id, opts)
    end)
  end

  @doc false
  def detail_in_tx(%Ankole.AuthZ.Actor{} = actor, id, opts) do
    before = Keyword.get(opts, :before_seq)
    loaded_first = Keyword.get(opts, :loaded_first_seq)

    with true <- is_nil(before) or (is_integer(before) and before > 0),
         true <- is_nil(loaded_first) or (is_integer(loaded_first) and loaded_first > 0),
         {:ok, id} <- Queries.cast_id(id) do
      case visible_conversation(actor, id) do
        %Conversation{} = conversation ->
          {:ok, detail(conversation, Keyword.put(opts, :actor, actor))}

        _ ->
          {:error, :conversation_not_found}
      end
    else
      false -> {:error, :invalid_request}
      {:error, _} = error -> error
    end
  end

  def create(%Ankole.AuthZ.Actor{} = actor, attrs) do
    Repo.transact_top_level(
      fn -> create_in_tx(actor, attrs) end,
      after_commit: &publish_native_change/1
    )
    |> committed(actor)
  end

  @doc "Creates a native conversation and returns publication facts to its transaction owner."
  def create_in_tx(%Ankole.AuthZ.Actor{} = actor, attrs) when is_map(attrs) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    initial_agents =
      Ankole.Attrs.get(attrs, :agent_uids) || List.wrap(Ankole.Attrs.get(attrs, :agent_uid))

    invited = Ankole.Attrs.get(attrs, :participant_uids) || []

    with :ok <- Repo.require_transaction(),
         {:ok, id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :conversation_id)),
         {:ok, message_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)),
         {:ok, mode} <- delivery_mode(Ankole.Attrs.get(attrs, :delivery_mode)),
         {:ok, page_id} <- optional_page_id(Ankole.Attrs.get(attrs, :page_id)),
         [first | _] <- initial_agents,
         {:ok, _} <-
           Ankole.Principals.lock_principals_in_tx(
             Enum.uniq([human_uid | initial_agents ++ invited])
             |> Enum.sort()
           ),
         :ok <- check_human_in_tx(actor),
         {:ok, agent} <- active_agent_in_tx(first),
         :ok <- authorize_agent(actor, first),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx(
             Enum.map(initial_agents, &{&1, Ankole.Sessions.Key.conversation(id)})
           ),
         {:ok, text, attachments} <- human_content(actor, id, message_id, attrs),
         :ok <- authorize_page(actor, page_id),
         {:ok, conversation} <-
           ensure_conversation_in_tx(
             actor,
             agent,
             id,
             conversation_title(text, attachments),
             page_id
           ),
         {:ok, _} <- NativeRoom.ensure_members(actor, conversation, initial_agents ++ invited),
         {:ok, conversation} <- NativeRoom.promote(conversation),
         {:ok, conversation} <-
           ModelPreferences.initialize(
             conversation,
             agent.uid,
             Ankole.Attrs.get(attrs, :model_profile)
           ),
         {:ok, _} <- initialize_scope(conversation, Ankole.Attrs.get(attrs, :access_scope)),
         {:ok, message, inserted?} <-
           append_human_message_in_tx(
             conversation,
             human_uid,
             message_id,
             text,
             attachments,
             attrs
           ),
         true <- message.seq == 1,
         {:ok, targets} <- NativeRoom.target_uids(actor, id, attrs),
         {:ok, events} <-
           accept_targets(
             conversation,
             targets,
             message,
             mode,
             actor,
             inserted?,
             optional_reply?(conversation, attrs)
           ) do
      {:ok, result(id, events, inserted?)}
    else
      false -> {:error, :conversation_conflict}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def create_in_tx(_human_uid, _attrs), do: {:error, :invalid_request}

  defp initialize_scope(conversation, scope) when scope in [nil, "participants", :participants],
    do: {:ok, conversation}

  defp initialize_scope(%Conversation{page_id: nil}, _), do: {:error, :anchor_page_required}

  defp initialize_scope(conversation, scope) when scope in ["anchor_page", :anchor_page],
    do: Ankole.Ash.update(conversation, :set_access_scope, %{native_access_scope: :anchor_page})

  defp initialize_scope(_, _), do: {:error, :invalid_request}

  defp accept_targets(conversation, agents, message, mode, actor, inserted?, optional_reply?) do
    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, events} ->
      with :ok <- ModelPreferences.authorize_input(conversation, agent.uid, mode, inserted?),
           {:ok, event} <-
             accept_message_in_tx(conversation, agent, message, mode, actor, optional_reply?),
           do: {:cont, {:ok, [event | events]}},
           else: (error -> {:halt, error})
    end)
  end

  defp optional_reply?(%Conversation{room_mode: :group}, attrs),
    do: NativeRoom.explicit_agents(attrs) == []

  defp optional_reply?(_conversation, _attrs), do: false

  defp result(id, events, inserted?) do
    keys = Enum.map(events, &%{agent_uid: &1.agent_uid, session_id: &1.session_id})

    %{
      id: id,
      event: List.first(events),
      events: events,
      session_keys: keys,
      session_key: List.first(keys),
      inserted?: inserted?,
      publications: publications(id, inserted?)
    }
  end

  def post(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    Repo.transact_top_level(
      fn -> post_in_tx(actor, id, attrs) end,
      after_commit: &publish_native_change/1
    )
    |> committed(actor)
  end

  @doc "Deletes the room for its owner or a Pod administrator."
  def delete(actor, id, opts \\ []) do
    Repo.transact_top_level(fn -> delete_in_tx(actor, id, opts) end,
      after_commit: &Ankole.Conversations.Events.publish_status/1
    )
  end

  def delete_in_tx(actor, id, opts \\ []) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} <- visible_conversation(actor, id),
         agents = room_agents(id),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx(
             Enum.map(agents, &{&1.uid, Ankole.Sessions.Key.conversation(id)})
           ),
         %Conversation{} = conversation <- visible_conversation(actor, id, lock: true),
         true <- NativeRoom.owner?(actor, conversation),
         :ok <- ensure_idle_or_stop(conversation, agents, opts[:force_stop]),
         {:ok, _} <- Ankole.Ash.destroy(conversation, :remove) do
      {:ok, id}
    else
      false -> {:error, :forbidden_room_operation}
      nil -> {:error, :conversation_not_found}
      error -> error
    end
  end

  defp ensure_idle_or_stop(conversation, agents, force?) do
    if busy?(conversation.id) and force? != true do
      {:error, :conversation_busy}
    else
      now = DateTime.utc_now(:microsecond)

      Enum.reduce_while(agents, :ok, fn agent, :ok ->
        with {:ok, _} <-
               AIGateway.end_active_conversation_in_tx(
                 agent.uid,
                 Ankole.Sessions.Key.conversation(conversation.id),
                 now
               ),
             do: {:cont, :ok},
             else: (error -> {:halt, error})
      end)
    end
  end

  defp busy?(id) do
    Signals.list_signals!(
      query: [
        filter: [
          or: [[conversation_id: id], [session_id: Ankole.Sessions.Key.conversation(id)]],
          status: [in: [:queued, :running]]
        ],
        limit: 1,
        select: [:id]
      ]
    ) != []
  end

  @doc "Appends human input and returns publication facts to its transaction owner."
  def post_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) when is_map(attrs) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    with :ok <- Repo.require_transaction(),
         {:ok, id} <- Queries.cast_id(id),
         {:ok, message_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)),
         {:ok, mode} <- delivery_mode(Ankole.Attrs.get(attrs, :delivery_mode)),
         %Conversation{} = visible <- visible_conversation(actor, id),
         {:ok, targets} <- NativeRoom.target_uids(actor, id, attrs),
         {:ok, _} <-
           Ankole.Principals.lock_principals_in_tx(
             Enum.uniq([human_uid, visible.created_by | Enum.map(targets, & &1.uid)])
             |> Enum.sort()
           ),
         :ok <- check_human_in_tx(actor),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx(
             Enum.map(targets, &{&1.uid, Ankole.Sessions.Key.conversation(id)})
           ),
         %Conversation{} = conversation <- visible_conversation(actor, id, lock: true),
         {:ok, _} <- NativeRoom.join_speaker(conversation, actor),
         {:ok, added} <-
           NativeRoom.ensure_members(actor, conversation, NativeRoom.explicit_agents(attrs)),
         {:ok, conversation} <- NativeRoom.promote(conversation),
         {:ok, text, attachments} <- human_content(actor, id, message_id, attrs),
         {:ok, message, inserted?} <-
           append_human_message_in_tx(
             conversation,
             human_uid,
             message_id,
             text,
             attachments,
             attrs
           ),
         :ok <- NativeRoom.notice_added(actor, conversation, added),
         {:ok, events} <-
           accept_targets(
             conversation,
             targets,
             message,
             mode,
             actor,
             inserted?,
             optional_reply?(conversation, attrs)
           ) do
      {:ok, result(id, events, inserted?)}
    else
      nil -> {:error, :conversation_not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def post_in_tx(_human_uid, _id, _attrs), do: {:error, :invalid_request}

  @doc "Commits a statement to its native host or external Delivery destination."
  def post_in_tx(
        %StatementTarget{kind: :external} = target,
        %Ankole.Conversations.Statement{} = statement
      ),
      do: Ankole.Conversations.Delivery.Posting.post_in_tx(target, statement)

  def post_in_tx(
        %StatementTarget{kind: :native} = target,
        %Ankole.Conversations.Statement{} = statement
      ) do
    text = Ankole.Conversations.Statement.text(statement)
    kind = if statement.notice, do: :notice, else: :message

    attachments =
      if is_map(statement.completion),
        do: Map.get(statement.completion, :attachments, []),
        else: []

    with {:ok, attachments} <-
           Ankole.Conversations.Delivery.Attachment.normalize_attachments(attachments) do
      if text in [nil, ""] and attachments == [] do
        {:ok, %Ankole.Conversations.PostResult{}}
      else
        with {:ok, message} <-
               post_native_in_tx(
                 target.conversation_id,
                 statement.signal,
                 text,
                 kind,
                 attachments,
                 rich_content:
                   Map.take(statement.completion || %{}, [:execution])
                   |> Map.new(fn {k, v} -> {to_string(k), v} end)
               ),
             do: {:ok, %Ankole.Conversations.PostResult{messages: [message]}}
      end
    end
  end

  def post_native_in_tx(id, event, text, kind, attachments, opts \\ []) do
    delivery_key = Keyword.get(opts, :delivery_key, "final")
    rich_content = Keyword.get(opts, :rich_content, %{})

    with {:ok, id} <- Queries.cast_id(id),
         {:ok, text} <- native_text(text, attachments),
         %Conversation{kind: :native} = conversation <- Queries.lock_conversation(id),
         %Participant{role: :agent} <- NativeRoom.participant(id, event.agent_uid) do
      uid = event.agent_uid

      case Message
           |> Ash.Query.filter(
             conversation_id == ^id and signal_id == ^event.id and delivery_key == ^delivery_key
           )
           |> Ankole.Ash.read_one!() do
        %Message{text: ^text, kind: ^kind, attachments: ^attachments} = message ->
          {:ok, message}

        %Message{} ->
          {:error, :conversation_conflict}

        nil ->
          with :ok <-
                 Ankole.Conversations.Delivery.Attachment.verify_in_drive(
                   event.agent_uid,
                   attachments
                 ),
               :ok <-
                 Ankole.Files.reference_contents_in_tx(Enum.map(attachments, & &1["blob_ref"])),
               {:ok, seq} <- Queries.next_sequence_in_tx(conversation) do
            attrs = %{
              id: Ankole.Ecto.UUIDv7.autogenerate(),
              conversation_id: id,
              seq: seq,
              author_type: :agent,
              author_uid: uid,
              delivery_key: delivery_key,
              rich_content: rich_content,
              kind: kind,
              text: text,
              attachments: attachments,
              links: page_links(text),
              origin: :native,
              session_id: event.session_id,
              signal_id: event.id,
              reply_to_message_id:
                if(is_map(event.data) and event.data["conversation_id"] == id,
                  do: event.message_id
                ),
              created_at: DateTime.utc_now(:microsecond)
            }

            with {:ok, message} <- Ankole.Ash.create(Message, :record, attrs),
                 {:ok, _} <- touch(conversation, message.created_at) do
              {:ok, message}
            end
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  defp publications(id, true), do: [{id, :message}]
  defp publications(_id, false), do: []

  @doc false
  def publish_native_change(%{publications: publications} = result) do
    Ankole.Conversations.Events.publish_committed(publications)

    if publications != [] do
      keys = Map.get(result, :session_keys, List.wrap(result.session_key))
      Enum.each(keys, &Ankole.Sessions.Events.publish_status(&1.agent_uid, &1.session_id))
    end

    :ok
  end

  @doc false
  def committed({:ok, %{id: id} = result}, human_uid),
    do: get(human_uid, id, removed_message_ids: Map.get(result, :removed_message_ids, []))

  def committed({:error, _} = error, _human_uid), do: error

  defp ensure_conversation_in_tx(%Ankole.AuthZ.Actor{} = actor, agent, id, text, page_id) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    attrs = %{
      id: id,
      title: text,
      created_by: human_uid,
      page_id: page_id,
      last_activity_at: DateTime.utc_now(:microsecond)
    }

    with :ok <- available_native_id(agent.uid, id),
         {:ok, _} <-
           Ankole.Ash.create(Conversation, :ensure_native, attrs, touch_update_defaults?: false),
         %Conversation{created_by: ^human_uid, page_id: ^page_id} = conversation <-
           Queries.lock_conversation(id),
         true <-
           conversation.sequence_high_water == 0 or
             match?(%Participant{role: :agent}, NativeRoom.participant(id, agent.uid)),
         {:ok, _} <- NativeRoom.join(id, human_uid, :owner),
         {:ok, _} <- NativeRoom.join(id, agent.uid, :agent, true),
         {:ok, _} <-
           AIGateway.ensure_conversation_in_tx(
             agent.uid,
             Ankole.Sessions.Key.conversation(id)
           ) do
      {:ok, conversation}
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_conflict}
    end
  end

  defp available_native_id(agent_uid, id) do
    session_id = Ankole.Sessions.Key.conversation(id)

    exists? =
      Conversation
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read_one!()
      |> is_struct()

    used? =
      AIGateway.conversation_exists_by_key?(agent_uid, session_id) or
        Signals.list_signals!(
          query: [
            filter: [agent_uid: agent_uid, session_id: session_id],
            limit: 1,
            select: [:id]
          ]
        ) != []

    if exists? or not used?, do: :ok, else: {:error, :conversation_conflict}
  end

  defp optional_page_id(nil), do: {:ok, nil}
  defp optional_page_id(id), do: Queries.cast_id(id)

  @doc false
  def authorize_page(_uid, nil), do: :ok

  def authorize_page(%Ankole.AuthZ.Actor{} = actor, id) do
    case Ankole.Pod.Pages.authorize(actor, id, "page_view", trash: false) do
      {:ok, _} -> :ok
      _ -> {:error, :page_unavailable}
    end
  end

  defp human_content(%Ankole.AuthZ.Actor{} = actor, conversation_id, message_id, attrs) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    existing =
      Message
      |> Ash.Query.filter(
        id == ^message_id and conversation_id == ^conversation_id and author_uid == ^uid
      )
      |> Ankole.Ash.read_one!()

    with {:ok, attachments} <-
           Ankole.Conversations.Attachments.Native.resolve(
             uid,
             Ankole.Attrs.get(attrs, :attachments),
             if(existing, do: existing.attachments, else: [])
           ),
         {:ok, text} <- native_text(Ankole.Attrs.get(attrs, :text), attachments) do
      {:ok, text, attachments}
    end
  end

  @doc "Derives a room title from its first Human message."
  def conversation_title(text, attachments) do
    (text || hd(attachments)["name"])
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 80)
  end

  defp append_human_message_in_tx(conversation, human_uid, id, text, attachments, input_attrs) do
    existing = message(id)

    links =
      Enum.uniq(
        page_links(text) ++
          NativeQueue.canonical_links(Ankole.Attrs.get(input_attrs, :links) || [])
      )

    mentions = NativeQueue.canonical_mentions(Ankole.Attrs.get(input_attrs, :mentions) || [])
    target_uid = Ankole.Attrs.get(input_attrs, :target_agent_uid)

    attachments =
      Ankole.Conversations.Attachments.prepare_native_in_tx(
        conversation.id,
        id,
        attachments,
        if(existing, do: existing.attachments, else: [])
      )

    case existing do
      %Message{
        conversation_id: conversation_id,
        author_uid: ^human_uid,
        text: ^text,
        attachments: ^attachments,
        author_type: :human,
        kind: :message
      } = message
      when conversation_id == conversation.id ->
        if Enum.sort(NativeQueue.canonical_links(message.links)) == Enum.sort(links) and
             Enum.sort(NativeQueue.canonical_mentions(message.mentions)) == Enum.sort(mentions) and
             message.rich_content["target_agent_uid"] == target_uid,
           do: {:ok, message, false},
           else: {:error, :conversation_conflict}

      %Message{} ->
        {:error, :conversation_conflict}

      nil ->
        with :ok <-
               Ankole.Files.reference_contents_in_tx(Enum.map(attachments, & &1["blob_ref"])),
             {:ok, seq} <- Queries.next_sequence_in_tx(conversation) do
          attrs = %{
            id: id,
            conversation_id: conversation.id,
            seq: seq,
            author_type: :human,
            author_uid: human_uid,
            kind: :message,
            text: text,
            attachments: attachments,
            links: links,
            mentions: mentions,
            rich_content: %{"target_agent_uid" => target_uid},
            origin: :native,
            created_at: DateTime.utc_now(:microsecond)
          }

          with {:ok, _} <-
                 Ankole.Ash.create(Message, :record_once, attrs),
               %Message{
                 conversation_id: conversation_id,
                 author_uid: ^human_uid,
                 text: ^text,
                 attachments: ^attachments,
                 author_type: :human,
                 kind: :message
               } = message <- message(id),
               true <- conversation_id == conversation.id,
               {:ok, _} <- touch(conversation, message.created_at) do
            {:ok, message, true}
          else
            {:error, _} = error -> error
            _ -> {:error, :conversation_conflict}
          end
        end
    end
  end

  defp accept_message_in_tx(conversation, agent, message, mode, actor, optional_reply?) do
    data = %{
      "conversation_id" => conversation.id,
      "message_id" => message.id,
      "message_ids" => [message.id],
      "author_uid" => message.author_uid,
      "text" => message.text,
      "request_context" => Ankole.AuthZ.Actor.request_context(actor),
      "model_profile" => ModelPreferences.logical(conversation, agent.uid)
    }

    data = if optional_reply?, do: Map.put(data, "optional_reply", true), else: data
    data = if mode == "queue", do: Map.put(data, "delivery_mode", mode), else: data

    data =
      if message.attachments == [],
        do: data,
        else:
          Map.put(data, "entry", %{"text" => message.text, "attachments" => message.attachments})

    Signals.accept_in_tx(%{
      producer: :kernel,
      source: Ankole.Sessions.Key.conversation(conversation.id),
      id: message.id,
      type: @addressed,
      subject: conversation.id,
      target: %{agent_uid: agent.uid, conversation_id: conversation.id},
      sender: message.author_uid,
      message_id: message.id,
      time: message.created_at,
      data: data
    })
  end

  defp delivery_mode(nil), do: {:ok, "steer"}
  defp delivery_mode(mode) when mode in ["steer", "queue"], do: {:ok, mode}
  defp delivery_mode(_mode), do: {:error, :invalid_request}

  @doc false
  def pending_filter(conversation_id) do
    [
      conversation_id: conversation_id,
      type: @addressed,
      status: [in: [:queued, :running]],
      last_attempt_at: [is_nil: true]
    ]
  end

  defp touch(conversation, now) do
    Ankole.Ash.update(conversation, :touch, %{last_activity_at: now})
  end

  @doc false
  def message(id), do: Message |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  @doc false
  def lock_participants_in_tx(%Ankole.AuthZ.Actor{} = actor, agent_uid, id \\ nil) do
    if id do
      lock_session_participants_in_tx(
        %{agent_uid: agent_uid, session_id: Ankole.Sessions.Key.conversation(id)},
        [Ankole.AuthZ.Actor.uid(actor)]
      )
    else
      lock_principal_uids([Ankole.AuthZ.Actor.uid(actor), agent_uid])
    end
  end

  @doc "Locks Principal references before a native Session write takes its Session lock."
  def lock_session_participants_in_tx(%{agent_uid: uid, session_id: session}, human_uids) do
    case Ankole.Sessions.Key.parse(session) do
      {:conversation, id} ->
        case Conversation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!() do
          %Conversation{kind: :native, created_by: creator} ->
            lock_principal_uids([uid, creator | human_uids])

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp lock_principal_uids(uids) do
    with {:ok, _} <- Ankole.Principals.lock_principals_in_tx(Enum.reject(uids, &is_nil/1)),
         do: :ok
  end

  @doc false
  def check_human_in_tx(%Ankole.AuthZ.Actor{} = actor) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    if active_human?(actor),
      do: WorkAccess.check_in_tx(WorkAccess.from_sender(human_uid)),
      else: {:error, :invalid_request}
  end

  def authorize_agent(%Ankole.AuthZ.Actor{} = actor, agent_uid) do
    context = Map.put(Ankole.AuthZ.Actor.request_context(actor), "surface", "conversation")
    Ankole.AuthZ.authorize(actor, "agent:#{agent_uid}", "chat", context)
  end

  defp active_agent_in_tx(agent_uid) do
    case Ankole.Principals.lock_principals_in_tx([agent_uid]) do
      {:ok, [%{type: :agent, status: :active} = agent]} -> {:ok, agent}
      _ -> {:error, :agent_unavailable}
    end
  end

  def active_human?(%Ankole.AuthZ.Actor{} = actor) do
    with {:ok, %{type: :human, status: :active} = principal} <-
           Ankole.Principals.get_principal(Ankole.AuthZ.Actor.uid(actor)),
         {:ok, _} <- Ankole.Pod.principal(%{actor | principal: principal}),
         do: true,
         else: (_ -> false)
  end

  @doc false
  def visible_conversation(actor, id, opts \\ []), do: NativeRoom.visible(actor, id, opts)
  def visible_conversation?(actor, id), do: not is_nil(visible_conversation(actor, id))
  def room_agents(id), do: NativeRoom.agents(id)
  def conversation_agent(id), do: List.first(room_agents(id))

  @doc false
  def read_states(details, opts \\ [])

  def read_states([], _opts), do: []

  def read_states(details, opts) do
    ids = Enum.map(details, & &1.conversation.id)
    sessions = Enum.map(ids, &Ankole.Sessions.Key.conversation/1)

    keys =
      for detail <- details,
          agent <- detail.agents,
          do: {agent.uid, Ankole.Sessions.Key.conversation(detail.conversation.id)}

    statuses = Ankole.Sessions.statuses(keys)
    questions = Ankole.Conversations.latest_native_questions(ids)

    cards =
      Enum.flat_map(details, &Map.get(&1, :messages, []))
      |> Enum.filter(&is_map(&1.rich_content["clarify"]))

    interactions =
      Ankole.Conversations.Delivery.Interactions.native_interactions(questions ++ cards)

    job_filter =
      if opts[:history], do: [], else: [status: [in: [:queued, :running, :waiting_on_user]]]

    workflow_filter = if opts[:history], do: [], else: [status: :running]

    fields = [
      :id,
      :agent_uid,
      :owner_session_id,
      :source_signal_id,
      :title,
      :status,
      :inserted_at,
      :updated_at
    ]

    jobs =
      Ankole.BackgroundAgentJobs.list_jobs!(
        query: [
          filter: [owner_session_id: [in: sessions]] ++ job_filter,
          select: fields,
          sort: [inserted_at: :desc]
        ]
      )

    workflows =
      Ankole.Workflow.list_runs!(
        query: [
          filter: [owner_session_id: [in: sessions]] ++ workflow_filter,
          select: fields,
          sort: [inserted_at: :desc]
        ]
      )

    source_ids =
      (jobs ++ workflows)
      |> Enum.map(& &1.source_signal_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    sources =
      Ankole.Signals.list_signals!(
        query: [
          filter: [id: [in: source_ids]],
          select: [:id, :agent_uid, :conversation_id, :message_id]
        ]
      )
      |> Map.new(&{&1.id, &1})

    grouped_questions = Enum.group_by(questions, & &1.conversation_id)
    grouped_jobs = Enum.group_by(jobs, & &1.owner_session_id)
    grouped_workflows = Enum.group_by(workflows, & &1.owner_session_id)

    for detail <- details do
      session = Ankole.Sessions.Key.conversation(detail.conversation.id)

      Map.merge(detail, %{
        statuses: Map.new(detail.agents, &{&1.uid, statuses[{&1.uid, session}]}),
        pending_questions: Map.get(grouped_questions, detail.conversation.id, []),
        interaction_states: interactions,
        linked_jobs: Map.get(grouped_jobs, session, []),
        linked_workflows: Map.get(grouped_workflows, session, []),
        source_signals: sources
      })
    end
  end

  defp detail(conversation, opts) do
    actor = Keyword.fetch!(opts, :actor)
    viewer_uid = Ankole.AuthZ.Actor.uid(actor)
    participants = NativeRoom.participants(conversation.id)

    principals =
      Ankole.Principals.list_principals!(
        query: [filter: [uid: [in: Enum.map(participants, & &1.principal_uid)]]]
      )
      |> Map.new(&{&1.uid, &1})

    agents =
      for member <- participants,
          member.role == :agent,
          do: Map.fetch!(principals, member.principal_uid)

    agent = List.first(agents)
    {messages, older_before} = history_window(conversation, opts)
    removed_ids = removed_messages(conversation, older_before, opts)

    model =
      if(agent,
        do:
          AIGateway.list_active_conversations(
            subject_uid: agent.uid,
            conversation_key: Ankole.Sessions.Key.conversation(conversation.id),
            limit: 1
          ),
        else: []
      )
      |> List.first()

    pending_inputs =
      Signals.list_signals!(
        query: [filter: pending_filter(conversation.id), sort: [queue_sequence: :asc]]
      )

    retryable = Map.new(agents, &{&1.uid, retryable_message_id(conversation, &1)})

    retryable_ids = Enum.reject(Map.values(retryable), &is_nil/1)

    latest_retryable =
      Message
      |> Ash.Query.filter(id in ^retryable_ids)
      |> Ash.Query.sort(seq: :desc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    queued_messages =
      Ankole.Conversations.list_messages!(
        query: [
          filter: [id: [in: Enum.map(pending_inputs, & &1.message_id)]],
          select: [:id, :links, :mentions]
        ]
      )
      |> Map.new(&{&1.id, &1})

    mentioned_uids =
      queued_messages
      |> Map.values()
      |> Enum.flat_map(fn message ->
        Enum.map(message.mentions, & &1["uid"])
      end)
      |> Enum.uniq()

    mention_names =
      Ankole.Principals.list_principals!(
        query: [filter: [uid: [in: mentioned_uids]], select: [:uid, :display_name]]
      )
      |> Map.new(&{&1.uid, &1.display_name})

    {:ok, pages} = Ankole.Pod.Pages.saved_from_conversation(actor, conversation.id)
    saved = Enum.group_by(pages, & &1.saved_from_message_id, &%{id: &1.id, title: &1.title})
    saved_message_ids = Map.keys(saved)

    artifacts =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and seq <= ^conversation.sequence_high_water and
          not withdrawn and (links != [] or attachments != [] or id in ^saved_message_ids)
      )
      |> Ash.Query.select([:id, :conversation_id, :links, :attachments, :seq])
      |> Ash.Query.sort(seq: :asc)
      |> Ankole.Ash.read!()

    latest_input =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and seq <= ^conversation.sequence_high_water and
          not withdrawn and author_type == :human and kind == :message
      )
      |> Ash.Query.select([:id, :conversation_id, :author_uid])
      |> Ash.Query.sort(seq: :desc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    detail = %{
      actor: actor,
      conversation: conversation,
      agent: agent,
      agents: agents,
      participants: participants,
      member_principals: principals,
      owner?: NativeRoom.owner?(actor, conversation),
      viewer_uid: viewer_uid,
      viewer: Enum.find(participants, &(&1.principal_uid == viewer_uid)),
      messages: messages,
      older_messages_before_seq: older_before,
      message_range: %{
        first_seq: older_before || 1,
        last_seq:
          min(
            (opts[:before_seq] || conversation.sequence_high_water + 1) - 1,
            conversation.sequence_high_water
          )
      },
      pending_inputs: pending_inputs,
      queued_messages: queued_messages,
      mention_names: mention_names,
      activities:
        Enum.map(agents, fn agent ->
          elem(
            Ankole.Sessions.Activity.current(%{
              agent_uid: agent.uid,
              session_id: Ankole.Sessions.Key.conversation(conversation.id)
            }),
            0
          )
        end),
      artifacts: artifacts,
      saved_pages: saved,
      latest_input: latest_input,
      latest_input_agent_uids:
        if(latest_input, do: NativeQueue.addressed_agent_uids(latest_input), else: []),
      removed_message_ids: removed_ids,
      retryable_message_id: latest_retryable && latest_retryable.id,
      retryable_message_ids: retryable,
      queue_versions:
        Map.new(agents, fn agent ->
          inputs = Enum.filter(pending_inputs, &(&1.agent_uid == agent.uid))
          {agent.uid, NativeQueue.queue_version(conversation, inputs, agent.uid)}
        end),
      session_id: Ankole.Sessions.Key.conversation(conversation.id),
      model_conversation_id: model && model.id
    }

    [detail] = read_states([detail], history: true)

    Map.put(
      detail,
      :status,
      if(agent, do: detail.statuses[agent.uid], else: %{state: :idle, retry_at: nil})
    )
  end

  defp history_window(conversation, opts) do
    query =
      Message
      |> Ash.Query.for_read(:history_page)
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and seq <= ^conversation.sequence_high_water and
          not withdrawn
      )
      |> Ash.Query.sort(seq: :desc)

    query =
      case opts[:before_seq] do
        nil -> query
        sequence -> Ash.Query.filter(query, seq < ^sequence)
      end

    page = Ankole.Ash.read!(query, page: [limit: 500])
    messages = Enum.reverse(page.results)
    {messages, if(page.more?, do: hd(messages).seq)}
  end

  defp removed_messages(conversation, older_before, opts) do
    first = min(opts[:loaded_first_seq] || older_before || 1, older_before || 1)

    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation.id and seq >= ^first and
        seq <= ^conversation.sequence_high_water and withdrawn
    )
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
    |> Enum.concat(opts[:removed_message_ids] || [])
    |> Enum.uniq()
  end

  # This is an advisory capability. The mutation repeats the same runtime
  # predicate under its session lock before it changes history.
  defp retryable_message_id(conversation, agent) do
    message =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and author_type == :agent and author_uid == ^agent.uid and
          delivery_key == "final" and not withdrawn
      )
      |> Ash.Query.sort(seq: :desc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    case message do
      %Message{author_type: :agent, signal_id: signal_id} when not is_nil(signal_id) ->
        key = %{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(conversation.id)
        }

        with {:ok, %Signal{} = input} <-
               Ankole.Sessions.Commands.retry_source_in_tx(key, nil, signal_id, lock: false),
             true <- NativeQueue.retryable_reply?(message, input) do
          message.id
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp validate_text(text) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>) and String.trim(text) != "",
      do: {:ok, text},
      else: {:error, :invalid_text}
  end

  defp validate_text(_), do: {:error, :invalid_text}

  @doc false
  def native_text(nil, [_attachment | _rest]), do: {:ok, nil}

  def native_text(text, [_attachment | _rest]) when is_binary(text) do
    if String.valid?(text) and String.trim(text) == "",
      do: {:ok, nil},
      else: validate_text(text)
  end

  def native_text(text, _attachments), do: validate_text(text)

  @doc false
  def page_links(text) when is_binary(text) do
    Regex.scan(~r/ankole:page\/([0-9a-f-]{36})(?![0-9a-f-])/, text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> [%{"kind" => "page", "id" => id}]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def page_links(_text), do: []
end
