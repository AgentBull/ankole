defmodule Ankole.Conversations.Native do
  @moduledoc false

  require Ash.Query

  alias Ankole.{AIGateway, Repo, Signals}

  alias Ankole.Conversations.{
    Conversation,
    Message,
    ModelPreferences,
    NativeQueue,
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
  Gives a native conversation that the active Human takes part in.

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

  def model_preferences(%Ankole.AuthZ.Actor{} = actor, id) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} = conversation <- visible_conversation(actor, id),
         %{} = agent <- conversation_agent(id),
         :ok <- authorize_page(actor, conversation.page_id) do
      ModelPreferences.selection(conversation, agent.uid)
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def set_model_profile(%Ankole.AuthZ.Actor{} = actor, id, profile) do
    Repo.transact_top_level(fn ->
      set_model_profile_in_tx(actor, id, profile)
    end)
  end

  @doc false
  def set_model_profile_in_tx(%Ankole.AuthZ.Actor{} = actor, id, profile) do
    with {:ok, id} <- Queries.cast_id(id),
         %Conversation{} <- visible_conversation(actor, id),
         %{} = selected_agent <- conversation_agent(id) do
      with :ok <- lock_participants_in_tx(actor, selected_agent.uid),
           :ok <-
             Signals.lock_target_in_tx(%{
               agent_uid: selected_agent.uid,
               session_id: Ankole.Sessions.Key.conversation(id)
             }),
           :ok <- check_human_in_tx(actor),
           {:ok, agent} <- active_agent_in_tx(selected_agent.uid),
           %Conversation{} = conversation <- visible_conversation(actor, id, lock: true),
           :ok <- authorize_page(actor, conversation.page_id),
           {:ok, profile} <- ModelPreferences.validate(agent.uid, profile),
           {:ok, conversation} <- ModelPreferences.put(conversation, profile) do
        ModelPreferences.selection(conversation, agent.uid)
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_not_found}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def list(%Ankole.AuthZ.Actor{} = actor) do
    list_native(actor, nil)
  end

  @doc "Lists the current Human's conversations attached to an accessible Page."
  def list_for_page(%Ankole.AuthZ.Actor{} = actor, page_id) do
    with {:ok, page_id} <- Queries.cast_id(page_id),
         :ok <- authorize_page(actor, page_id) do
      {:ok, list_native(actor, page_id)}
    end
  end

  defp list_native(%Ankole.AuthZ.Actor{} = actor, page_id) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    if active_human?(actor) do
      query =
        Ash.Query.filter(
          Conversation,
          kind == :native and
            exists(Participant, conversation_id == parent(id) and principal_uid == ^human_uid) and
            exists(Participant, conversation_id == parent(id) and role == :agent)
        )

      query = if page_id, do: Ash.Query.filter(query, page_id == ^page_id), else: query

      conversations =
        query
        |> Ash.Query.sort(last_activity_at: :desc, id: :desc)
        |> Ash.Query.limit(100)
        |> Ankole.Ash.read!()

      agents = conversation_agents(Enum.map(conversations, & &1.id))

      for conversation <- conversations,
          agent = Map.get(agents, conversation.id),
          do: %{conversation: conversation, agent: agent}
    else
      []
    end
  end

  def get(%Ankole.AuthZ.Actor{} = actor, id, opts \\ []) do
    Repo.transact_top_level(fn ->
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
      with %{} = agent <- conversation_agent(id),
           :ok <-
             Signals.lock_target_in_tx(%{
               agent_uid: agent.uid,
               session_id: Ankole.Sessions.Key.conversation(id)
             }),
           %Conversation{} = conversation <- visible_conversation(actor, id) do
        {:ok, detail(conversation, agent, opts)}
      else
        _ -> {:error, :conversation_not_found}
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

    with :ok <- Repo.require_transaction(),
         {:ok, id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :conversation_id)),
         {:ok, message_id} <- Queries.cast_id(Ankole.Attrs.get(attrs, :message_id)),
         {:ok, mode} <- delivery_mode(Ankole.Attrs.get(attrs, :delivery_mode)),
         {:ok, page_id} <- optional_page_id(Ankole.Attrs.get(attrs, :page_id)),
         agent_uid when is_binary(agent_uid) and agent_uid != "" <-
           Ankole.Attrs.get(attrs, :agent_uid) do
      session_id = Ankole.Sessions.Key.conversation(id)

      with :ok <- lock_participants_in_tx(actor, agent_uid),
           :ok <- check_human_in_tx(actor),
           {:ok, agent} <- active_agent_in_tx(agent_uid),
           :ok <- authorize_agent(actor, agent.uid),
           :ok <- Signals.lock_target_in_tx(%{agent_uid: agent_uid, session_id: session_id}),
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
           {:ok, conversation} <-
             ModelPreferences.initialize(
               conversation,
               agent.uid,
               Ankole.Attrs.get(attrs, :model_profile)
             ),
           {:ok, message, inserted?} <-
             append_human_message_in_tx(
               conversation,
               human_uid,
               message_id,
               text,
               attachments
             ),
           true <- message.seq == 1,
           :ok <- ModelPreferences.authorize_input(conversation, agent.uid, mode, inserted?),
           {:ok, event} <- accept_message_in_tx(conversation, agent, message, mode, actor) do
        {:ok,
         %{
           id: id,
           event: event,
           session_key: %{agent_uid: agent.uid, session_id: session_id},
           inserted?: inserted?,
           publications: publications(id, inserted?)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_conflict}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def create_in_tx(_human_uid, _attrs), do: {:error, :invalid_request}

  def post(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    Repo.transact_top_level(
      fn -> post_in_tx(actor, id, attrs) end,
      after_commit: &publish_native_change/1
    )
    |> committed(actor)
  end

  @doc "Deletes an idle native conversation owned by the current Human. Pages remain independent."
  def delete(%Ankole.AuthZ.Actor{} = actor, id) do
    Repo.transact_top_level(
      fn -> delete_in_tx(actor, id) end,
      after_commit: &Ankole.Conversations.Events.publish_status/1
    )
  end

  @doc false
  def delete_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, id} <- Queries.cast_id(id),
         {:ok, %{agent: agent}} <- detail_in_tx(actor, id, []),
         :ok <-
           Signals.lock_target_in_tx(%{
             agent_uid: agent.uid,
             session_id: Ankole.Sessions.Key.conversation(id)
           }),
         %Conversation{kind: :native, created_by: ^human_uid} = conversation <-
           Queries.lock_conversation(id),
         false <- busy?(id),
         {:ok, _} <-
           AIGateway.end_active_conversation_in_tx(
             agent.uid,
             Ankole.Sessions.Key.conversation(id),
             DateTime.utc_now(:microsecond)
           ),
         {:ok, _} <- Ankole.Ash.destroy(conversation, :remove) do
      {:ok, id}
    else
      true -> {:error, :conversation_busy}
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
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
         %Conversation{} <- visible_conversation(actor, id),
         %{} = agent <- conversation_agent(id) do
      with :ok <- lock_participants_in_tx(actor, agent.uid),
           :ok <- check_human_in_tx(actor),
           :ok <-
             Signals.lock_target_in_tx(%{
               agent_uid: agent.uid,
               session_id: Ankole.Sessions.Key.conversation(id)
             }),
           {:ok, text, attachments} <- human_content(actor, id, message_id, attrs),
           {:ok, agent} <- active_agent_in_tx(agent.uid),
           :ok <- authorize_agent(actor, agent.uid),
           %Conversation{} = conversation <- visible_conversation(actor, id, lock: true),
           :ok <- authorize_page(actor, conversation.page_id),
           {:ok, message, inserted?} <-
             append_human_message_in_tx(
               conversation,
               human_uid,
               message_id,
               text,
               attachments
             ),
           :ok <- ModelPreferences.authorize_input(conversation, agent.uid, mode, inserted?),
           {:ok, event} <- accept_message_in_tx(conversation, agent, message, mode, actor) do
        {:ok,
         %{
           id: id,
           event: event,
           session_key: %{agent_uid: event.agent_uid, session_id: event.session_id},
           inserted?: inserted?,
           publications: publications(id, inserted?)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_not_found}
      end
    else
      nil -> {:error, :conversation_not_found}
      error -> error
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
                 attachments
               ),
             do: {:ok, %Ankole.Conversations.PostResult{messages: [message]}}
      end
    end
  end

  defp post_native_in_tx(id, event, text, kind, attachments) do
    with {:ok, id} <- Queries.cast_id(id),
         {:ok, text} <- native_text(text, attachments),
         %Conversation{kind: :native} = conversation <- Queries.lock_conversation(id),
         %{uid: uid} <- conversation_agent(id),
         true <- uid == event.agent_uid do
      case Message
           |> Ash.Query.filter(conversation_id == ^id and signal_id == ^event.id)
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
      key = result.session_key
      Ankole.Sessions.Events.publish_status(key.agent_uid, key.session_id)
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
      title: text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80),
      created_by: human_uid,
      page_id: page_id,
      last_activity_at: DateTime.utc_now(:microsecond)
    }

    with :ok <- available_native_id(agent.uid, id),
         {:ok, _} <-
           Ankole.Ash.create(Conversation, :ensure_native, attrs, touch_update_defaults?: false),
         %Conversation{created_by: ^human_uid, page_id: ^page_id} = conversation <-
           Queries.lock_conversation(id),
         :ok <- check_existing_agent(id, agent.uid),
         {:ok, _} <- insert_participant(id, human_uid, :owner),
         {:ok, _} <- insert_participant(id, agent.uid, :agent),
         %{uid: uid} <- conversation_agent(id),
         true <- uid == agent.uid,
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

  defp insert_participant(id, uid, role) do
    Ankole.Ash.create(Participant, :join, %{conversation_id: id, principal_uid: uid, role: role})
  end

  defp optional_page_id(nil), do: {:ok, nil}
  defp optional_page_id(id), do: Queries.cast_id(id)

  @doc false
  def authorize_page(_uid, nil), do: :ok

  def authorize_page(%Ankole.AuthZ.Actor{} = actor, id) do
    case Ankole.Pod.Pages.authorize(actor, id, "page_view") do
      {:ok, _} -> :ok
      _ -> {:error, :page_unavailable}
    end
  end

  defp check_existing_agent(id, uid) do
    case conversation_agent(id) do
      nil -> :ok
      %{uid: ^uid} -> :ok
      _ -> {:error, :conversation_conflict}
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

  defp conversation_title(text, attachments),
    do: text || hd(attachments)["name"]

  defp append_human_message_in_tx(conversation, human_uid, id, text, attachments) do
    existing = message(id)

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
        {:ok, message, false}

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
            links: page_links(text),
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

  defp accept_message_in_tx(conversation, agent, message, mode, actor) do
    data = %{
      "conversation_id" => conversation.id,
      "message_id" => message.id,
      "message_ids" => [message.id],
      "author_uid" => message.author_uid,
      "text" => message.text,
      "request_context" => Ankole.AuthZ.Actor.request_context(actor),
      "model_profile" => ModelPreferences.logical(conversation)
    }

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
  def lock_participants_in_tx(%Ankole.AuthZ.Actor{} = actor, agent_uid) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)
    {:ok, _principals} = Ankole.Principals.lock_principals_in_tx([human_uid, agent_uid])
    :ok
  end

  @doc false
  def check_human_in_tx(%Ankole.AuthZ.Actor{} = actor) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    if active_human?(actor),
      do: WorkAccess.check_in_tx(WorkAccess.from_sender(human_uid)),
      else: {:error, :invalid_request}
  end

  defp authorize_agent(%Ankole.AuthZ.Actor{} = actor, agent_uid) do
    context = Map.put(Ankole.AuthZ.Actor.request_context(actor), "surface", "conversation")
    Ankole.AuthZ.authorize(actor, "agent:#{agent_uid}", "chat", context)
  end

  defp active_agent_in_tx(agent_uid) do
    case Ankole.Principals.lock_principals_in_tx([agent_uid]) do
      {:ok, [%{type: :agent, status: :active} = agent]} -> {:ok, agent}
      _ -> {:error, :agent_unavailable}
    end
  end

  defp active_human?(%Ankole.AuthZ.Actor{} = actor),
    do: match?({:ok, %{type: :human}}, Ankole.Pod.principal(actor))

  @doc false
  def visible_conversation(%Ankole.AuthZ.Actor{} = actor, id, opts \\ []) do
    human_uid = Ankole.AuthZ.Actor.uid(actor)

    if active_human?(actor) do
      query =
        Ash.Query.filter(
          Conversation,
          id == ^id and kind == :native and
            exists(Participant, conversation_id == parent(id) and principal_uid == ^human_uid)
        )

      query = if opts[:lock], do: Ash.Query.lock(query, :for_update), else: query
      Ankole.Ash.read_one!(query)
    end
  end

  @doc false
  def conversation_agent(id), do: [id] |> conversation_agents() |> Map.get(id)

  defp conversation_agents([]), do: %{}

  defp conversation_agents(ids) do
    participants =
      Participant
      |> Ash.Query.filter(conversation_id in ^ids and role == :agent)
      |> Ankole.Ash.read!()

    agents =
      Ankole.Principals.list_principals!(
        query: [filter: [uid: [in: Enum.map(participants, & &1.principal_uid)]]]
      )
      |> Map.new(&{&1.uid, &1})

    for participant <- participants,
        agent = Map.get(agents, participant.principal_uid),
        into: %{},
        do: {participant.conversation_id, agent}
  end

  defp detail(conversation, agent, opts) do
    query =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and seq <= ^conversation.sequence_high_water and
          not withdrawn
      )
      |> Ash.Query.sort(seq: :desc)
      |> Ash.Query.limit(501)

    query =
      case Keyword.get(opts, :before_seq) do
        nil -> query
        sequence -> Ash.Query.filter(query, seq < ^sequence)
      end

    rows = Ankole.Ash.read!(query)
    messages = rows |> Enum.take(500) |> Enum.reverse()
    older_before = if length(rows) > 500, do: hd(messages).seq, else: nil
    loaded_first = min(opts[:loaded_first_seq] || older_before || 1, older_before || 1)

    removed_ids =
      Message
      |> Ash.Query.filter(
        conversation_id == ^conversation.id and seq >= ^loaded_first and
          seq <= ^conversation.sequence_high_water and withdrawn
      )
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.id)
      |> Enum.concat(opts[:removed_message_ids] || [])
      |> Enum.uniq()

    model =
      AIGateway.list_active_conversations(
        subject_uid: agent.uid,
        conversation_key: Ankole.Sessions.Key.conversation(conversation.id),
        limit: 1
      )
      |> List.first()

    pending_inputs =
      Signals.list_signals!(
        query: [filter: pending_filter(conversation.id), sort: [queue_sequence: :asc]]
      )

    %{
      conversation: conversation,
      agent: agent,
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
      removed_message_ids: removed_ids,
      retryable_message_id: retryable_message_id(conversation, agent, messages, opts),
      queue_version: NativeQueue.queue_version(conversation, pending_inputs),
      session_id: Ankole.Sessions.Key.conversation(conversation.id),
      model_conversation_id: model && model.id,
      status:
        Ankole.Sessions.status(%{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(conversation.id)
        })
    }
  end

  # This is an advisory capability. The mutation repeats the same runtime
  # predicate under its session lock before it changes history.
  defp retryable_message_id(conversation, agent, messages, opts) do
    message =
      if opts[:before_seq] do
        Message
        |> Ash.Query.filter(conversation_id == ^conversation.id and not withdrawn)
        |> Ash.Query.sort(seq: :desc)
        |> Ash.Query.limit(1)
        |> Ankole.Ash.read_one!()
      else
        List.last(messages)
      end

    case message do
      %Message{author_type: :agent, signal_id: signal_id} when not is_nil(signal_id) ->
        key = %{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(conversation.id)
        }

        with {:ok, %Signal{} = input} <-
               Ankole.Sessions.Commands.retry_source_in_tx(key, nil, signal_id),
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
