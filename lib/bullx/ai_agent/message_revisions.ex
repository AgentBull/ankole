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
  alias BullX.MailBox.Entry, as: MailboxEntry
  alias BullX.Principals.Principal
  alias BullX.Repo

  @addressed_reasons ~w(dm mention free_response command reply_to_bot application_command mention_text action batch_addressed)
  @preview_chars 500

  @type action :: :edited | :recalled | :deleted

  @spec handle(action(), map(), Principal.t(), map(), map(), String.t() | nil) ::
          :ok | {:error, term()}
  def handle(
        action,
        event_data,
        %Principal{} = principal,
        invocation,
        entry,
        caller_principal_uid
      )
      when action in [:edited, :recalled, :deleted] and is_map(event_data) and
             is_map(invocation) and is_map(entry) do
    event_data
    |> Event.source_message_ids()
    |> find_target_message(principal.uid, Map.get(entry, :event_source))
    |> case do
      %Message{} = target ->
        target
        |> revise_target(action, event_data, invocation, entry, caller_principal_uid)
        |> run_side_effects(event_data, invocation, entry, caller_principal_uid)

      nil ->
        :ok
    end
  end

  def handle(_action, _event_data, _principal, _invocation, _entry, _caller_principal_uid),
    do: :ok

  defp find_target_message([], _agent_uid, _event_source), do: nil

  defp find_target_message(target_ids, agent_uid, event_source) do
    target_set = MapSet.new(target_ids)

    agent_uid
    |> target_candidates(event_source)
    |> Enum.find_value(fn {message, cloud_event} ->
      case intersects?(target_set, message_source_ids(message, cloud_event)) do
        true -> message
        false -> nil
      end
    end)
  end

  defp target_candidates(agent_uid, event_source) do
    Message
    |> join(:inner, [m], c in Conversation, on: c.id == m.conversation_id)
    |> join(:left, [m, _c], e in MailboxEntry, on: e.id == m.mailbox_entry_id)
    |> where([m, c], c.agent_uid == ^agent_uid)
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
        %{"data" => data} -> Event.source_message_ids(data)
        _cloud_event -> []
      end

    (metadata_ids ++ event_ids)
    |> Enum.map(&safe_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp intersects?(target_set, ids), do: Enum.any?(ids, &MapSet.member?(target_set, &1))

  defp revise_target(target, action, event_data, invocation, entry, caller_principal_uid) do
    Repo.transaction(fn ->
      conversation = lock_conversation!(target.conversation_id)

      case lock_message(target.id) do
        %Message{conversation_id: conversation_id} = locked_target
        when conversation_id == conversation.id ->
          case revision_allowed?(locked_target, conversation, invocation) do
            true ->
              revise_locked(action, locked_target, conversation, event_data, invocation, entry)

            false ->
              empty_effects()
          end

        _missing ->
          Repo.rollback(:ignore)
      end
    end)
    |> case do
      {:ok, effects} -> {:ok, Map.put(effects, :caller_principal_uid, caller_principal_uid)}
      {:error, :ignore} -> {:ok, empty_effects()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revise_locked(
         :edited,
         %Message{role: :user, kind: :normal} = target,
         conversation,
         event_data,
         _invocation,
         entry
       ) do
    case batch_addressed_revision(:edited, target, conversation, event_data, entry) do
      :not_batch ->
        case latest_addressed_with_output?(conversation, target) do
          true -> latest_addressed_edit(target, conversation, event_data, entry)
          false -> historical_addressed_revision(:edited, target, conversation, event_data, entry)
        end

      effects ->
        effects
    end
  end

  defp revise_locked(
         action,
         %Message{role: :user, kind: :normal} = target,
         conversation,
         event_data,
         _invocation,
         entry
       )
       when action in [:recalled, :deleted] do
    case batch_addressed_revision(action, target, conversation, event_data, entry) do
      :not_batch ->
        case latest_addressed_with_output?(conversation, target) do
          true -> latest_addressed_remove(action, target, conversation, entry)
          false -> historical_addressed_revision(action, target, conversation, event_data, entry)
        end

      effects ->
        effects
    end
  end

  defp revise_locked(
         :edited,
         %Message{role: :im_ambient, kind: :normal} = target,
         conversation,
         event_data,
         _invocation,
         entry
       ) do
    case batch_ambient_revision(:edited, target, conversation, event_data, entry) do
      :not_batch ->
        case {lane_for_event_data(event_data), latest_ambient_turn?(conversation, target)} do
          {:addressed, true} ->
            latest_ambient_to_addressed_edit(target, conversation, event_data, entry)

          {:ambient, _latest} ->
            ambient_edit_by_old_lane(target, conversation, event_data)

          _other ->
            historical_ambient_revision(:edited, target, conversation, event_data, entry)
        end

      effects ->
        effects
    end
  end

  defp revise_locked(
         action,
         %Message{role: :im_ambient, kind: :normal} = target,
         conversation,
         event_data,
         _invocation,
         entry
       )
       when action in [:recalled, :deleted] do
    case batch_ambient_revision(action, target, conversation, event_data, entry) do
      :not_batch ->
        case later_ambient_introspection?(target) do
          false ->
            with :ok <- delete_message_and_rewire(conversation, target) do
              empty_effects()
              |> Map.put(:batch_remove, batch_ref(conversation, target))
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          true ->
            historical_ambient_revision(action, target, conversation, event_data, entry)
        end

      effects ->
        effects
    end
  end

  defp revise_locked(_action, _target, _conversation, _event_data, _invocation, _entry),
    do: empty_effects()

  defp batch_addressed_revision(action, target, conversation, event_data, entry) do
    with {:ok, revised_items} <- revise_batch_items(target, action, event_data) do
      case latest_addressed_with_output?(conversation, target) do
        true ->
          latest_addressed_batch_revision(
            action,
            target,
            conversation,
            revised_items,
            event_data,
            entry
          )

        false ->
          historical_addressed_revision(action, target, conversation, event_data, entry)
      end
    else
      :not_batch ->
        :not_batch

      :missing_item ->
        historical_addressed_revision(action, target, conversation, event_data, entry)
    end
  end

  defp batch_ambient_revision(action, target, conversation, event_data, entry) do
    with {:ok, revised_items} <- revise_batch_items(target, action, event_data) do
      lane = effective_batch_lane(revised_items)

      cond do
        action == :edited and lane == :addressed and latest_ambient_turn?(conversation, target) ->
          latest_ambient_batch_to_addressed(target, conversation, revised_items, event_data)

        later_ambient_introspection?(target) ->
          historical_ambient_revision(action, target, conversation, event_data, entry)

        lane == :empty ->
          with :ok <- delete_message_and_rewire(conversation, target) do
            empty_effects()
            |> Map.put(:batch_remove, batch_ref(conversation, target))
          else
            {:error, reason} -> Repo.rollback(reason)
          end

        lane == :ambient ->
          update_ambient_batch_message(target, conversation, revised_items, event_data)

        lane == :addressed ->
          latest_ambient_batch_to_addressed(target, conversation, revised_items, event_data)
      end
    else
      :not_batch ->
        :not_batch

      :missing_item ->
        historical_ambient_revision(action, target, conversation, event_data, entry)
    end
  end

  defp latest_addressed_batch_revision(
         action,
         target,
         conversation,
         revised_items,
         event_data,
         entry
       ) do
    now = DateTime.utc_now(:microsecond)
    lane = effective_batch_lane(revised_items)
    reason = "source_message_#{action}"

    with {:ok, conversation} <- maybe_cancel_generation(conversation, target.id, reason, now),
         branch <- Conversations.active_branch(conversation),
         suffix <- suffix_from(branch, target),
         recall_targets <- DeliveryRecall.targets_for_messages(suffix),
         :ok <- mark_suffix(suffix, batch_revision_state(action), reason, entry.id, now),
         {:ok, _conversation} <- Conversations.set_current_leaf(conversation, target.parent_id) do
      empty_effects()
      |> Map.put(:recall_targets, recall_targets)
      |> maybe_republish_revised_batch(lane, revised_items, event_data)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp latest_ambient_batch_to_addressed(target, conversation, revised_items, event_data) do
    with :ok <- delete_message_and_rewire(conversation, target) do
      empty_effects()
      |> Map.put(:batch_remove, batch_ref(conversation, target))
      |> maybe_republish_revised_batch(:addressed, revised_items, event_data)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_ambient_batch_message(target, conversation, revised_items, event_data) do
    content = batch_content_blocks(revised_items)
    revised_event_data = revised_batch_event_data(revised_items, event_data, :ambient)

    with {:ok, _target} <- update_content(target, content, revised_event_data) do
      empty_effects()
      |> Map.put(
        :batch_update,
        Map.put(batch_ref(conversation, target), :text, batch_text(revised_items))
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_republish_revised_batch(effects, :addressed, revised_items, event_data) do
    effects
    |> Map.put(:republish_lane, :addressed)
    |> Map.put(
      :republish_event_data,
      revised_batch_event_data(revised_items, event_data, :addressed)
    )
  end

  defp maybe_republish_revised_batch(effects, :ambient, revised_items, event_data) do
    case ambient_batch_republish_allowed?(revised_items, event_data) do
      true ->
        effects
        |> Map.put(:republish_lane, :ambient)
        |> Map.put(
          :republish_event_data,
          revised_batch_event_data(revised_items, event_data, :ambient)
        )

      false ->
        effects
    end
  end

  defp maybe_republish_revised_batch(effects, _lane, _revised_items, _event_data), do: effects

  defp ambient_batch_republish_allowed?(revised_items, event_data) do
    group_message_mode(event_data) == "engage_all" or
      Enum.any?(active_batch_items(revised_items), fn item ->
        mode =
          item
          |> Map.get("routing_facts")
          |> map_value("group_message_mode")
          |> safe_string()

        mode == "engage_all"
      end)
  end

  defp group_message_mode(event_data) do
    event_data
    |> map_value("routing_facts")
    |> map_value("group_message_mode")
    |> safe_string()
  end

  defp revise_batch_items(
         %Message{metadata: %{"im_batch" => %{"items" => items}}},
         action,
         event_data
       )
       when is_list(items) do
    target_ids = MapSet.new(Event.source_message_ids(event_data))

    case MapSet.size(target_ids) do
      0 ->
        :missing_item

      _size ->
        {revised_items, matched?} =
          Enum.map_reduce(items, false, fn item, matched? ->
            case batch_item_matches?(item, target_ids) do
              true -> {revise_batch_item(item, action, event_data), true}
              false -> {item, matched?}
            end
          end)

        case matched? do
          true -> {:ok, revised_items}
          false -> :missing_item
        end
    end
  end

  defp revise_batch_items(_target, _action, _event_data), do: :not_batch

  defp batch_item_matches?(%{} = item, target_ids) do
    item
    |> Map.get("provider_message_ids", [])
    |> List.wrap()
    |> Enum.any?(&MapSet.member?(target_ids, safe_string(&1)))
  end

  defp revise_batch_item(%{} = item, :edited, event_data) do
    item
    |> Map.put("state", "active")
    |> Map.put("attention", batch_item_attention(event_data))
    |> Map.put("text", Event.text_content(event_data))
    |> Map.put("content", content_blocks(event_data))
    |> Map.put("refs", map_value(event_data, "refs") || [])
    |> Map.put("raw_ref", map_value(event_data, "raw_ref"))
    |> Map.put("routing_facts", map_value(event_data, "routing_facts") || %{})
    |> Map.update("provider_message_ids", Event.source_message_ids(event_data), fn ids ->
      (List.wrap(ids) ++ Event.source_message_ids(event_data))
      |> Enum.map(&safe_string/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end)
  end

  defp revise_batch_item(%{} = item, action, _event_data) when action in [:recalled, :deleted] do
    item
    |> Map.put("state", Atom.to_string(action))
    |> Map.put("text", "")
    |> Map.put("content", [])
  end

  defp batch_item_attention(event_data) do
    case lane_for_event_data(event_data) do
      :addressed -> "addressed"
      :ambient -> "ambient"
      _lane -> "ignored"
    end
  end

  defp effective_batch_lane(items) do
    active = active_batch_items(items)

    cond do
      active == [] -> :empty
      Enum.any?(active, &(Map.get(&1, "attention") == "addressed")) -> :addressed
      Enum.any?(active, &(Map.get(&1, "attention") == "ambient")) -> :ambient
      true -> :empty
    end
  end

  defp active_batch_items(items), do: Enum.filter(items, &(Map.get(&1, "state") == "active"))

  defp deliverable_batch_items(items) do
    Enum.filter(
      active_batch_items(items),
      &(Map.get(&1, "attention") in ["addressed", "ambient"])
    )
  end

  defp revised_batch_event_data(revised_items, event_data, lane) do
    active = deliverable_batch_items(revised_items)

    event_data
    |> put_map_value("content", batch_content_blocks(revised_items))
    |> put_map_value("refs", Enum.flat_map(active, &(Map.get(&1, "refs") || [])) |> Enum.uniq())
    |> put_map_value("im_batch", %{
      "effective_attention" => Atom.to_string(lane),
      "items" => revised_items
    })
    |> put_map_value("routing_facts", revised_batch_routing_facts(event_data, lane))
  end

  defp revised_batch_routing_facts(event_data, lane) do
    event_data
    |> map_value("routing_facts")
    |> case do
      %{} = facts -> facts
      _facts -> %{}
    end
    |> Map.put("batch_effective_attention", Atom.to_string(lane))
    |> Map.put("attention_reason", revised_attention_reason(lane))
  end

  defp revised_attention_reason(:addressed), do: "batch_addressed"
  defp revised_attention_reason(_lane), do: "unaddressed"

  defp batch_content_blocks(revised_items) do
    case batch_text(revised_items) do
      "" -> [%{"type" => "omitted_marker", "reason" => "empty_normalized_content"}]
      text -> [Message.text_block(text)]
    end
  end

  defp batch_text(revised_items) do
    revised_items
    |> deliverable_batch_items()
    |> Enum.map(&(Map.get(&1, "text") || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp batch_revision_state(:edited), do: "superseded"

  defp batch_revision_state(action) when action in [:recalled, :deleted],
    do: Atom.to_string(action)

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

  defp latest_addressed_remove(action, target, conversation, entry) do
    now = DateTime.utc_now(:microsecond)
    state = Atom.to_string(action)
    reason = "source_message_#{state}"

    with {:ok, conversation} <- maybe_cancel_generation(conversation, target.id, reason, now),
         branch <- Conversations.active_branch(conversation),
         suffix <- suffix_from(branch, target),
         recall_targets <- DeliveryRecall.targets_for_messages(suffix),
         :ok <- mark_suffix(suffix, state, reason, entry.id, now),
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

  defp historical_addressed_revision(action, target, conversation, event_data, entry) do
    ref_id = revision_ref_id(target)

    with {:ok, _target} <- append_target_ref_marker(target, ref_id),
         {:ok, _conversation, _message} <-
           append_revision_message(
             conversation,
             entry,
             :user,
             :introspection,
             revision_notice(action, ref_id, event_data)
           ) do
      empty_effects()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ambient_edit_by_old_lane(target, conversation, event_data) do
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
        historical_ambient_revision(:edited, target, conversation, event_data, %{})
    end
  end

  defp historical_ambient_revision(action, target, conversation, event_data, entry) do
    ref_id = revision_ref_id(target)

    with {:ok, _target} <- append_target_ref_marker(target, ref_id),
         {:ok, _conversation, _message} <-
           append_revision_message(
             conversation,
             entry,
             :im_ambient,
             :normal,
             revision_notice(action, ref_id, event_data),
             scene_metadata: target.metadata
           ) do
      empty_effects()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp run_side_effects(
         {:error, reason},
         _event_data,
         _invocation,
         _entry,
         _caller_principal_uid
       ),
       do: {:error, reason}

  defp run_side_effects({:ok, effects}, event_data, invocation, entry, caller_principal_uid) do
    :ok = maybe_update_batch(effects)
    :ok = maybe_remove_from_batch(effects)
    :ok = maybe_recall_outputs(effects, event_data, entry)
    maybe_republish(effects, event_data, invocation, entry, caller_principal_uid)
  end

  defp maybe_update_batch(%{
         batch_update: %{
           agent_uid: agent,
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
           agent_uid: agent,
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
         %{republish_lane: lane} = effects,
         event_data,
         invocation,
         entry,
         caller_principal_uid
       )
       when lane in [:addressed, :ambient] do
    event_data = Map.get(effects, :republish_event_data) || event_data

    MailBox.deliver(%{
      cloud_event: republished_event(event_data, entry, caller_principal_uid),
      agent_uid: invocation.target_ref,
      attention: lane,
      session_key: Map.get(invocation, :mailbox_session_id),
      dedupe_key: "message_revision"
    })
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_republish(_effects, _event_data, _invocation, _entry, _caller_principal_uid), do: :ok

  defp republished_event(event_data, entry, caller_principal_uid) do
    base = Map.get(entry, :cloud_event) || %{}

    %{
      "specversion" => base["specversion"] || "1.0",
      "id" => republished_event_id(event_data, entry),
      "source" => base["source"] || entry.event_source,
      "type" => "bullx.message.received",
      "time" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
      "datacontenttype" => base["datacontenttype"] || "application/json",
      "subject" => base["subject"] || "bullx.message.received:#{entry.event_id}",
      "data" => event_data |> put_caller_principal(caller_principal_uid) |> json_normalize()
    }
  end

  defp republished_event_id(event_data, entry) do
    provider_hash =
      event_data
      |> Event.source_message_ids()
      |> Jason.encode!()
      |> BullX.Ext.generic_hash()

    content_hash =
      event_data
      |> content_blocks()
      |> Jason.encode!()
      |> BullX.Ext.generic_hash()

    "message_revision:#{entry.id}:bullx.message.received:#{provider_hash}:#{content_hash}"
  end

  defp revision_allowed?(%Message{} = target, %Conversation{} = conversation, invocation) do
    same_session?(target, invocation) and after_latest_compression?(target, conversation)
  end

  defp same_session?(%Message{mailbox_session_id: session_id}, %{mailbox_session_id: session_id})
       when is_binary(session_id),
       do: true

  defp same_session?(_target, _invocation), do: false

  defp after_latest_compression?(target, conversation) do
    conversation
    |> Conversations.render_branch()
    |> Enum.any?(&(&1.id == target.id))
  end

  defp update_content(%Message{} = target, content, event_data) do
    metadata =
      target.metadata
      |> Map.merge(Event.provider_ref_metadata(event_data))
      |> Map.delete("brief")
      |> Map.delete("brief_usage")

    Conversations.update_message(target, %{content: content, metadata: metadata})
  end

  defp append_target_ref_marker(%Message{} = target, ref_id) do
    metadata =
      target.metadata
      |> Map.put("revision_ref_id", ref_id)
      |> Map.update("revision_refs", [ref_id], fn refs ->
        [ref_id | List.wrap(refs)]
        |> Enum.uniq()
      end)

    Conversations.update_message(target, %{
      content: append_ref_marker_once(target.content, ref_id),
      metadata: metadata
    })
  end

  defp append_revision_message(conversation, entry, role, kind, text, opts \\ []) do
    metadata = revision_metadata(entry, opts)

    Conversations.append_message(conversation, %{
      conversation_id: conversation.id,
      role: role,
      kind: kind,
      status: :complete,
      content: [Message.text_block(text)],
      mailbox_session_id: Map.get(entry, :mailbox_session_id),
      mailbox_entry_id: Map.get(entry, :id),
      event_source: Map.get(entry, :event_source),
      event_id: Map.get(entry, :event_id),
      metadata: metadata
    })
  end

  defp revision_metadata(entry, opts) do
    base = %{
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

  defp suffix_from(branch, target), do: Enum.drop_while(branch, &(&1.id != target.id))

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

  defp revision_notice(:edited, ref_id, event_data) do
    "<btw>ref id #{ref_id} 的消息被编辑为：#{new_text_preview(event_data)}</btw>"
  end

  defp revision_notice(:recalled, ref_id, _event_data) do
    "<btw>ref id #{ref_id} 的消息已被撤回</btw>"
  end

  defp revision_notice(:deleted, ref_id, _event_data) do
    "<btw>ref id #{ref_id} 的消息已被删除</btw>"
  end

  defp new_text_preview(event_data) do
    event_data
    |> Event.text_content()
    |> String.trim()
    |> case do
      "" -> "[empty]"
      text -> String.slice(text, 0, @preview_chars)
    end
  end

  defp append_ref_marker_once(content, ref_id) when is_list(content) do
    marker = Message.text_block("<btw>ref id: #{ref_id}</btw>")

    case Enum.any?(content, &(&1 == marker)) do
      true -> content
      false -> content ++ [marker]
    end
  end

  defp append_ref_marker_once(_content, ref_id),
    do: [Message.text_block("<btw>ref id: #{ref_id}</btw>")]

  defp revision_ref_id(%Message{metadata: %{"revision_ref_id" => ref_id}})
       when is_binary(ref_id) and ref_id != "",
       do: ref_id

  defp revision_ref_id(%Message{id: id, inserted_at: inserted_at}) do
    timestamp =
      inserted_at
      |> Time.format("%m%d%H%M%S", nil)
      |> String.replace(~r/[^0-9]/, "")

    "msg-#{timestamp}-#{String.slice(id, -6, 6)}"
  end

  defp content_blocks(event_data) do
    case Event.transcript_texts(event_data) do
      [] -> [%{"type" => "omitted_marker", "reason" => "empty_normalized_content"}]
      texts -> Enum.map(texts, &Message.text_block/1)
    end
  end

  defp lane_for_event_data(event_data) do
    facts = map_value(event_data, "routing_facts")
    reason = safe_string(map_value(facts, "attention_reason"))
    group_message_mode = safe_string(map_value(facts, "group_message_mode"))
    channel_kind = event_data |> map_value("channel") |> map_value("kind") |> safe_string()

    cond do
      reason in @addressed_reasons -> :addressed
      is_binary(map_value(facts, "command_name")) -> :addressed
      channel_kind == "dm" -> :addressed
      reason == "unaddressed" and group_message_mode in ["observe_all", "engage_all"] -> :ambient
      reason == "unaddressed" -> :ignored
      true -> :ignored
    end
  end

  defp batch_ref(conversation, target) do
    %{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      message_id: target.id
    }
  end

  defp empty_effects do
    %{
      recall_targets: [],
      republish_lane: nil,
      republish_event_data: nil,
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

  defp put_caller_principal(event_data, nil), do: event_data

  defp put_caller_principal(event_data, caller_principal_uid)
       when is_binary(caller_principal_uid) do
    actor =
      event_data
      |> map_value("actor")
      |> case do
        %{"principal" => %{"uid" => uid}} = actor when is_binary(uid) and uid != "" ->
          actor

        %{} = actor ->
          Map.put(actor, "principal", %{"uid" => caller_principal_uid, "type" => "human"})

        _actor ->
          %{
            "external_account_id" => nil,
            "display_name" => nil,
            "principal" => %{"uid" => caller_principal_uid, "type" => "human"}
          }
      end

    put_map_value(event_data, "actor", actor)
  end

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

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_string(_value), do: ""
end
