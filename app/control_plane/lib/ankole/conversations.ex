defmodule Ankole.Conversations do
  @moduledoc "Owns conversations, participation, and committed messages."
  import Ecto.Query

  alias Ankole.Conversations.Target, as: StatementTarget
  alias Ankole.AIGateway
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Message
  alias Ankole.Conversations.Participant
  alias Ankole.Principals.Principal
  alias Ankole.Principals.WorkAccess
  alias Ankole.{Repo, Signals}

  @doc "Commits the effects of an actual external Message change with its observation."
  def message_changed_in_tx(repo, before_message, after_message, now) do
    if before_message != nil and after_message == nil do
      :ok = Ankole.Sessions.AmbientCuration.message_removed_in_tx(repo, before_message)
    end

    fields = [
      :text,
      :author_type,
      :author_uid,
      :attachments,
      :links,
      :mentions,
      :rich_content,
      :reply_to_message_id
    ]

    changed? =
      before_message != nil and
        (after_message == nil or
           Map.take(before_message, fields) != Map.take(after_message, fields))

    if changed? do
      Ankole.Brain.Sources.invalidate_conversation_message_in_tx(repo, before_message, now)
    else
      :ok
    end
  end

  @doc "Returns a Signal's committed statement when both IDs name the same Conversation."
  def message_for_signal(%{message_id: id, conversation_id: conversation_id})
      when is_binary(id) and is_binary(conversation_id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id) do
      Repo.get_by(Message, id: id, conversation_id: conversation_id)
    else
      _ -> nil
    end
  end

  def message_for_signal(_event), do: nil

  @doc "Returns the latest reply candidate text for each requested Signal."
  @spec reply_candidate_texts([String.t()]) :: %{String.t() => String.t() | nil}
  def reply_candidate_texts([]), do: %{}

  def reply_candidate_texts(signal_ids) when is_list(signal_ids) do
    messages =
      Repo.all(
        from message in Message,
          where: message.signal_id in ^signal_ids,
          distinct: message.signal_id,
          order_by: [asc: message.signal_id, desc: message.created_at],
          select: {message.signal_id, message.text}
      )
      |> Map.new()

    fallback_ids = Enum.filter(signal_ids, &is_nil(Map.get(messages, &1)))

    fallback =
      if fallback_ids == [] do
        %{}
      else
        Repo.all(
          from intent in Ankole.Conversations.Delivery.Intent,
            where: intent.source_signal_id in ^fallback_ids,
            where: not is_nil(intent.fallback_visible_text),
            distinct: intent.source_signal_id,
            order_by: [asc: intent.source_signal_id, desc: intent.inserted_at],
            select: {intent.source_signal_id, intent.fallback_visible_text}
        )
        |> Map.new()
      end

    Map.new(signal_ids, &{&1, Map.get(messages, &1) || Map.get(fallback, &1)})
  end

  def agents do
    Repo.all(
      from p in Principal,
        where: p.type == :agent and p.status == :active,
        order_by: [asc: p.display_name, asc: p.uid]
    )
  end

  def list(human_uid) do
    Repo.all(
      from c in visible_conversations(human_uid),
        join: member in Participant,
        on: member.conversation_id == c.id and member.role == :agent,
        join: agent in Principal,
        on: agent.uid == member.principal_uid,
        order_by: [desc: c.last_activity_at, desc: c.id],
        limit: 100,
        select: %{conversation: c, agent: agent}
    )
  end

  def get(human_uid, id) do
    with {:ok, id} <- cast_id(id),
         %Conversation{} = conversation <- Repo.one(visible_conversation(human_uid, id)),
         %Principal{} = agent <- conversation_agent(Repo, id) do
      {:ok, detail(conversation, agent)}
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  def create(human_uid, attrs) do
    Repo.assert_outside_transaction!()
    Repo.transact(&create_in_tx(&1, human_uid, attrs)) |> committed(human_uid)
  end

  @doc "Creates a native conversation and returns publication facts to its transaction owner."
  def create_in_tx(repo, human_uid, attrs) when is_map(attrs) do
    with :ok <- Repo.require_transaction(repo),
         {:ok, id} <- cast_id(value(attrs, :conversation_id)),
         {:ok, message_id} <- cast_id(value(attrs, :message_id)),
         {:ok, text} <- validate_text(value(attrs, :text)),
         agent_uid when is_binary(agent_uid) and agent_uid != "" <- value(attrs, :agent_uid) do
      session_id = Ankole.Sessions.Key.conversation(id)
      :ok = Signals.lock_target_in_tx(repo, %{agent_uid: agent_uid, session_id: session_id})

      with :ok <- check_human_in_tx(repo, human_uid),
           {:ok, agent} <- active_agent_in_tx(repo, agent_uid),
           {:ok, conversation} <- ensure_conversation_in_tx(repo, human_uid, agent, id, text),
           {:ok, message, inserted?} <-
             append_human_message_in_tx(repo, conversation, human_uid, message_id, text),
           true <- message.seq == 1,
           {:ok, event} <- accept_message_in_tx(repo, conversation, agent, message) do
        {:ok,
         %{
           id: id,
           event: event,
           inserted?: inserted?,
           publications: publications(event, inserted?)
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

  def create_in_tx(_repo, _human_uid, _attrs), do: {:error, :invalid_request}

  def post(human_uid, id, attrs) do
    Repo.assert_outside_transaction!()
    Repo.transact(&post_in_tx(&1, human_uid, id, attrs)) |> committed(human_uid)
  end

  @doc "Appends human input and returns publication facts to its transaction owner."
  def post_in_tx(repo, human_uid, id, attrs) when is_map(attrs) do
    with :ok <- Repo.require_transaction(repo),
         {:ok, id} <- cast_id(id),
         {:ok, message_id} <- cast_id(value(attrs, :message_id)),
         {:ok, text} <- validate_text(value(attrs, :text)),
         {:ok, %{agent: agent}} <- get(human_uid, id) do
      :ok =
        Signals.lock_target_in_tx(repo, %{
          agent_uid: agent.uid,
          session_id: Ankole.Sessions.Key.conversation(id)
        })

      with :ok <- check_human_in_tx(repo, human_uid),
           {:ok, agent} <- active_agent_in_tx(repo, agent.uid),
           %Conversation{} = conversation <-
             repo.one(from c in visible_conversation(human_uid, id), lock: "FOR UPDATE"),
           {:ok, message, inserted?} <-
             append_human_message_in_tx(repo, conversation, human_uid, message_id, text),
           {:ok, event} <- accept_message_in_tx(repo, conversation, agent, message) do
        {:ok,
         %{
           id: id,
           event: event,
           inserted?: inserted?,
           publications: publications(event, inserted?)
         }}
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_not_found}
      end
    end
  end

  def post_in_tx(_repo, _human_uid, _id, _attrs), do: {:error, :invalid_request}

  @doc "Commits a statement to its native host or external Delivery destination."
  def post_in_tx(
        repo,
        %StatementTarget{kind: :external} = target,
        %Ankole.Conversations.Statement{} = statement
      ),
      do: Ankole.Conversations.Delivery.Posting.post_in_tx(repo, target, statement)

  def post_in_tx(
        repo,
        %StatementTarget{kind: :native} = target,
        %Ankole.Conversations.Statement{} = statement
      ) do
    text = Ankole.Conversations.Statement.text(statement)
    kind = if statement.notice, do: :notice, else: :message

    if text in [nil, ""] do
      {:ok, %Ankole.Conversations.PostResult{}}
    else
      with {:ok, message} <-
             post_native_in_tx(repo, target.conversation_id, statement.signal, text, kind),
           do: {:ok, %Ankole.Conversations.PostResult{messages: [message]}}
    end
  end

  defp post_native_in_tx(repo, id, event, text, kind) do
    with {:ok, id} <- cast_id(id),
         {:ok, text} <- validate_text(text),
         %Conversation{kind: :native} = conversation <-
           repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE"),
         %Principal{uid: uid} <- conversation_agent(repo, id),
         true <- uid == event.agent_uid do
      case repo.get_by(Message, conversation_id: id, signal_id: event.id) do
        %Message{text: ^text, kind: ^kind} = message ->
          {:ok, message}

        %Message{} ->
          {:error, :conversation_conflict}

        nil ->
          with {:ok, seq} <- next_sequence_in_tx(repo, conversation) do
            attrs = %{
              id: Ankole.Ecto.UUIDv7.autogenerate(),
              conversation_id: id,
              seq: seq,
              author_type: :agent,
              author_uid: uid,
              kind: kind,
              text: text,
              origin: :native,
              session_id: event.session_id,
              signal_id: event.id,
              reply_to_message_id:
                if(is_map(event.data) and event.data["conversation_id"] == id,
                  do: event.message_id
                ),
              created_at: DateTime.utc_now(:microsecond)
            }

            with {:ok, message} <- %Message{} |> Message.changeset(attrs) |> repo.insert(),
                 {:ok, _} <- touch_in_tx(repo, conversation, message.created_at) do
              {:ok, message}
            end
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_not_found}
    end
  end

  @doc "Returns the native host IDs for model-history lifecycle queries."
  def native_ids_query, do: from(c in Conversation, where: c.kind == :native, select: c.id)

  @doc "Reads a bounded snapshot of statements not yet included by the caller."
  def context_snapshot(
        id,
        %{agent_uid: agent_uid, session_id: session_id},
        read_seq,
        excluded_ids,
        opts \\ []
      ) do
    limit = min(max(Keyword.get(opts, :limit, 50), 1), 500)

    Repo.transact(fn repo ->
      with {:ok, id} <- cast_id(id),
           %Conversation{} = conversation <-
             repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR SHARE") do
        max_seq = conversation.sequence_high_water

        messages =
          repo.all(
            from m in Message,
              where:
                m.conversation_id == ^id and m.seq > ^read_seq and
                  m.seq <= ^max_seq,
              where:
                is_nil(m.session_id) or m.session_id != ^session_id or is_nil(m.author_uid) or
                  m.author_uid != ^agent_uid,
              where: m.id not in ^excluded_ids,
              order_by: [desc: m.seq],
              limit: ^limit
          )
          |> Enum.reverse()

        {:ok, %{messages: messages, max_seq: max_seq}}
      else
        {:error, _} = error -> error
        _ -> {:error, :conversation_not_found}
      end
    end)
  end

  @doc false
  def ids_for_agent_in_tx(repo, uid) do
    repo.all(
      from c in Conversation,
        join: p in Participant,
        on: p.conversation_id == c.id,
        where: c.kind == :native and p.principal_uid == ^uid and p.role == :agent,
        select: c.id
    )
  end

  @doc false
  def delete_for_agent_in_tx(repo, uid) do
    ids =
      from p in Participant,
        where: p.principal_uid == ^uid and p.role == :agent,
        select: p.conversation_id

    repo.delete_all(from c in Conversation, where: c.kind == :native and c.id in subquery(ids))
    :ok
  end

  def subscribe(id), do: Phoenix.PubSub.subscribe(Ankole.PubSub, topic(id))
  def unsubscribe(id), do: Phoenix.PubSub.unsubscribe(Ankole.PubSub, topic(id))
  def publish_message(event), do: publish(event, :message)
  def publish_status(event), do: publish(event, :status)
  def publish_activity(event, snapshot), do: publish(event, {:activity, self(), snapshot})

  def publish_statement(%Message{conversation_id: id}) do
    Repo.assert_outside_transaction!()
    Phoenix.PubSub.broadcast(Ankole.PubSub, topic(id), {:conversation_event, id, :message})
  end

  def publish_committed(publications) when is_list(publications) do
    Repo.assert_outside_transaction!()
    Enum.each(publications, fn {event, type} -> publish(event, type) end)
    :ok
  end

  defp publications(event, true), do: [{event, :message}, {event, :status}]
  defp publications(_event, false), do: []

  defp committed({:ok, %{id: id, publications: publications}}, human_uid) do
    publish_committed(publications)
    get(human_uid, id)
  end

  defp committed({:error, _} = error, _human_uid), do: error

  defp ensure_conversation_in_tx(repo, human_uid, agent, id, text) do
    attrs = %{
      id: id,
      kind: :native,
      title: text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 80),
      created_by: human_uid,
      last_activity_at: DateTime.utc_now(:microsecond)
    }

    with {:ok, _} <-
           %Conversation{}
           |> Conversation.changeset(attrs)
           |> repo.insert(on_conflict: :nothing, conflict_target: [:tenant_id, :id]),
         %Conversation{created_by: ^human_uid} = conversation <-
           repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE"),
         :ok <- check_existing_agent(repo, id, agent.uid),
         {:ok, _} <- insert_participant(repo, id, human_uid, :owner),
         {:ok, _} <- insert_participant(repo, id, agent.uid, :agent),
         %Principal{uid: uid} <- conversation_agent(repo, id),
         true <- uid == agent.uid,
         {:ok, _} <-
           AIGateway.ensure_conversation_in_tx(
             repo,
             agent.uid,
             Ankole.Sessions.Key.conversation(id)
           ) do
      {:ok, conversation}
    else
      {:error, _} = error -> error
      _ -> {:error, :conversation_conflict}
    end
  end

  defp insert_participant(repo, id, uid, role) do
    %Participant{}
    |> Participant.changeset(%{conversation_id: id, principal_uid: uid, role: role})
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :conversation_id, :principal_uid]
    )
  end

  defp check_existing_agent(repo, id, uid) do
    case conversation_agent(repo, id) do
      nil -> :ok
      %Principal{uid: ^uid} -> :ok
      _ -> {:error, :conversation_conflict}
    end
  end

  defp append_human_message_in_tx(repo, conversation, human_uid, id, text) do
    case repo.get_by(Message, id: id) do
      %Message{
        conversation_id: conversation_id,
        author_uid: ^human_uid,
        text: ^text,
        author_type: :human,
        kind: :message
      } = message
      when conversation_id == conversation.id ->
        {:ok, message, false}

      %Message{} ->
        {:error, :conversation_conflict}

      nil ->
        with {:ok, seq} <- next_sequence_in_tx(repo, conversation) do
          attrs = %{
            id: id,
            conversation_id: conversation.id,
            seq: seq,
            author_type: :human,
            author_uid: human_uid,
            kind: :message,
            text: text,
            origin: :native,
            created_at: DateTime.utc_now(:microsecond)
          }

          with {:ok, _} <-
                 %Message{}
                 |> Message.changeset(attrs)
                 |> repo.insert(on_conflict: :nothing, conflict_target: [:tenant_id, :id]),
               %Message{
                 conversation_id: conversation_id,
                 author_uid: ^human_uid,
                 text: ^text,
                 author_type: :human,
                 kind: :message
               } = message <- repo.get_by(Message, id: id),
               true <- conversation_id == conversation.id,
               {:ok, _} <- touch_in_tx(repo, conversation, message.created_at) do
            {:ok, message, true}
          else
            {:error, _} = error -> error
            _ -> {:error, :conversation_conflict}
          end
        end
    end
  end

  defp accept_message_in_tx(repo, conversation, agent, message) do
    Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: Ankole.Sessions.Key.conversation(conversation.id),
      id: message.id,
      type: "conversation.message.addressed",
      subject: conversation.id,
      target: %{agent_uid: agent.uid, conversation_id: conversation.id},
      sender: message.author_uid,
      message_id: message.id,
      time: message.created_at,
      data: %{
        "conversation_id" => conversation.id,
        "message_id" => message.id,
        "message_ids" => [message.id],
        "author_uid" => message.author_uid,
        "text" => message.text
      }
    })
  end

  @doc "Allocates one committed statement sequence in the caller's transaction."
  def next_sequence_in_tx(repo, %Conversation{id: id}) do
    case repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE") do
      %Conversation{} = conversation ->
        seq = conversation.sequence_high_water + 1

        with {:ok, _} <-
               conversation |> Ecto.Changeset.change(sequence_high_water: seq) |> repo.update(),
             do: {:ok, seq}

      nil ->
        {:error, :conversation_not_found}
    end
  end

  defp touch_in_tx(repo, conversation, now) do
    conversation |> Ecto.Changeset.change(last_activity_at: now) |> repo.update()
  end

  defp check_human_in_tx(repo, human_uid) do
    case repo.get_by(Principal, uid: human_uid, type: :human, status: :active) do
      %Principal{} -> WorkAccess.check_in_tx(repo, WorkAccess.from_sender(repo, human_uid))
      _ -> {:error, :invalid_request}
    end
  end

  defp active_agent_in_tx(repo, agent_uid) do
    case repo.one(from p in Principal, where: p.uid == ^agent_uid, lock: "FOR UPDATE") do
      %Principal{type: :agent, status: :active} = agent -> {:ok, agent}
      _ -> {:error, :agent_unavailable}
    end
  end

  defp visible_conversations(human_uid) do
    from c in Conversation,
      join: member in Participant,
      on: member.conversation_id == c.id and member.principal_uid == ^human_uid,
      join: human in Principal,
      on: human.uid == member.principal_uid,
      where: c.kind == :native and human.type == :human and human.status == :active
  end

  defp visible_conversation(human_uid, id),
    do: from(c in visible_conversations(human_uid), where: c.id == ^id)

  defp conversation_agent(repo, id) do
    repo.one(
      from p in Participant,
        join: agent in Principal,
        on: agent.uid == p.principal_uid,
        where: p.conversation_id == ^id and p.role == :agent,
        select: agent
    )
  end

  defp detail(conversation, agent) do
    messages =
      Repo.all(
        from m in Message,
          where: m.conversation_id == ^conversation.id,
          order_by: [desc: m.seq],
          limit: 500
      )
      |> Enum.reverse()

    model =
      AIGateway.list_active_conversations(Repo,
        subject_uid: agent.uid,
        conversation_key: Ankole.Sessions.Key.conversation(conversation.id),
        limit: 1
      )
      |> List.first()

    %{
      conversation: conversation,
      agent: agent,
      messages: messages,
      session_id: Ankole.Sessions.Key.conversation(conversation.id),
      model_conversation_id: model && model.id
    }
  end

  defp publish(event, type) do
    Repo.assert_outside_transaction!()

    case native_conversation_id(event.session_id) do
      {:ok, id} ->
        Phoenix.PubSub.broadcast(Ankole.PubSub, topic(id), {:conversation_event, id, type})

      :error ->
        :ok
    end

    :ok
  end

  defp topic(id), do: "conversation:#{Repo.tenant_id!()}:#{id}"

  defp native_conversation_id(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:conversation, id} -> {:ok, id}
      _ -> :error
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_id}
    end
  end

  defp validate_text(text) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>) and String.trim(text) != "",
      do: {:ok, text},
      else: {:error, :invalid_text}
  end

  defp validate_text(_), do: {:error, :invalid_text}
  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
