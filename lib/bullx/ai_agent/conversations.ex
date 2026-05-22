defmodule BullX.AIAgent.Conversations do
  @moduledoc """
  Conversation and Message mutation helpers for AIAgent runtime.

  In an OpenClaw / Hermes-style harness, a session is the conversation you
  are currently having — the source of truth is the live transcript, and a
  "history" file or memory note is an artifact derived from it. In BullX a
  Conversation is itself a durable **business record**: a per-scope chat
  object that outlives any process, addressable as a Postgres row, with
  product-level semantics (start, end, branch, summary, audit). Two
  properties worth knowing before reading the code:

  * Messages form a **tree** (each Message has `parent_id`), not a flat
    list. The "active branch" is the path from the current leaf back to the
    root, which lets the runtime rewind to a prior turn and explore an
    alternate continuation without losing history.
  * **Compression is durable.** A summary is itself a Message (with
    `kind: :summary`) that covers a contiguous range of the branch; it lives
    *alongside* the raw Messages it summarizes rather than replacing them, so
    the un-compressed history is always retrievable.

  ## Branch model

  A Conversation stores Messages as a tree (each Message has `parent_id`). The
  "active branch" is the path from `current_leaf_message_id` back to the root.
  A leaf may be a `:summary` Message that overlays a range of raw Messages —
  `raw_leaf_id/1` then unwraps the summary back to the underlying raw leaf so
  appends continue from real conversation history rather than from the summary.

  ## Generation lease

  Exactly one runner generates for a Conversation at a time. The lease lives in
  `conversation.generation` as a JSON blob with `lease_id`, `expires_at`,
  `max_expires_at`, and heartbeat metadata. Callers acquire via
  `acquire_generation_lease/3`, extend via `heartbeat_generation_lease/3`, and
  every persist checks `owned_active_lease?/3` so a preempted runner cannot
  write past its lease.

  Mutations that can affect the active branch lock the Conversation row. This
  keeps TargetSession redelivery, command handling, and generation recovery on
  one boring persistence path.
  """

  import Ecto.Query

  alias BullX.AIAgent.{Conversation, Message}
  alias BullX.Repo

  @type append_result :: {:ok, Conversation.t(), Message.t()} | {:error, term()}

  @spec find_or_create_active(String.t(), String.t(), map()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def find_or_create_active(agent_principal_id, conversation_key, metadata)
      when is_binary(agent_principal_id) and is_binary(conversation_key) and is_map(metadata) do
    Repo.transaction(fn ->
      case active_query(agent_principal_id, conversation_key)
           |> lock("FOR UPDATE")
           |> Repo.one() do
        %Conversation{} = conversation ->
          conversation

        nil ->
          %Conversation{}
          |> Conversation.changeset(%{
            agent_principal_id: agent_principal_id,
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

  @spec lock_active(String.t(), String.t(), (Conversation.t() | nil -> term())) ::
          {:ok, term()} | {:error, term()}
  def lock_active(agent_principal_id, conversation_key, fun)
      when is_binary(agent_principal_id) and is_binary(conversation_key) and is_function(fun, 1) do
    Repo.transaction(fn ->
      agent_principal_id
      |> active_query(conversation_key)
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> fun.()
    end)
    |> unwrap_transaction()
  end

  @spec append_message(Conversation.t(), map(), keyword()) :: append_result()
  def append_message(%Conversation{} = conversation, attrs, opts \\ []) when is_map(attrs) do
    move_leaf? = Keyword.get(opts, :move_leaf?, true)

    Repo.transaction(fn ->
      locked = lock_conversation!(conversation.id)
      attrs = Map.put_new(attrs, :parent_id, raw_leaf_id(locked))

      with {:ok, message} <- insert_message(attrs),
           {:ok, updated} <- maybe_move_leaf(locked, message, move_leaf?) do
        {updated, message}
      else
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
  Compare-and-swap append: succeeds only if the active branch's raw leaf still
  matches `expected_raw_leaf_id`. Used by compression and other writers that
  computed something against a specific branch snapshot and must abort cleanly
  if a concurrent writer has since moved the leaf (returns `:branch_changed`).
  """
  @spec append_message_if_raw_leaf(Conversation.t(), String.t() | nil, map(), keyword()) ::
          append_result()
  def append_message_if_raw_leaf(
        %Conversation{} = conversation,
        expected_raw_leaf_id,
        attrs,
        opts \\ []
      )
      when is_map(attrs) do
    move_leaf? = Keyword.get(opts, :move_leaf?, true)
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

        raw_leaf_id(locked) != expected_raw_leaf_id ->
          Repo.rollback(:branch_changed)

        summary_attrs?(attrs) and not summary_interval_valid?(attrs, locked) ->
          Repo.rollback(:invalid_summary_interval)

        true ->
          attrs = Map.put_new(attrs, :parent_id, expected_raw_leaf_id)

          with {:ok, message} <- insert_message(attrs),
               {:ok, updated} <- maybe_move_leaf(locked, message, move_leaf?) do
            {updated, message}
          else
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

  @spec inbound_message_for_entry(String.t()) :: Message.t() | nil
  def inbound_message_for_entry(target_session_entry_id)
      when is_binary(target_session_entry_id) do
    Message
    |> where([m], m.target_session_entry_id == ^target_session_entry_id)
    |> where([m], m.role in [:user, :im_ambient])
    |> where([m], m.kind == :normal)
    |> Repo.one()
  end

  @spec append_inbound_once(Conversation.t(), String.t(), map(), keyword()) :: append_result()
  def append_inbound_once(
        %Conversation{} = conversation,
        target_session_entry_id,
        attrs,
        opts \\ []
      )
      when is_binary(target_session_entry_id) and is_map(attrs) do
    existing =
      Message
      |> where([m], m.target_session_entry_id == ^target_session_entry_id)
      |> where([m], m.role in [:user, :im_ambient])
      |> where([m], m.kind == :normal)
      |> Repo.one()

    case existing do
      %Message{} = message ->
        {:ok, Repo.get!(Conversation, message.conversation_id), message}

      nil ->
        attrs
        |> Map.put(:target_session_entry_id, target_session_entry_id)
        |> then(&append_message(conversation, &1, opts))
    end
  end

  @spec update_message(Message.t(), map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def update_message(%Message{} = message, attrs) when is_map(attrs) do
    message
    |> Message.changeset(attrs)
    |> Repo.update()
  end

  @spec active_branch(Conversation.t() | String.t()) :: [Message.t()]
  def active_branch(%Conversation{} = conversation), do: active_branch(conversation.id)

  def active_branch(conversation_id) when is_binary(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil -> []
      %Conversation{} = conversation -> branch_from_leaf(resolve_raw_leaf_id(conversation))
    end
  end

  @doc """
  Returns the branch as it should be presented to the model: raw Messages with
  the most recent compatible summary substituted in place of its
  `covers_range`. If no compatible summary exists, summaries are stripped from
  the branch entirely (they're persisted artifacts, not part of the live
  context unless they cover a contiguous range of the current branch).
  """
  @spec render_branch(Conversation.t() | String.t()) :: [Message.t()]
  def render_branch(%Conversation{} = conversation), do: render_branch(conversation.id)

  def render_branch(conversation_id) when is_binary(conversation_id) do
    branch = active_branch(conversation_id)

    case latest_compatible_summary(conversation_id, branch) do
      nil -> Enum.reject(branch, &(&1.kind == :summary))
      %Message{} = summary -> replace_range_with_summary(branch, summary)
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
    |> where([m], is_nil(fragment("?->'branch_effect'", m.metadata)))
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
    |> where([m], is_nil(fragment("?->'branch_effect'", m.metadata)))
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
    |> where([m], is_nil(fragment("?->'branch_effect'", m.metadata)))
    |> Repo.exists?()
  end

  @spec summary_for_entry(String.t()) :: Message.t() | nil
  def summary_for_entry(target_session_entry_id) when is_binary(target_session_entry_id) do
    Message
    |> where([m], m.target_session_entry_id == ^target_session_entry_id)
    |> where([m], m.role == :assistant and m.kind == :summary and m.status == :complete)
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

  defp active_query(agent_principal_id, conversation_key) do
    Conversation
    |> where([c], c.agent_principal_id == ^agent_principal_id)
    |> where([c], c.conversation_key == ^conversation_key)
    |> where([c], is_nil(c.ended_at))
  end

  defp lock_conversation!(conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp insert_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  defp summary_attrs?(attrs) do
    role = attrs[:role] || attrs["role"]
    kind = attrs[:kind] || attrs["kind"]
    role in [:assistant, "assistant"] and kind in [:summary, "summary"]
  end

  defp summary_interval_valid?(attrs, conversation) do
    covers_range = attrs[:covers_range] || attrs["covers_range"] || %{}
    metadata = attrs[:metadata] || attrs["metadata"] || %{}
    from_id = covers_range["from_id"] || covers_range[:from_id]
    to_id = covers_range["to_id"] || covers_range[:to_id]
    source_leaf_id = metadata["source_leaf_message_id"] || metadata[:source_leaf_message_id]

    branch = active_branch(conversation)

    indexed =
      branch
      |> Enum.with_index()
      |> Map.new(fn {message, index} -> {message.id, {message, index}} end)

    with {%Message{}, from_index} <- Map.get(indexed, from_id),
         {%Message{}, to_index} <- Map.get(indexed, to_id),
         {%Message{}, source_leaf_index} <- Map.get(indexed, source_leaf_id),
         true <- from_index <= to_index,
         true <- to_index <= source_leaf_index do
      branch
      |> Enum.slice(from_index..to_index)
      |> Enum.all?(fn message ->
        message.kind != :summary and message.status != :generating and
          not (message.role == :im_ambient and message.kind == :normal)
      end)
    else
      _other -> false
    end
  end

  defp maybe_move_leaf(conversation, _message, false), do: {:ok, conversation}

  defp maybe_move_leaf(conversation, message, true) do
    conversation
    |> Conversation.changeset(%{current_leaf_message_id: message.id})
    |> Repo.update()
  end

  defp raw_leaf_id(%Conversation{current_leaf_message_id: nil}), do: nil

  # When the leaf is a summary, the "raw" leaf is the original message the
  # summary was anchored at — appends continue from there, not from the summary.
  # The summary is a render-time overlay (see `render_branch/1`), not a real
  # parent for future Messages.
  defp raw_leaf_id(%Conversation{current_leaf_message_id: leaf_id} = conversation) do
    case Repo.get(Message, leaf_id) do
      %Message{kind: :summary, metadata: %{"source_leaf_message_id" => source_leaf_id}} ->
        source_leaf_id

      %Message{} ->
        leaf_id

      nil ->
        conversation.current_leaf_message_id
    end
  end

  defp resolve_raw_leaf_id(%Conversation{current_leaf_message_id: nil}), do: nil
  defp resolve_raw_leaf_id(%Conversation{} = conversation), do: raw_leaf_id(conversation)

  defp branch_from_leaf(nil), do: []

  defp branch_from_leaf(leaf_id) do
    unfold_branch(leaf_id, [])
  end

  defp unfold_branch(nil, acc), do: acc

  defp unfold_branch(message_id, acc) do
    case Repo.get(Message, message_id) do
      nil -> acc
      %Message{} = message -> unfold_branch(message.parent_id, [message | acc])
    end
  end

  defp latest_compatible_summary(conversation_id, branch) do
    Message
    |> where([m], m.conversation_id == ^conversation_id)
    |> where([m], m.role == :assistant and m.kind == :summary and m.status == :complete)
    |> Repo.all()
    |> Enum.filter(&compatible_summary?(&1, branch))
    |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}, :desc)
    |> List.first()
  end

  defp compatible_summary?(
         %Message{covers_range: %{"from_id" => from_id, "to_id" => to_id}, metadata: metadata},
         branch
       ) do
    indexed =
      branch
      |> Enum.with_index()
      |> Map.new(fn {message, index} -> {message.id, {message, index}} end)

    source_leaf_id = metadata["source_leaf_message_id"]

    with {%Message{}, from_index} <- Map.get(indexed, from_id),
         {%Message{}, to_index} <- Map.get(indexed, to_id),
         {%Message{}, source_leaf_index} <- Map.get(indexed, source_leaf_id),
         true <- from_index <= to_index,
         true <- to_index <= source_leaf_index do
      branch
      |> Enum.slice(from_index..to_index)
      |> Enum.all?(fn message ->
        message.kind != :summary and message.status != :generating and
          not (message.role == :im_ambient and message.kind == :normal)
      end)
    else
      _other -> false
    end
  end

  defp compatible_summary?(_summary, _branch), do: false

  defp replace_range_with_summary(
         branch,
         %Message{covers_range: %{"from_id" => from_id, "to_id" => to_id}} = summary
       ) do
    {_state, rendered} =
      Enum.reduce(branch, {:before, []}, fn message, {state, acc} ->
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

  defp min_datetime(first, second) do
    case DateTime.compare(first, second) do
      :gt -> second
      _other -> first
    end
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
