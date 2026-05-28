defmodule BullX.AIAgent.MessageRevisions do
  @moduledoc false

  import Ecto.Query

  alias BullX.AIAgent.{
    AmbientBatch,
    Conversation,
    Conversations,
    DeliveryRecall,
    Event,
    Message,
    Time
  }

  alias BullX.MailBox
  alias BullX.MailBox.StreamingOutput.Redis
  alias BullX.MailBox.Entry, as: MailboxEntry
  alias BullX.Principals.Principal
  alias BullX.Repo

  @addressed_reasons ~w(dm mention free_response command reply_to_bot application_command mention_text)
  @preview_chars 500
  @revision_dedupe_ttl_ms 86_400_000

  @type action :: :edited | :recalled

  @spec provider_ref_metadata(map()) :: map()
  def provider_ref_metadata(event_data) when is_map(event_data) do
    case source_message_ids(event_data) do
      [] -> %{}
      ids -> %{"provider_refs" => %{"message_ids" => ids}}
    end
  end

  @spec handle(action(), map(), Principal.t(), map(), map(), String.t() | nil) ::
          :ok | {:error, term()}
  def handle(action, event_data, %Principal{} = principal, invocation, entry, caller_principal_id)
      when action in [:edited, :recalled] and is_map(event_data) and is_map(invocation) and
             is_map(entry) do
    case reserve_revision_entry(entry) do
      :duplicate ->
        :ok

      :process ->
        event_data
        |> source_message_ids()
        |> find_target_message(principal.id, Map.get(entry, :event_source))
        |> case do
          %Message{} = target ->
            target
            |> revise_target(action, event_data, invocation, entry, caller_principal_id)
            |> run_side_effects(event_data, invocation, entry, caller_principal_id)

          nil ->
            :ok
        end
    end
  end

  def handle(_action, _event_data, _principal, _invocation, _entry, _caller_principal_id),
    do: :ok

  @spec source_message_ids(map()) :: [String.t()]
  def source_message_ids(event_data) when is_map(event_data) do
    [
      ref_message_ids(map_value(event_data, "refs")),
      raw_ref_message_ids(map_value(event_data, "raw_ref"))
    ]
    |> List.flatten()
    |> Enum.map(&safe_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def source_message_ids(_event_data), do: []

  defp find_target_message([], _agent_principal_id, _event_source), do: nil

  defp find_target_message(target_ids, agent_principal_id, event_source) do
    target_set = MapSet.new(target_ids)

    agent_principal_id
    |> target_candidates(event_source)
    |> Enum.find_value(fn {message, cloud_event} ->
      case intersects?(target_set, message_source_ids(message, cloud_event)) do
        true -> message
        false -> nil
      end
    end)
  end

  defp target_candidates(agent_principal_id, event_source) do
    Message
    |> join(:inner, [m], c in Conversation, on: c.id == m.conversation_id)
    |> join(:left, [m, _c], e in MailboxEntry, on: e.id == m.mailbox_entry_id)
    |> where([m, c], c.agent_principal_id == ^agent_principal_id)
    |> where([_m, c], is_nil(c.ended_at))
    |> where([m], m.role in [:user, :im_ambient])
    |> where([m], m.kind == :normal)
    |> where([m], is_nil(fragment("?->'branch_effect'", m.metadata)))
    |> maybe_event_source(event_source)
    |> order_by([m], desc: m.inserted_at)
    |> select([m, _c, e], {m, e.cloud_event})
    |> Repo.all()
  end

  defp maybe_event_source(query, event_source)
       when is_binary(event_source) and event_source != "",
       do: where(query, [m], m.event_source == ^event_source)

  defp maybe_event_source(query, _event_source), do: query

  defp message_source_ids(%Message{metadata: metadata}, cloud_event) do
    metadata_ids =
      metadata
      |> get_in(["provider_refs", "message_ids"])
      |> List.wrap()

    event_ids =
      case cloud_event do
        %{"data" => data} -> source_message_ids(data)
        _cloud_event -> []
      end

    (metadata_ids ++ event_ids)
    |> Enum.map(&safe_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp intersects?(target_set, ids) do
    ids
    |> Enum.any?(&MapSet.member?(target_set, &1))
  end

  defp revise_target(target, action, event_data, invocation, entry, caller_principal_id) do
    Repo.transaction(fn ->
      conversation = lock_conversation!(target.conversation_id)

      case lock_message(target.id) do
        %Message{conversation_id: conversation_id} = locked_target
        when conversation_id == conversation.id ->
          revise_locked(action, locked_target, conversation, event_data, invocation, entry)

        _missing ->
          Repo.rollback(:ignore)
      end
    end)
    |> case do
      {:ok, effects} -> {:ok, Map.put(effects, :caller_principal_id, caller_principal_id)}
      {:error, :ignore} -> {:ok, empty_effects()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revise_locked(
         :edited,
         %Message{role: :user, kind: :normal} = target,
         conversation,
         event_data,
         invocation,
         entry
       ) do
    case latest_addressed_with_output?(conversation, target) do
      true -> latest_addressed_edit(target, conversation, event_data, entry)
      false -> historical_addressed_edit(target, conversation, event_data, invocation, entry)
    end
  end

  defp revise_locked(
         :recalled,
         %Message{role: :user, kind: :normal} = target,
         conversation,
         _event_data,
         _invocation,
         entry
       ) do
    case latest_addressed_with_output?(conversation, target) do
      true -> latest_addressed_recall(target, conversation, entry)
      false -> historical_addressed_recall(target, conversation, entry)
    end
  end

  defp revise_locked(
         :edited,
         %Message{role: :im_ambient, kind: :normal} = target,
         conversation,
         event_data,
         invocation,
         entry
       ) do
    case {lane_for_event_data(event_data), latest_ambient_turn?(conversation, target)} do
      {:addressed, true} ->
        latest_ambient_to_addressed_edit(target, conversation, event_data, entry)

      _other ->
        ambient_edit_by_old_lane(target, conversation, event_data, invocation, entry)
    end
  end

  defp revise_locked(
         :recalled,
         %Message{role: :im_ambient, kind: :normal} = target,
         conversation,
         _event_data,
         invocation,
         entry
       ) do
    ambient_recall_by_old_lane(target, conversation, invocation, entry)
  end

  defp revise_locked(_action, _target, _conversation, _event_data, _invocation, _entry),
    do: empty_effects()

  defp latest_addressed_edit(target, conversation, event_data, entry) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, conversation} <-
           maybe_cancel_generation(conversation, target.id, "source_message_edited", now),
         branch <- Conversations.active_branch(conversation),
         suffix <- suffix_from(branch, target),
         recall_targets <- DeliveryRecall.targets_for_messages(suffix),
         :ok <- mark_suffix(suffix, "superseded", "source_message_edited", entry.id, now),
         {:ok, _conversation} <- Conversations.set_current_leaf(conversation, target.parent_id) do
      empty_effects()
      |> Map.put(:recall_targets, recall_targets)
      |> Map.put(:republish_lane, lane_for_event_data(event_data))
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp latest_addressed_recall(target, conversation, entry) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, conversation} <-
           maybe_cancel_generation(conversation, target.id, "source_message_recalled", now),
         branch <- Conversations.active_branch(conversation),
         suffix <- suffix_from(branch, target),
         recall_targets <- DeliveryRecall.targets_for_messages(suffix),
         :ok <- mark_suffix(suffix, "recalled", "source_message_recalled", entry.id, now),
         {:ok, _conversation} <- Conversations.set_current_leaf(conversation, target.parent_id) do
      empty_effects()
      |> Map.put(:recall_targets, recall_targets)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp latest_ambient_to_addressed_edit(target, conversation, event_data, _entry) do
    with :ok <- delete_message_and_rewire(conversation, target) do
      empty_effects()
      |> Map.put(:batch_remove, batch_ref(conversation, target))
      |> Map.put(:republish_lane, lane_for_event_data(event_data))
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp historical_addressed_edit(target, conversation, event_data, invocation, entry) do
    content = content_blocks(event_data) ++ [inserted_at_marker(target)]
    notice = historical_edit_notice(target, event_data)

    with {:ok, _target} <- update_content(target, content, event_data),
         {:ok, _conversation, _message} <-
           append_revision_message(conversation, invocation, entry, :user, :introspection, notice) do
      empty_effects()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp historical_addressed_recall(target, conversation, entry) do
    content = [Message.text_block("[message recalled]"), inserted_at_marker(target)]
    notice = historical_recall_notice(target)

    with {:ok, _target} <- update_content(target, content, %{}),
         {:ok, _conversation, _message} <-
           append_revision_message(conversation, %{}, entry, :user, :introspection, notice) do
      empty_effects()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ambient_edit_by_old_lane(target, conversation, event_data, invocation, entry) do
    case later_ambient_introspection?(target) do
      false ->
        content = content_blocks(event_data)

        with {:ok, _target} <- update_content(target, content, event_data) do
          empty_effects()
          |> Map.put(
            :batch_update,
            Map.put(batch_ref(conversation, target), :text, Event.text_content(event_data))
          )
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      true ->
        notice = historical_edit_notice(target, event_data)

        with {:ok, _target} <- append_target_marker(target),
             {:ok, _conversation, _message} <-
               append_revision_message(
                 conversation,
                 invocation,
                 entry,
                 :im_ambient,
                 :normal,
                 notice,
                 scene_metadata: target.metadata
               ) do
          empty_effects()
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp ambient_recall_by_old_lane(target, conversation, invocation, entry) do
    case later_ambient_introspection?(target) do
      false ->
        with :ok <- delete_message_and_rewire(conversation, target) do
          empty_effects()
          |> Map.put(:batch_remove, batch_ref(conversation, target))
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      true ->
        notice = historical_recall_notice(target)

        with {:ok, _target} <- append_target_marker(target),
             {:ok, _conversation, _message} <-
               append_revision_message(
                 conversation,
                 invocation,
                 entry,
                 :im_ambient,
                 :normal,
                 notice,
                 scene_metadata: target.metadata
               ) do
          empty_effects()
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp run_side_effects({:error, reason}, _event_data, _invocation, _entry, _caller_principal_id),
    do: {:error, reason}

  defp run_side_effects({:ok, effects}, event_data, invocation, entry, caller_principal_id) do
    :ok = maybe_update_batch(effects)
    :ok = maybe_remove_from_batch(effects)
    :ok = maybe_recall_outputs(effects, event_data, entry)
    maybe_republish(effects, event_data, invocation, entry, caller_principal_id)
  end

  defp maybe_update_batch(%{
         batch_update: %{
           agent_principal_id: agent,
           conversation_id: conversation,
           message_id: message,
           text: text
         }
       })
       when is_binary(text) do
    _result = AmbientBatch.update_item(agent, conversation, message, text)
    :ok
  end

  defp maybe_update_batch(_effects), do: :ok

  defp maybe_remove_from_batch(%{
         batch_remove: %{
           agent_principal_id: agent,
           conversation_id: conversation,
           message_id: message
         }
       }) do
    _result = AmbientBatch.remove_item(agent, conversation, message)
    :ok
  end

  defp maybe_remove_from_batch(_effects), do: :ok

  defp maybe_recall_outputs(%{recall_targets: [_ | _] = targets}, event_data, entry) do
    reply_address = Event.reply_address(event_data)

    _result =
      DeliveryRecall.deliver_targets(reply_address, targets, %{
        "mailbox_entry_id" => entry.id,
        "event_id" => entry.event_id,
        "reason" => "message_revision"
      })

    :ok
  end

  defp maybe_recall_outputs(_effects, _event_data, _entry), do: :ok

  defp maybe_republish(
         %{republish_lane: :ignored},
         _event_data,
         _invocation,
         _entry,
         _caller_principal_id
       ),
       do: :ok

  defp maybe_republish(
         %{republish_lane: lane},
         event_data,
         invocation,
         entry,
         caller_principal_id
       )
       when lane in [:addressed, :ambient] do
    event_type =
      case lane do
        :addressed -> "bullx.im.message.addressed"
        :ambient -> "bullx.im.message.ambient"
      end

    MailBox.deliver(%{
      cloud_event: republished_event(event_data, entry, event_type, caller_principal_id),
      receiver_type: "ai_agent",
      receiver_ref: invocation.target_ref,
      attention: lane,
      session_key: Map.get(invocation, :mailbox_session_id),
      dedupe_key: "message_revision"
    })
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_republish(_effects, _event_data, _invocation, _entry, _caller_principal_id), do: :ok

  defp republished_event(event_data, entry, event_type, caller_principal_id) do
    base = Map.get(entry, :cloud_event) || %{}

    %{
      "specversion" => base["specversion"] || "1.0",
      "id" => republished_event_id(event_type, event_data, entry),
      "source" => base["source"] || entry.event_source,
      "type" => event_type,
      "time" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
      "datacontenttype" => base["datacontenttype"] || "application/json",
      "subject" => base["subject"] || "#{event_type}:#{entry.event_id}",
      "data" => event_data |> put_caller_principal(caller_principal_id) |> json_normalize()
    }
  end

  defp republished_event_id(event_type, event_data, entry) do
    provider_hash =
      event_data
      |> source_message_ids()
      |> Jason.encode!()
      |> BullX.Ext.generic_hash()

    content_hash =
      event_data
      |> content_blocks()
      |> Jason.encode!()
      |> BullX.Ext.generic_hash()

    "message_revision:#{entry.id}:#{event_type}:#{provider_hash}:#{content_hash}"
  end

  defp put_caller_principal(event_data, nil), do: event_data

  defp put_caller_principal(event_data, caller_principal_id)
       when is_binary(caller_principal_id) do
    actor =
      event_data
      |> map_value("actor")
      |> case do
        %{"principal" => %{"id" => id}} = actor when is_binary(id) and id != "" ->
          actor

        %{} = actor ->
          Map.put(actor, "principal", %{"id" => caller_principal_id, "type" => "human"})

        _actor ->
          %{
            "external_account_id" => nil,
            "display_name" => nil,
            "principal" => %{"id" => caller_principal_id, "type" => "human"}
          }
      end

    put_map_value(event_data, "actor", actor)
  end

  defp update_content(%Message{} = target, content, event_data) do
    metadata =
      target.metadata
      |> Map.merge(provider_ref_metadata(event_data))
      |> Map.delete("brief")
      |> Map.delete("brief_usage")

    Conversations.update_message(target, %{content: content, metadata: metadata})
  end

  defp append_target_marker(%Message{} = target) do
    Conversations.update_message(target, %{content: append_marker_once(target.content, target)})
  end

  defp append_revision_message(conversation, invocation, entry, role, kind, text, opts \\ []) do
    metadata =
      revision_metadata(entry, opts)

    Conversations.append_message(conversation, %{
      conversation_id: conversation.id,
      role: role,
      kind: kind,
      status: :complete,
      content: [Message.text_block(text)],
      mailbox_session_id: Map.get(invocation, :mailbox_session_id),
      event_source: Map.get(entry, :event_source),
      event_id: Map.get(entry, :event_id),
      metadata: metadata
    })
  end

  defp revision_metadata(entry, opts) do
    base =
      %{
        "message_revision" => %{
          "source_event_id" => Map.get(entry, :event_id),
          "source_mailbox_entry_id" => Map.get(entry, :id)
        }
      }

    case Keyword.get(opts, :scene_metadata) do
      %{"scene" => scene} = source ->
        base
        |> Map.put("scene", scene)
        |> Map.put("actor", %{"display_name" => "BullX", "external_account_id_present" => false})
        |> Map.put("time_awareness", %{
          "send_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
          "injected" => false
        })
        |> maybe_put_conversation_key_parts(source)

      _source ->
        base
    end
  end

  defp maybe_put_conversation_key_parts(metadata, %{"conversation_key_parts" => parts}),
    do: Map.put(metadata, "conversation_key_parts", parts)

  defp maybe_put_conversation_key_parts(metadata, _source), do: metadata

  defp latest_addressed_with_output?(conversation, target) do
    latest_addressed_turn?(conversation, target) and
      (assistant_for_trigger?(target.id) or
         active_generation_for_trigger?(conversation, target.id))
  end

  defp latest_addressed_turn?(conversation, target) do
    conversation
    |> Conversations.active_branch()
    |> Enum.reverse()
    |> Enum.find(fn
      %Message{role: :user, kind: :normal} -> true
      _message -> false
    end)
    |> case do
      %Message{id: id} -> id == target.id
      nil -> false
    end
  end

  defp latest_ambient_turn?(conversation, target) do
    conversation
    |> Conversations.active_branch()
    |> List.last()
    |> case do
      %Message{id: id} -> id == target.id
      nil -> false
    end
  end

  defp assistant_for_trigger?(target_message_id) do
    Message
    |> where([m], m.role == :assistant)
    |> where([m], m.kind == :normal)
    |> where([m], m.status in [:generating, :complete])
    |> where(
      [m],
      fragment("?->'generation'->>'trigger_message_id' = ?", m.metadata, ^target_message_id)
    )
    |> where([m], is_nil(fragment("?->'branch_effect'", m.metadata)))
    |> Repo.exists?()
  end

  defp active_generation_for_trigger?(conversation, target_message_id) do
    generation = conversation.generation || %{}

    generation["trigger_message_id"] == target_message_id and
      Conversations.owned_active_lease?(
        conversation,
        generation["lease_id"] || "",
        DateTime.utc_now(:microsecond)
      )
  end

  defp maybe_cancel_generation(conversation, target_message_id, reason, now) do
    case active_generation_for_trigger?(conversation, target_message_id) do
      true -> Conversations.cancel_generation(conversation, reason, now)
      false -> {:ok, conversation}
    end
  end

  defp suffix_from(branch, target) do
    Enum.drop_while(branch, &(&1.id != target.id))
  end

  defp mark_suffix(messages, state, reason, entry_id, now) do
    messages
    |> Enum.reduce_while(:ok, fn message, :ok ->
      case mark_message(message, state, reason, entry_id, now) do
        {:ok, _message} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mark_message(
         %Message{role: :assistant, kind: :normal, status: :generating} = message,
         _state,
         reason,
         entry_id,
         now
       ) do
    metadata =
      message.metadata
      |> put_branch_effect("interrupted", reason, entry_id, now)
      |> put_in(["stream", "status"], "interrupted")

    Conversations.update_message(message, %{
      role: :assistant,
      kind: :error,
      status: :complete,
      content: [
        Message.error_block("generation_interrupted", "AIAgent generation interrupted.", true)
      ],
      metadata: metadata
    })
  end

  defp mark_message(%Message{} = message, state, reason, entry_id, now) do
    metadata = put_branch_effect(message.metadata, state, reason, entry_id, now)
    Conversations.update_message(message, %{metadata: metadata})
  end

  defp put_branch_effect(metadata, state, reason, entry_id, now) do
    Map.put(metadata, "branch_effect", %{
      "state" => state,
      "reason" => reason,
      "source_mailbox_entry_id" => entry_id,
      "at" => DateTime.to_iso8601(now)
    })
  end

  defp later_ambient_introspection?(target) do
    Message
    |> where([m], m.conversation_id == ^target.conversation_id)
    |> where([m], m.role == :im_ambient)
    |> where([m], m.kind == :introspection)
    |> where([m], m.inserted_at > ^target.inserted_at)
    |> Repo.exists?()
  end

  defp delete_message_and_rewire(conversation, target) do
    children =
      Message
      |> where([m], m.conversation_id == ^conversation.id)
      |> where([m], m.parent_id == ^target.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    with :ok <- reparent_children(children, target.parent_id),
         {:ok, _conversation} <- maybe_move_leaf_before_delete(conversation, target),
         {:ok, _target} <- Repo.delete(target) do
      :ok
    end
  end

  defp reparent_children(children, parent_id) do
    children
    |> Enum.reduce_while(:ok, fn child, :ok ->
      case Conversations.update_message(child, %{parent_id: parent_id}) do
        {:ok, _message} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_move_leaf_before_delete(
         %Conversation{current_leaf_message_id: target_id} = conversation,
         %Message{id: target_id} = target
       ),
       do: Conversations.set_current_leaf(conversation, target.parent_id)

  defp maybe_move_leaf_before_delete(conversation, _target), do: {:ok, conversation}

  defp historical_edit_notice(target, event_data) do
    "<btw>之前对话里 inserted_at is #{inserted_at_label(target)} 的消息被编辑为：#{new_text_preview(event_data)}</btw>"
  end

  defp historical_recall_notice(target) do
    "<btw>之前对话里 inserted_at is #{inserted_at_label(target)} 的消息已被撤回</btw>"
  end

  defp inserted_at_marker(target) do
    Message.text_block("<btw>This message inserted_at is #{inserted_at_label(target)}</btw>")
  end

  defp inserted_at_label(target), do: Time.format(target.inserted_at, "%m-%d %H:%M:%S", nil)

  defp new_text_preview(event_data) do
    event_data
    |> Event.text_content()
    |> String.trim()
    |> case do
      "" -> "[empty]"
      text -> String.slice(text, 0, @preview_chars)
    end
  end

  defp append_marker_once(content, target) when is_list(content) do
    marker = inserted_at_marker(target)

    case Enum.any?(content, &(&1 == marker)) do
      true -> content
      false -> content ++ [marker]
    end
  end

  defp append_marker_once(_content, target), do: [inserted_at_marker(target)]

  defp content_blocks(event_data) do
    case Event.transcript_texts(event_data) do
      [] -> [%{"type" => "omitted_marker", "reason" => "empty_normalized_content"}]
      texts -> Enum.map(texts, &Message.text_block/1)
    end
  end

  defp lane_for_event_data(event_data) do
    facts = map_value(event_data, "routing_facts")
    reason = safe_string(map_value(facts, "attention_reason"))
    listen_mode = safe_string(map_value(facts, "im_listen_mode"))
    channel_kind = event_data |> map_value("channel") |> map_value("kind") |> safe_string()

    cond do
      reason in @addressed_reasons -> :addressed
      is_binary(map_value(facts, "command_name")) -> :addressed
      channel_kind == "dm" -> :addressed
      reason == "unaddressed" and listen_mode == "all_messages" -> :ambient
      reason == "unaddressed" -> :ignored
      true -> :ignored
    end
  end

  defp batch_ref(conversation, target) do
    %{
      agent_principal_id: conversation.agent_principal_id,
      conversation_id: conversation.id,
      message_id: target.id
    }
  end

  defp empty_effects do
    %{
      recall_targets: [],
      republish_lane: nil,
      batch_update: nil,
      batch_remove: nil
    }
  end

  defp lock_conversation!(conversation_id) do
    Conversation
    |> where([c], c.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> Repo.one!()
  end

  defp lock_message(message_id) do
    Message
    |> where([m], m.id == ^message_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp ref_message_ids(refs) when is_list(refs) do
    refs
    |> Enum.filter(&message_ref?/1)
    |> Enum.map(&map_value(&1, "id"))
  end

  defp ref_message_ids(_refs), do: []

  defp message_ref?(ref) when is_map(ref) do
    ref
    |> map_value("kind")
    |> safe_string()
    |> String.contains?("message")
  end

  defp message_ref?(_ref), do: false

  defp raw_ref_message_ids(%{} = raw_ref) do
    [
      map_value(raw_ref, "message_id"),
      map_value(raw_ref, "open_message_id")
    ]
  end

  defp raw_ref_message_ids(_raw_ref), do: []

  defp map_value(%{} = map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp map_value(_value, _key), do: nil

  defp put_map_value(%{} = map, key, value) do
    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, String.to_atom(key)) -> Map.put(map, String.to_atom(key), value)
      true -> Map.put(map, key, value)
    end
  rescue
    ArgumentError -> Map.put(map, key, value)
  end

  defp json_normalize(value) do
    value
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp reserve_revision_entry(%{id: id}) when is_binary(id) and id != "" do
    case Redis.command(["SET", revision_dedupe_key(id), "1", "PX", @revision_dedupe_ttl_ms, "NX"]) do
      {:ok, "OK"} -> :process
      {:ok, nil} -> :duplicate
      {:error, _reason} -> :process
    end
  end

  defp reserve_revision_entry(_entry), do: :process

  defp revision_dedupe_key(entry_id), do: "ai_agent:message_revision:entry:#{entry_id}"

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_string(_value), do: ""
end
