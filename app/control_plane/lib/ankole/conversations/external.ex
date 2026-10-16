defmodule Ankole.Conversations.External do
  @moduledoc """
  Persists observations from an external host. Callers own the transaction that
  also admits a Signal or commits a Delivery. Platform IDs remain opaque at this
  boundary; readers receive a Message and its adapter-owned reference.
  """
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ankole.Conversations.{Conversation, ExternalMessageRef, Message, Participant}
  alias Ankole.Conversations.Attachments
  alias Ankole.Principals.Principal

  @message_fields [
    :text,
    :attachments,
    :links,
    :mentions,
    :rich_content,
    :kind,
    :session_id,
    :signal_id
  ]
  @ref_fields [
    :reply_to_provider_message_id,
    :provider_thread_id,
    :author,
    :metadata,
    :raw_payload,
    :provider_time,
    :ai_message_id
  ]
  @conversation_fields [
    :external_kind,
    :reply_mode,
    :visibility,
    :principal_group_id,
    :metadata,
    :raw_payload
  ]

  def observe_entry_in_tx(repo, fact, now) do
    observe_in_tx(
      repo,
      fact.conversation_id,
      %{
        agent_uid: fact.agent_uid,
        provider_message_id: fact.provider_message_id,
        reply_to_provider_message_id: Map.get(fact, :reply_to_provider_message_id),
        provider_thread_id: fact.provider_thread_id,
        text: fact.text,
        rich_content: Attachments.rich_content(fact.text, fact.formatted_content || %{}),
        attachments: fact.attachments || [],
        links: fact.links || [],
        author: fact.author || %{},
        mentions: fact.mentions || [],
        metadata:
          Map.merge(fact.metadata || %{}, %{
            "binding_name" => fact.binding_name,
            "sender_key" => fact.sender_key
          }),
        raw_payload: fact.raw_payload || %{},
        provider_time: fact.provider_time
      },
      now
    )
  end

  def get_conversation(repo, provider_conversation_id),
    do:
      repo.get_by(Conversation,
        kind: :external,
        provider_conversation_id: provider_conversation_id
      )

  def fetch_conversation(id) do
    with {:ok, id} <- Ankole.Ecto.UUIDv7.cast(id),
         %Conversation{kind: :external} = conversation <- Ankole.Repo.get_by(Conversation, id: id) do
      {:ok, conversation}
    else
      _ -> {:error, :external_conversation_not_found}
    end
  end

  def provider_conversation_id!(id) do
    case fetch_conversation(id) do
      {:ok, conversation} -> conversation.provider_conversation_id
      {:error, _} -> raise ArgumentError, "external conversation not found: #{inspect(id)}"
    end
  end

  def existing_direct_conversation(binding, principal_uid) do
    Ankole.Repo.all(
      from(c in Conversation,
        join: event in Ankole.Signals.Signal,
        on: event.tenant_id == c.tenant_id and event.conversation_id == c.id,
        distinct: true,
        where:
          c.kind == :external and c.external_kind == :im_dm and
            event.agent_uid == ^binding.agent_uid and event.reply_binding_name == ^binding.name and
            fragment("?->>'dm_peer_principal_uid'", c.metadata) == ^principal_uid,
        limit: 2
      )
    )
    |> case do
      [conversation] -> {:ok, conversation}
      [] -> {:error, :principal_conversation_not_observed}
      _ -> {:error, :principal_conversation_ambiguous}
    end
  end

  def update_metadata(conversation_id, fun) when is_function(fun, 1) do
    Ankole.Repo.transact(fn repo ->
      case lock_conversation(repo, conversation_id) do
        %Conversation{kind: :external} = conversation ->
          conversation
          |> Conversation.changeset(%{metadata: fun.(conversation.metadata || %{})})
          |> repo.update()

        _ ->
          {:error, :external_conversation_not_found}
      end
    end)
  end

  def observe_conversation_in_tx(repo, %{agent_uid: agent_uid}, observation, now) do
    provider_id = value(observation, :provider_conversation_id)

    if is_binary(provider_id) and String.trim(provider_id) != "" do
      lock_identity(repo, [provider_id])

      existing = get_conversation(repo, provider_id)

      attrs = conversation_attrs(existing, observation, now)

      with {:ok, conversation} <-
             write_conversation(
               repo,
               existing,
               Map.merge(attrs, %{
                 provider_conversation_id: provider_id
               })
             ),
           {:ok, _} <- ensure_agent(repo, conversation.id, agent_uid) do
        {:ok, conversation}
      end
    else
      {:error, :invalid_provider_conversation_id}
    end
  end

  def observe_in_tx(repo, conversation_id, observation, now) do
    provider_id = value(observation, :provider_message_id)

    with :ok <- validate_provider_message_id(provider_id),
         %Conversation{kind: :external} = conversation <- lock_conversation(repo, conversation_id) do
      existing = get_message(repo, conversation_id, provider_id)

      if stale?(existing, value(observation, :provider_time)) do
        {:ok, Map.merge(existing, %{status: :unchanged, conversation: conversation})}
      else
        write_observation(repo, conversation, existing, observation, provider_id, now)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :external_conversation_not_found}
    end
  end

  @doc "Records a confirmed provider send/edit through the same identity as inbound observations."
  def record_delivery_in_tx(repo, conversation_id, observation, now),
    do: observe_in_tx(repo, conversation_id, observation, now)

  def get_message(repo, conversation_id, provider_message_id) do
    repo.one(
      from(message in Message,
        join: ref in ExternalMessageRef,
        on: ref.message_id == message.id and ref.tenant_id == message.tenant_id,
        where:
          ref.conversation_id == ^conversation_id and
            ref.provider_message_id == ^provider_message_id,
        select: %{message: message, external_ref: ref}
      )
    )
  end

  def list_messages(repo, conversation_id, opts \\ []) do
    after_seq = Keyword.get(opts, :after_seq, 0)
    limit = Keyword.get(opts, :limit, 500)

    repo.all(
      from(message in Message,
        left_join: ref in ExternalMessageRef,
        on: ref.message_id == message.id and ref.tenant_id == message.tenant_id,
        where: message.conversation_id == ^conversation_id and message.seq > ^after_seq,
        order_by: [asc: message.seq],
        limit: ^limit,
        select: %{message: message, external_ref: ref}
      )
    )
  end

  def remove_in_tx(repo, conversation_id, provider_message_id) do
    with %Conversation{kind: :external} <- lock_conversation(repo, conversation_id),
         %{message: message} <- get_message(repo, conversation_id, provider_message_id),
         :ok <-
           Ankole.Conversations.message_changed_in_tx(
             repo,
             message,
             nil,
             DateTime.utc_now(:microsecond)
           ),
         {:ok, _} <- repo.delete(message) do
      {:ok, message}
    else
      nil -> {:ok, nil}
      {:error, _} = error -> error
      _ -> {:error, :external_conversation_not_found}
    end
  end

  @doc "Folds a provider reaction under the conversation lock without creating a statement or Signal."
  def fold_reaction_in_tx(repo, conversation_id, provider_message_id, reaction, now) do
    with %Conversation{kind: :external} <- lock_conversation(repo, conversation_id),
         %{external_ref: ref} <- get_message(repo, conversation_id, provider_message_id) do
      actors = ref.reactions |> Map.get(reaction.reaction_key, []) |> List.wrap() |> MapSet.new()

      actors =
        case reaction.action do
          :add -> MapSet.put(actors, reaction.actor_key)
          :remove -> MapSet.delete(actors, reaction.actor_key)
        end

      actors = actors |> MapSet.to_list() |> Enum.sort()

      reactions =
        if actors == [],
          do: Map.delete(ref.reactions, reaction.reaction_key),
          else: Map.put(ref.reactions, reaction.reaction_key, actors)

      ref
      |> ExternalMessageRef.changeset(
        Map.merge(
          %{
            reactions: reactions,
            raw_reaction_keys:
              Map.put(ref.raw_reaction_keys, reaction.reaction_key, reaction.raw_reaction_key)
          },
          %{last_seen_at: latest(ref.last_seen_at, now)}
        )
      )
      |> repo.update()
    else
      nil -> {:ok, nil}
      _ -> {:error, :external_conversation_not_found}
    end
  end

  defp write_observation(repo, conversation, existing, observation, provider_id, now) do
    {message, ref, status} =
      case existing do
        nil -> {%Message{}, %ExternalMessageRef{}, :inserted}
        %{message: message, external_ref: ref} -> {message, ref, :updated}
      end

    with {:ok, sequence} <- message_sequence(repo, conversation, message) do
      author = value(observation, :author) || ref.author || %{}
      {author_type, author_uid} = author_identity(repo, author)

      {author_type, author_uid} =
        if author_type == :unknown and message.author_type == :agent,
          do: {:agent, message.author_uid},
          else: {author_type, author_uid}

      message_id = message.id || Ankole.Ecto.UUIDv7.autogenerate()
      before_message = if message.id, do: message
      old_attachments = message.attachments || []
      attachments = value(observation, :attachments) || old_attachments

      message_attrs =
        take(observation, @message_fields)
        |> Map.merge(%{
          id: message_id,
          conversation_id: conversation.id,
          seq: sequence,
          origin: :external,
          author_type: author_type,
          author_uid: author_uid,
          attachments: attachments,
          created_at: message.created_at || value(observation, :provider_time) || now,
          reply_to_message_id:
            reply_message_id(repo, conversation.id, observation, message.reply_to_message_id)
        })

      ref_attrs =
        take(observation, @ref_fields)
        |> Map.merge(%{
          message_id: message_id,
          conversation_id: conversation.id,
          provider_message_id: provider_id,
          author: author,
          first_seen_at: ref.first_seen_at || now,
          last_seen_at: latest(ref.last_seen_at, now)
        })

      with {:ok, message} <- persist(repo, Message.changeset(message, message_attrs)),
           attachments =
             Attachments.prepare_in_tx(
               repo,
               value(observation, :agent_uid),
               conversation.id,
               message.id,
               attachments,
               old_attachments
             ),
           {:ok, message} <-
             message |> Message.changeset(%{attachments: attachments}) |> repo.update(),
           hash = content_hash(message, ref_attrs, ref),
           status = if(ref.content_hash == hash, do: :unchanged, else: status),
           ref_attrs = Map.put(ref_attrs, :content_hash, hash),
           {:ok, ref} <- persist(repo, ExternalMessageRef.changeset(ref, ref_attrs)),
           :ok <- Ankole.Conversations.message_changed_in_tx(repo, before_message, message, now),
           {:ok, conversation} <-
             conversation
             |> Conversation.changeset(%{
               last_activity_at: latest(conversation.last_activity_at, now),
               last_seen_at: latest(conversation.last_seen_at, now)
             })
             |> repo.update() do
        {:ok, %{status: status, conversation: conversation, message: message, external_ref: ref}}
      end
    end
  end

  defp author_identity(repo, author) do
    uid = Map.get(author, "principal_uid") || Map.get(author, "agent_uid")

    case is_binary(uid) && repo.get_by(Principal, uid: uid) do
      %Principal{uid: uid, type: :human} -> {:human, uid}
      %Principal{uid: uid, type: :agent} -> {:agent, uid}
      _ -> {:unknown, nil}
    end
  end

  defp conversation_attrs(existing, observation, now) do
    attrs = take(observation, @conversation_fields)

    title =
      value(observation, :title) || (existing && existing.title) ||
        value(observation, :provider_conversation_id)

    attrs = Map.put(attrs, :title, title)

    if existing do
      attrs =
        Enum.reduce(
          [:external_kind, :reply_mode, :visibility, :principal_group_id],
          attrs,
          fn field, acc ->
            if Map.get(acc, field) in [nil, :unknown, :none, "unknown", "none"],
              do: Map.put(acc, field, Map.get(existing, field)),
              else: acc
          end
        )

      attrs
      |> Map.put(:metadata, merge_maps(existing.metadata, value(observation, :metadata)))
      |> Map.put(
        :raw_payload,
        nonempty_map(value(observation, :raw_payload), existing.raw_payload)
      )
      |> Map.put(:last_seen_at, latest(existing.last_seen_at, now))
    else
      Map.merge(
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          kind: :external,
          external_kind: :unknown,
          reply_mode: :none,
          first_seen_at: now,
          last_seen_at: now,
          last_activity_at: now
        },
        Map.reject(attrs, fn {_field, value} -> is_nil(value) end)
      )
    end
  end

  defp write_conversation(repo, nil, attrs),
    do: %Conversation{} |> Conversation.changeset(attrs) |> repo.insert()

  defp write_conversation(repo, conversation, attrs),
    do: conversation |> Conversation.changeset(attrs) |> repo.update()

  defp ensure_agent(repo, id, uid) do
    %Participant{}
    |> Participant.changeset(%{conversation_id: id, principal_uid: uid, role: :agent})
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :conversation_id, :principal_uid]
    )
  end

  defp lock_identity(repo, parts) do
    key = Enum.join([Ankole.Repo.tenant_id!() | parts], "|")

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "external-conversation:" <> key
    ])
  end

  defp lock_conversation(repo, id),
    do:
      repo.one(
        from(conversation in Conversation, where: conversation.id == ^id, lock: "FOR UPDATE")
      )

  defp message_sequence(repo, conversation, %Message{seq: nil}),
    do: Ankole.Conversations.next_sequence_in_tx(repo, conversation)

  defp message_sequence(_repo, _conversation, %Message{seq: sequence}), do: {:ok, sequence}

  defp persist(repo, %{data: %{__meta__: %{state: :built}}} = changeset),
    do: repo.insert(changeset)

  defp persist(repo, changeset), do: repo.update(changeset)

  defp stale?(%{external_ref: %{provider_time: %DateTime{} = old}}, %DateTime{} = new),
    do: DateTime.compare(new, old) == :lt

  defp stale?(_, _), do: false

  defp latest(%DateTime{} = old, %DateTime{} = new),
    do: if(DateTime.compare(old, new) == :gt, do: old, else: new)

  defp latest(_, new), do: new

  defp reply_message_id(repo, id, observation, old) do
    if Map.has_key?(observation, :reply_to_provider_message_id) or
         Map.has_key?(observation, "reply_to_provider_message_id") do
      reply_id = value(observation, :reply_to_provider_message_id)

      case is_binary(reply_id) && get_message(repo, id, reply_id) do
        %{message: %{id: id}} -> id
        _ -> nil
      end
    else
      old
    end
  end

  defp content_hash(message, attrs, ref) do
    parts = [
      Map.take(message, [:text, :attachments, :links, :mentions, :rich_content]),
      Map.merge(
        Map.take(ref, [:author, :metadata, :reply_to_provider_message_id, :provider_thread_id]),
        Map.take(attrs, [:author, :metadata, :reply_to_provider_message_id, :provider_thread_id])
      )
    ]

    :crypto.hash(:sha256, :erlang.term_to_binary(parts)) |> Base.encode16(case: :lower)
  end

  defp nonempty_map(map, old) when map in [nil, %{}], do: old
  defp nonempty_map(map, _), do: map
  defp merge_maps(old, nil), do: old
  defp merge_maps(old, incoming), do: Map.merge(old || %{}, incoming)

  defp take(attrs, fields),
    do:
      Enum.reduce(fields, %{}, fn key, acc ->
        if Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key)),
          do: Map.put(acc, key, value(attrs, key)),
          else: acc
      end)

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp validate_provider_message_id(id) when is_binary(id) do
    if String.trim(id) != "", do: :ok, else: {:error, :invalid_provider_message_id}
  end

  defp validate_provider_message_id(_), do: {:error, :invalid_provider_message_id}
end
