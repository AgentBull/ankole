defmodule BullX.AIAgent.Conversations do
  @moduledoc """
  Conversation and Message mutation helpers for AIAgent runtime.

  A Conversation is AIAgent-owned durable execution state for one conversation
  key. It stores an append-only transcript used by prompt rendering, tool-loop
  recovery, command handling, and compression. External IM facts live in
  IMGateway tables; this transcript is the agent's interpretation and execution
  record.

  Summaries are durable overlay Messages (`kind: :summary`) that cover a
  contiguous range of transcript rows. They never replace or delete raw Messages.
  Runtime commands and lifecycle revisions hide obsolete transcript rows by
  writing `metadata.transcript_effect`.

  ## Generation lease

  Exactly one runner generates for a Conversation at a time. The lease lives in
  `conversation.generation` as a JSON blob with `lease_id`, `expires_at`,
  `max_expires_at`, and heartbeat metadata. Callers acquire via
  `acquire_generation_lease/3`, extend via `heartbeat_generation_lease/3`, and
  every persist checks `owned_active_lease?/3` so a preempted runner cannot
  write past its lease.

  Mutations that can affect the active transcript lock the Conversation row. This
  keeps MailboxSession redelivery, command handling, and generation recovery on
  one boring persistence path.
  """

  import Ecto.Query

  alias BullX.AIAgent.{Conversation, Message}
  alias BullX.Repo

  @type append_result :: {:ok, Conversation.t(), Message.t()} | {:error, term()}

  @spec find_or_create_active(String.t(), String.t(), map()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def find_or_create_active(agent_uid, conversation_key, metadata)
      when is_binary(agent_uid) and is_binary(conversation_key) and is_map(metadata) do
    Repo.transaction(fn ->
      case active_query(agent_uid, conversation_key)
           |> lock("FOR UPDATE")
           |> Repo.one() do
        %Conversation{} = conversation ->
          conversation

        nil ->
          %Conversation{}
          |> Conversation.changeset(%{
            agent_uid: agent_uid,
            conversation_key: conversation_key,
            generation: %{},
            metadata: metadata
          })
          |> Repo.insert()
          |> case do
            {:ok, conversation} -> conversation
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
    |> unwrap_transaction()
  end

  @spec get(String.t()) :: Conversation.t() | nil
  def get(conversation_id) when is_binary(conversation_id),
    do: Repo.get(Conversation, conversation_id)

  @spec append_message(Conversation.t(), map()) :: append_result()
  def append_message(%Conversation{} = conversation, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      locked = lock_conversation!(conversation.id)

      case insert_message(locked, attrs) do
        {:ok, message} -> {locked, message}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {conversation, message}} -> {:ok, conversation, message}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Compare-and-swap append: succeeds only if the visible transcript tail still
  matches `expected_tail_message_id`. Used by compression and other writers that
  computed something against a specific transcript snapshot and must abort
  cleanly if a concurrent writer has since appended prompt-visible content.
  """
  @spec append_message_if_transcript_tail(Conversation.t(), String.t() | nil, map(), keyword()) ::
          append_result()
  def append_message_if_transcript_tail(
        %Conversation{} = conversation,
        expected_tail_message_id,
        attrs,
        opts \\ []
      )
      when is_map(attrs) do
    lease_id = Keyword.get(opts, :lease_id)
    require_inactive_generation? = Keyword.get(opts, :require_inactive_generation?, false)

    Repo.transaction(fn ->
      locked = lock_conversation!(conversation.id)

      cond do
        not is_nil(locked.ended_at) ->
          Repo.rollback(:conversation_inactive)

        is_binary(lease_id) and
            not owned_active_lease?(locked, lease_id, DateTime.utc_now(:microsecond)) ->
          Repo.rollback(:generation_inactive)

        require_inactive_generation? and active_lease?(locked, DateTime.utc_now(:microsecond)) ->
          Repo.rollback(:generation_active)

        transcript_tail_id(locked) != expected_tail_message_id ->
          Repo.rollback(:transcript_changed)

        summary_attrs?(attrs) and not summary_interval_valid?(attrs, locked) ->
          Repo.rollback(:invalid_summary_interval)

        true ->
          case insert_message(locked, attrs) do
            {:ok, message} -> {locked, message}
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, {conversation, message}} -> {:ok, conversation, message}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec inbound_message_for_event(Conversation.t() | String.t(), term(), term()) ::
          Message.t() | nil
  def inbound_message_for_event(conversation, event_source, event_id)
      when is_binary(event_source) and event_source != "" and is_binary(event_id) and
             event_id != "" do
    conversation
    |> conversation_id()
    |> inbound_message_for_event_query(event_source, event_id)
    |> Repo.one()
  end

  def inbound_message_for_event(_conversation, _event_source, _event_id), do: nil

  @spec append_inbound_once(Conversation.t(), map()) :: append_result()
  def append_inbound_once(%Conversation{} = conversation, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      locked = lock_conversation!(conversation.id)

      case existing_inbound_message(locked, attrs) do
        %Message{} = message ->
          {locked, message}

        nil ->
          case insert_message(locked, attrs) do
            {:ok, message} -> {locked, message}
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, {conversation, message}} -> {:ok, conversation, message}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_message(Message.t(), map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def update_message(%Message{} = message, attrs) when is_map(attrs) do
    message
    |> Message.changeset(attrs)
    |> Repo.update()
  end

  @spec active_transcript(Conversation.t() | String.t()) :: [Message.t()]
  def active_transcript(%Conversation{} = conversation), do: active_transcript(conversation.id)

  def active_transcript(conversation_id) when is_binary(conversation_id) do
    Message
    |> where([m], m.conversation_id == ^conversation_id)
    |> where([m], m.kind != :summary)
    |> where([m], is_nil(fragment("?->'transcript_effect'", m.metadata)))
    |> order_by([m], asc: m.inserted_at, asc: m.id)
    |> Repo.all()
  end

  @doc """
  Returns the transcript as it should be presented to the model: raw Messages
  with the most recent compatible summary substituted in place of its
  `covers_range`. If no compatible summary exists, summaries remain persisted
  artifacts and are not part of the live model context.
  """
  @spec render_transcript(Conversation.t() | String.t()) :: [Message.t()]
  def render_transcript(%Conversation{} = conversation), do: render_transcript(conversation.id)

  def render_transcript(conversation_id) when is_binary(conversation_id) do
    transcript = active_transcript(conversation_id)

    case latest_compatible_summary(conversation_id, transcript) do
      nil -> transcript
      %Message{} = summary -> replace_range_with_summary(transcript, summary)
    end
  end

  @spec generated_output_for_trigger?(String.t()) :: boolean()
  def generated_output_for_trigger?(trigger_message_id) when is_binary(trigger_message_id) do
    Message
    |> where([m], m.role in [:assistant, :tool])
    |> where([m], m.status == :complete)
    |> where(
      [m],
      fragment("?->'generation'->>'trigger_message_id' = ?", m.metadata, ^trigger_message_id)
    )
    |> where([m], is_nil(fragment("?->'transcript_effect'", m.metadata)))
    |> Repo.exists?()
  end

  @spec complete_assistant_for_trigger(String.t()) :: Message.t() | nil
  def complete_assistant_for_trigger(trigger_message_id) when is_binary(trigger_message_id) do
    Message
    |> where([m], m.role == :assistant)
    |> where([m], m.kind == :normal)
    |> where([m], m.status == :complete)
    |> where(
      [m],
      fragment("?->'generation'->>'trigger_message_id' = ?", m.metadata, ^trigger_message_id)
    )
    |> where([m], is_nil(fragment("?->'transcript_effect'", m.metadata)))
    |> order_by([m], desc: m.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec tool_result_for_assistant?(String.t()) :: boolean()
  def tool_result_for_assistant?(assistant_message_id) when is_binary(assistant_message_id) do
    Message
    |> where([m], m.role == :tool)
    |> where([m], m.kind == :normal)
    |> where([m], m.status == :complete)
    |> where(
      [m],
      fragment(
        "?->'generation'->>'root_assistant_message_id' = ?",
        m.metadata,
        ^assistant_message_id
      )
    )
    |> where([m], is_nil(fragment("?->'transcript_effect'", m.metadata)))
    |> Repo.exists?()
  end

  @spec summary_for_range(String.t(), String.t(), String.t()) :: Message.t() | nil
  def summary_for_range(conversation_id, from_id, to_id)
      when is_binary(conversation_id) and is_binary(from_id) and is_binary(to_id) do
    Message
    |> where([m], m.conversation_id == ^conversation_id)
    |> where([m], m.role == :assistant and m.kind == :summary and m.status == :complete)
    |> where([m], fragment("?->>'from_id' = ?", m.covers_range, ^from_id))
    |> where([m], fragment("?->>'to_id' = ?", m.covers_range, ^to_id))
    |> order_by([m], desc: m.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec close_active(Conversation.t(), String.t(), DateTime.t()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def close_active(%Conversation{} = conversation, reason, now)
      when is_binary(reason) and is_struct(now, DateTime) do
    metadata =
      conversation.metadata
      |> Map.put("end_reason", reason)
      |> Map.put("ended_at", DateTime.to_iso8601(now))

    conversation
    |> Conversation.changeset(%{ended_at: now, metadata: metadata})
    |> Repo.update()
  end

  @spec acquire_generation_lease(Conversation.t(), map(), DateTime.t()) ::
          {:ok, Conversation.t(), String.t()} | {:error, :generation_active | Ecto.Changeset.t()}
  def acquire_generation_lease(%Conversation{} = conversation, owner, now)
      when is_map(owner) and is_struct(now, DateTime) do
    Repo.transaction(fn ->
      locked = lock_conversation!(conversation.id)

      case acquire_generation_lease_locked(locked, owner, now) do
        {:ok, updated, lease_id} -> {updated, lease_id}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {conversation, lease_id}} -> {:ok, conversation, lease_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec acquire_generation_lease_locked(Conversation.t(), map(), DateTime.t()) ::
          {:ok, Conversation.t(), String.t()} | {:error, :generation_active | Ecto.Changeset.t()}
  def acquire_generation_lease_locked(%Conversation{} = locked, owner, now)
      when is_map(owner) and is_struct(now, DateTime) do
    case active_lease?(locked, now) do
      true ->
        {:error, :generation_active}

      false ->
        lease_id = BullX.Ext.gen_uuid_v7()
        ttl_ms = owner["generation_lease_ttl_ms"] || 600_000
        max_runtime_ms = owner["generation_max_runtime_ms"] || 1_800_000
        expires_at = DateTime.add(now, ttl_ms, :millisecond)
        max_expires_at = DateTime.add(now, max_runtime_ms, :millisecond)

        generation =
          owner
          |> Map.take(["owner_trigger_type", "owner_trigger_id", "trigger_message_id"])
          |> Map.merge(%{
            "lease_id" => lease_id,
            "started_at" => DateTime.to_iso8601(now),
            "heartbeat_at" => DateTime.to_iso8601(now),
            "expires_at" => DateTime.to_iso8601(min_datetime(expires_at, max_expires_at)),
            "max_expires_at" => DateTime.to_iso8601(max_expires_at),
            "generation_lease_ttl_ms" => ttl_ms,
            "cancelled_at" => nil,
            "cancellation_reason" => nil
          })

        locked
        |> Conversation.changeset(%{generation: generation})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated, lease_id}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec owned_active_lease?(Conversation.t(), String.t(), DateTime.t()) :: boolean()
  def owned_active_lease?(%Conversation{} = conversation, lease_id, now)
      when is_binary(lease_id) and is_struct(now, DateTime) do
    conversation.generation["lease_id"] == lease_id and active_lease?(conversation, now)
  end

  @spec heartbeat_generation_lease(String.t(), String.t(), DateTime.t()) ::
          {:ok, Conversation.t()} | {:error, :generation_inactive | Ecto.Changeset.t()}
  def heartbeat_generation_lease(conversation_id, lease_id, now)
      when is_binary(conversation_id) and is_binary(lease_id) and is_struct(now, DateTime) do
    Repo.transaction(fn ->
      locked = lock_conversation!(conversation_id)

      if owned_active_lease?(locked, lease_id, now) do
        ttl_ms = locked.generation["generation_lease_ttl_ms"] || 600_000
        expires_at = DateTime.add(now, ttl_ms, :millisecond)
        max_expires_at = parse_datetime(locked.generation["max_expires_at"]) || expires_at

        generation =
          locked.generation
          |> Map.put("heartbeat_at", DateTime.to_iso8601(now))
          |> Map.put("expires_at", DateTime.to_iso8601(min_datetime(expires_at, max_expires_at)))

        locked
        |> Conversation.changeset(%{generation: generation})
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        Repo.rollback(:generation_inactive)
      end
    end)
    |> unwrap_transaction()
  end

  @spec clear_generation_lease(Conversation.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def clear_generation_lease(%Conversation{} = conversation, lease_id) when is_binary(lease_id) do
    Repo.transaction(fn ->
      locked = lock_conversation!(conversation.id)

      case {locked.generation["lease_id"], locked.generation["cancelled_at"]} do
        {^lease_id, nil} ->
          locked
          |> Conversation.changeset(%{generation: %{}})
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end

        _other ->
          locked
      end
    end)
    |> unwrap_transaction()
  end

  @spec cancel_generation(Conversation.t(), String.t(), DateTime.t(), map()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def cancel_generation(%Conversation{} = conversation, reason, now, metadata \\ %{})
      when is_binary(reason) and is_struct(now, DateTime) and is_map(metadata) do
    generation =
      conversation.generation
      |> Map.merge(metadata)
      |> Map.put("cancelled_at", DateTime.to_iso8601(now))
      |> Map.put("cancellation_reason", reason)

    conversation
    |> Conversation.changeset(%{generation: generation})
    |> Repo.update()
  end

  @spec cancel_generation_lease(String.t(), String.t(), String.t(), DateTime.t(), map()) ::
          {:ok, Conversation.t()} | {:error, :generation_inactive | Ecto.Changeset.t()}
  def cancel_generation_lease(conversation_id, lease_id, reason, now, metadata \\ %{})
      when is_binary(conversation_id) and is_binary(lease_id) and is_binary(reason) and
             is_struct(now, DateTime) and is_map(metadata) do
    Repo.transaction(fn ->
      locked = lock_conversation!(conversation_id)

      case owned_active_lease?(locked, lease_id, now) do
        true ->
          case cancel_generation(locked, reason, now, metadata) do
            {:ok, cancelled} -> cancelled
            {:error, changeset} -> Repo.rollback(changeset)
          end

        false ->
          Repo.rollback(:generation_inactive)
      end
    end)
    |> unwrap_transaction()
  end

  defp active_query(agent_uid, conversation_key) do
    Conversation
    |> where([c], c.agent_uid == ^agent_uid)
    |> where([c], c.conversation_key == ^conversation_key)
    |> where([c], is_nil(c.ended_at))
  end

  defp lock_conversation!(conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp conversation_id(%Conversation{id: id}), do: id
  defp conversation_id(id) when is_binary(id), do: id

  defp inbound_message_for_event_query(conversation_id, event_source, event_id) do
    Message
    |> where([m], m.conversation_id == ^conversation_id)
    |> where([m], m.event_source == ^event_source)
    |> where([m], m.event_id == ^event_id)
    |> where([m], m.role in [:user, :im_ambient])
    |> where([m], m.kind == :normal)
  end

  defp existing_inbound_message(%Conversation{} = conversation, attrs) do
    case inbound_event_identity(attrs) do
      {event_source, event_id} ->
        conversation.id
        |> inbound_message_for_event_query(event_source, event_id)
        |> Repo.one()

      nil ->
        nil
    end
  end

  defp inbound_event_identity(attrs) do
    with event_source when is_binary(event_source) and event_source != "" <-
           map_value(attrs, :event_source),
         event_id when is_binary(event_id) and event_id != "" <- map_value(attrs, :event_id) do
      {event_source, event_id}
    else
      _missing -> nil
    end
  end

  defp insert_message(%Conversation{} = conversation, attrs) do
    %Message{}
    |> Message.changeset(owned_message_attrs(conversation, attrs))
    |> Repo.insert()
  end

  defp owned_message_attrs(%Conversation{} = conversation, attrs) do
    attrs
    |> Map.put(:conversation_id, conversation.id)
    |> Map.put(:agent_uid, conversation.agent_uid)
  end

  defp summary_attrs?(attrs) do
    role = attrs[:role] || attrs["role"]
    kind = attrs[:kind] || attrs["kind"]
    role in [:assistant, "assistant"] and kind in [:summary, "summary"]
  end

  defp summary_interval_valid?(attrs, conversation) do
    covers_range = attrs[:covers_range] || attrs["covers_range"] || %{}
    from_id = covers_range["from_id"] || covers_range[:from_id]
    to_id = covers_range["to_id"] || covers_range[:to_id]

    transcript = active_transcript(conversation)

    indexed = transcript_index(transcript)

    with {%Message{}, from_index} <- Map.get(indexed, from_id),
         {%Message{}, to_index} <- Map.get(indexed, to_id),
         true <- from_index <= to_index do
      transcript
      |> Enum.slice(from_index..to_index)
      |> Enum.all?(&summary_eligible_message?/1)
    else
      _other -> false
    end
  end

  defp transcript_tail_id(%Conversation{} = conversation) do
    conversation
    |> active_transcript()
    |> List.last()
    |> case do
      %Message{id: id} -> id
      nil -> nil
    end
  end

  defp latest_compatible_summary(_conversation_id, []), do: nil

  defp latest_compatible_summary(conversation_id, transcript) do
    indexed = transcript_index(transcript)
    eligible_ids = summary_eligible_ids(transcript)

    case eligible_ids do
      [] ->
        nil

      [_ | _] ->
        Message
        |> where([m], m.conversation_id == ^conversation_id)
        |> where([m], m.role == :assistant and m.kind == :summary and m.status == :complete)
        |> where([m], is_nil(fragment("?->'transcript_effect'", m.metadata)))
        |> where([m], fragment("?->>'from_id' = ANY(?)", m.covers_range, ^eligible_ids))
        |> where([m], fragment("?->>'to_id' = ANY(?)", m.covers_range, ^eligible_ids))
        |> order_by([m], desc: m.inserted_at, desc: m.id)
        |> Repo.all()
        |> Enum.find(&compatible_summary?(&1, transcript, indexed))
    end
  end

  defp transcript_index(transcript) do
    transcript
    |> Enum.with_index()
    |> Map.new(fn {message, index} -> {message.id, {message, index}} end)
  end

  defp summary_eligible_ids(transcript) do
    transcript
    |> Enum.filter(&summary_eligible_message?/1)
    |> Enum.map(& &1.id)
  end

  defp compatible_summary?(
         %Message{covers_range: %{"from_id" => from_id, "to_id" => to_id}},
         transcript,
         indexed
       ) do
    with {%Message{}, from_index} <- Map.get(indexed, from_id),
         {%Message{}, to_index} <- Map.get(indexed, to_id),
         true <- from_index <= to_index do
      transcript
      |> Enum.slice(from_index..to_index)
      |> Enum.all?(&summary_eligible_message?/1)
    else
      _other -> false
    end
  end

  defp compatible_summary?(_summary, _transcript, _indexed), do: false

  defp summary_eligible_message?(%Message{} = message) do
    message.status != :generating and
      not (message.role == :im_ambient and message.kind == :normal)
  end

  defp replace_range_with_summary(
         transcript,
         %Message{covers_range: %{"from_id" => from_id, "to_id" => to_id}} = summary
       ) do
    {_state, rendered} =
      Enum.reduce(transcript, {:before, []}, fn message, {state, acc} ->
        case {state, message.id} do
          {:before, ^from_id} -> {:inside, [summary | acc]}
          {:inside, ^to_id} -> {:after, acc}
          {:inside, _id} -> {:inside, acc}
          {_state, _id} when message.kind == :summary -> {state, acc}
          {_state, _id} -> {state, [message | acc]}
        end
      end)

    Enum.reverse(rendered)
  end

  defp active_lease?(%Conversation{generation: generation}, now) when is_map(generation) do
    with lease_id when is_binary(lease_id) <- generation["lease_id"],
         nil <- generation["cancelled_at"],
         expires_at when is_binary(expires_at) <- generation["expires_at"],
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at) do
      DateTime.compare(expires_at, now) == :gt
    else
      _other -> false
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp map_value(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp min_datetime(first, second) do
    case DateTime.compare(first, second) do
      :gt -> second
      _other -> first
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
