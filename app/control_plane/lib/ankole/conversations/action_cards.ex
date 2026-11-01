defmodule Ankole.Conversations.ActionCards do
  @moduledoc """
  Drafts, authorizes, and executes privilege-escalated Action Cards across
  Pod native rooms and external messaging channels.
  """

  require Ash.Query

  alias Ankole.{AuthZ, Logging, Principals, Repo, Signals}
  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations
  alias Ankole.Conversations.{ActionCard, Conversation, Native, NativeRoom, Queries}

  alias Ankole.Conversations.Delivery

  alias Ankole.Conversations.Delivery.{
    ActionCardPrompt,
    Adapter,
    InteractionState,
    PreviewAdapter,
    PreviewStates
  }

  alias Ankole.Files
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Pod.{Bases, BaseTable, Page, Pages}
  alias Ankole.Pod.Pages.Sharing
  alias Ankole.Signals.{Adapters, Binding, Signal}

  @wakeup_signal_type "conversation.action_card.executed"

  def wakeup_signal_type, do: @wakeup_signal_type

  def action_card_interaction_id?(interaction_id) when is_binary(interaction_id) do
    String.starts_with?(interaction_id, "action_card:") or
      match?([_, "action_card:" <> _], String.split(interaction_id, ":", parts: 2))
  end

  def action_card_interaction_id?(_interaction_id), do: false

  @doc """
  Validates an Agent's `propose_action_card` tool call, verifies read visibility,
  and snapshots CAS preconditions without mutating domain state.
  """
  def prepare_draft(run, _call, args) when is_map(args) do
    with conversation_id when is_binary(conversation_id) <- run.event.conversation_id,
         {:ok, %Conversation{} = conversation} <- Conversations.get_conversation(conversation_id),
         {:ok, summary} <- ActionCardPrompt.sanitize_summary(Map.get(args, "summary")),
         {:ok, %{type: :agent, status: :active} = agent_principal} <-
           Principals.get_principal(run.agent_uid),
         agent_actor = Actor.new(agent_principal),
         {:ok, target_node_id, payload, preconditions} <-
           draft_action(agent_actor, conversation, Map.get(args, "action_kind"), args) do
      card_id = Ankole.Ecto.UUIDv7.autogenerate()

      {:ok,
       %{
         "tool" => "propose_action_card",
         "ok" => true,
         "card_id" => card_id,
         "action_kind" => Map.get(args, "action_kind"),
         "summary" => summary,
         "target_node_id" => target_node_id,
         "payload" => payload,
         "preconditions" => preconditions
       }}
    else
      nil ->
        {:error, "propose_action_card requires an active conversation."}

      {:ok, nil} ->
        {:error, "Conversation not found."}

      {:error, :invalid_summary} ->
        {:error, "summary must be 1..500 visible characters."}

      {:error, :not_found} ->
        {:error, "Target resource was not found or is not visible to this Agent."}

      {:error, :forbidden} ->
        {:error,
         "Agent must have view access to the target resource before proposing an action card."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp draft_action(agent_actor, _conversation, "pod.page.set_sharing", args) do
    node_id = Map.get(args, "node_id")
    inherit_permissions = Map.get(args, "inherit_permissions", :unchanged)
    grants = Map.get(args, "grants", :unchanged)

    cond do
      inherit_permissions == :unchanged and grants == :unchanged ->
        {:error, "pod.page.set_sharing requires inherit_permissions and/or grants."}

      inherit_permissions != :unchanged and not is_boolean(inherit_permissions) ->
        {:error, "inherit_permissions must be a boolean."}

      grants != :unchanged and not is_list(grants) ->
        {:error, "grants must be an array of grant objects."}

      true ->
        with {:ok, node_id} <- cast_uuid(node_id, "node_id"),
             {:ok, sharing} <- Sharing.sharing(agent_actor, node_id),
             {:ok, page} <- Pages.fetch(node_id) do
          payload =
            %{
              "node_id" => page.id,
              "node_title" => page.title
            }
            |> maybe_put_unchanged("inherit_permissions", inherit_permissions)
            |> maybe_put_unchanged("grants", normalize_grant_items(grants))

          preconditions = %{
            "node_id" => page.id,
            "expected_sharing_version" => sharing.sharing_version
          }

          {:ok, page.id, payload, preconditions}
        end
    end
  end

  defp draft_action(agent_actor, _conversation, "pod.page.delete", args) do
    with {:ok, node_id} <- cast_uuid(Map.get(args, "node_id"), "node_id"),
         {:ok, %Page{} = page} <- Pages.authorize(agent_actor, node_id, "node_view") do
      if is_nil(page.deleted_at) do
        payload = %{
          "node_id" => page.id,
          "node_title" => page.title,
          "node_type" => to_string(page.type)
        }

        preconditions = %{
          "node_id" => page.id,
          "expected_updated_at" => DateTime.to_iso8601(page.updated_at),
          "expected_deleted" => false,
          "expected_revision" => page.revision
        }

        {:ok, page.id, payload, preconditions}
      else
        {:error, "Target node is already in trash."}
      end
    end
  end

  defp draft_action(agent_actor, _conversation, "pod.page.restore", args) do
    with {:ok, node_id} <- cast_uuid(Map.get(args, "node_id"), "node_id"),
         {:ok, %Page{} = page} <-
           Repo.transact_top_level(fn ->
             with {:ok, page} <- Pages.fetch(node_id),
                  {:ok, _} <- Access.authorize(agent_actor, page, "node_view", trash: true) do
               {:ok, page}
             end
           end) do
      if not is_nil(page.deleted_at) do
        payload = %{
          "node_id" => page.id,
          "node_title" => page.title,
          "node_type" => to_string(page.type)
        }

        preconditions = %{
          "node_id" => page.id,
          "expected_updated_at" => DateTime.to_iso8601(page.updated_at),
          "expected_deleted" => true,
          "expected_revision" => page.revision
        }

        {:ok, page.id, payload, preconditions}
      else
        {:error, "Target node is not in trash."}
      end
    end
  end

  defp draft_action(agent_actor, _conversation, "pod.base.delete_table", args) do
    with {:ok, table_id} <- cast_uuid(Map.get(args, "table_id"), "table_id"),
         {:ok, {%BaseTable{} = table, %Page{} = page}} <-
           Repo.transact_top_level(fn ->
             with {:ok, table} <- Bases.fetch_table(table_id),
                  {:ok, _} <- Bases.table_access(agent_actor, table, :read),
                  {:ok, page} <- Pages.fetch(table.page_id) do
               {:ok, {table, page}}
             end
           end),
         :ok <- verify_optional_page_id(Map.get(args, "page_id"), table.page_id) do
      payload = %{
        "page_id" => table.page_id,
        "page_title" => page.title,
        "table_id" => table.id,
        "table_name" => table.name
      }

      preconditions = %{
        "page_id" => table.page_id,
        "table_id" => table.id,
        "expected_name" => table.name,
        "expected_schema_version" => table.schema_version,
        "expected_data_version" => table.data_version,
        "expected_updated_at" => DateTime.to_iso8601(page.updated_at)
      }

      {:ok, table.page_id, payload, preconditions}
    end
  end

  defp draft_action(
         _agent_actor,
         %Conversation{kind: kind},
         "conversation.add_participants",
         _args
       )
       when kind != :native do
    {:error,
     "conversation.add_participants is only supported in Pod native rooms, not external IM channels."}
  end

  defp draft_action(
         _agent_actor,
         %Conversation{kind: :native} = conversation,
         "conversation.add_participants",
         args
       ) do
    raw_uids = Map.get(args, "participant_uids")

    if is_list(raw_uids) and raw_uids != [] do
      uids =
        raw_uids
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()

      if uids == [] do
        {:error, "participant_uids must contain at least one Principal UID."}
      else
        Enum.reduce_while(uids, {:ok, []}, fn uid, {:ok, acc} ->
          case Principals.get_principal(uid) do
            {:ok, %{status: :active, type: type} = principal} when type in [:human, :agent] ->
              {:cont,
               {:ok,
                [
                  %{
                    "uid" => principal.uid,
                    "name" => NativeRoom.display_name(principal),
                    "type" => to_string(principal.type)
                  }
                  | acc
                ]}}

            _ ->
              {:halt, {:error, "Principal #{uid} is unavailable."}}
          end
        end)
        |> case do
          {:ok, participants} ->
            participants = Enum.reverse(participants)

            payload = %{
              "conversation_id" => conversation.id,
              "participant_uids" => uids,
              "participants" => participants
            }

            preconditions = %{"conversation_id" => conversation.id}
            {:ok, nil, payload, preconditions}

          error ->
            error
        end
      end
    else
      {:error, "participant_uids must be a non-empty array of Principal UIDs."}
    end
  end

  defp draft_action(_agent_actor, _conversation, kind, _args) do
    {:error, "Unsupported action_kind: #{inspect(kind)}"}
  end

  @doc "Persists a prepared ActionCard row inside the turn-completion transaction."
  def commit_prepared_in_tx(%Signal{} = event, conversation_id, prompt) when is_map(prompt) do
    Ankole.Ash.create(ActionCard, :prepare_in_tx, %{
      id: prompt["card_id"],
      conversation_id: conversation_id,
      session_id: event.session_id,
      agent_uid: event.agent_uid,
      source_signal_id: event.id,
      interaction_id: prompt["interaction_id"],
      action_kind: prompt["action_kind"],
      summary: prompt["summary"],
      target_node_id: prompt["target_node_id"],
      payload: prompt["payload"] || %{},
      preconditions: prompt["preconditions"] || %{}
    })
  end

  @doc "Classifies an external binding into Tier 1 (in-place refresh), Tier 2 (append receipt), or Tier 3 (non-interactive)."
  def channel_tier(%Binding{} = binding) do
    cond do
      binding.adapter == "email" ->
        :tier3

      match?(
        %PreviewAdapter{refresh_fun: fun} when is_function(fun, 1),
        PreviewAdapter.for_binding(binding)
      ) ->
        :tier1

      true ->
        case Adapters.fetch_delivery(binding.adapter) do
          {:ok, delivery_adapter} ->
            if MapSet.member?(Adapter.capabilities(delivery_adapter), :card),
              do: :tier2,
              else: :tier3

          {:error, {:signal_adapter_not_found, _}} ->
            :tier2

          _ ->
            :tier3
        end
    end
  end

  @doc "Returns the subset of conversation IDs that have at least one prepared Action Card."
  def prepared_conversation_ids([]), do: MapSet.new()

  def prepared_conversation_ids(conversation_ids) when is_list(conversation_ids) do
    ActionCard
    |> Ash.Query.filter(conversation_id in ^conversation_ids and status == :prepared)
    |> Ash.Query.select([:conversation_id])
    |> Ankole.Ash.read!()
    |> MapSet.new(& &1.conversation_id)
  end

  @doc "Locks prepared Action Cards belonging to candidate Signals in canonical row order before Signal locks."
  def lock_prepared_for_signals_in_tx([]), do: []

  def lock_prepared_for_signals_in_tx(signal_ids) when is_list(signal_ids) do
    ActionCard
    |> Ash.Query.filter(source_signal_id in ^signal_ids and status == :prepared)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "conversation_action_cards", :id})
  end

  @doc "Marks pre-locked prepared Action Cards cancelled when their source Signal entry was removed."
  def cancel_locked_for_signals_in_tx([], _superseded_signal_ids, _now), do: :ok
  def cancel_locked_for_signals_in_tx(_locked_cards, [], _now), do: :ok

  def cancel_locked_for_signals_in_tx(locked_cards, superseded_signal_ids, %DateTime{} = now)
      when is_list(locked_cards) and is_list(superseded_signal_ids) do
    superseded_set = MapSet.new(superseded_signal_ids)

    Enum.reduce_while(locked_cards, :ok, fn %ActionCard{} = card, :ok ->
      if card.status == :prepared and MapSet.member?(superseded_set, card.source_signal_id) do
        case Ankole.Ash.update(card, :resolve_in_tx, %{
               status: :cancelled,
               resolved_by_uid: nil,
               resolved_by_name: nil,
               resolved_at: now,
               resolution_note: "Source message was removed."
             }) do
          {:ok, _updated} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  @doc "Loads durable ActionCard projections for a list of Native messages."
  def native_cards(messages) when is_list(messages) do
    card_ids =
      messages
      |> Enum.map(&get_in(&1.rich_content || %{}, ["action_card", "card_id"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if card_ids == [] do
      %{}
    else
      cards =
        ActionCard
        |> Ash.Query.filter(id in ^card_ids)
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1})

      Map.new(messages, fn message ->
        card_id = get_in(message.rich_content || %{}, ["action_card", "card_id"])

        case card_id && Map.get(cards, card_id) do
          %ActionCard{} = card ->
            {message.id, client_card_state(card)}

          nil ->
            {message.id, %{}}
        end
      end)
    end
  end

  def client_card_state(%ActionCard{} = card) do
    %{
      "card_id" => card.id,
      "interaction_id" => card.source_signal_id <> ":" <> card.interaction_id,
      "action_kind" => card.action_kind,
      "summary" => card.summary,
      "target_node_id" => card.target_node_id,
      "payload" => card.payload,
      "status" => to_string(card.status),
      "resolved_by_uid" => card.resolved_by_uid,
      "resolved_by_name" => card.resolved_by_name,
      "resolved_at" => card.resolved_at && DateTime.to_iso8601(card.resolved_at),
      "resolution_note" => card.resolution_note
    }
  end

  def browser_card_state(%ActionCard{} = card, %Conversation{} = conversation) do
    card
    |> client_card_state()
    |> Map.merge(%{
      "conversation_id" => card.conversation_id,
      "conversation_kind" => to_string(conversation.kind),
      "agent_uid" => card.agent_uid
    })
  end

  @doc "Reads a standalone Action Card for Pod WebUI approval (`?actionCard=<id>`)."
  def get_browser_card(%Actor{} = actor, card_id) do
    human_actor = %{actor | turn_authority: nil}

    with {:ok, card_id} <- cast_uuid(card_id, "card_id"),
         %ActionCard{} = card <- get_card(card_id),
         {:ok, %Conversation{} = conversation} <-
           Conversations.get_conversation(card.conversation_id),
         :ok <- authorize_browser_card_view(human_actor, conversation, card) do
      {:ok, browser_card_state(card, conversation)}
    else
      {:ok, nil} -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc "Confirms or cancels a standalone Action Card from Pod WebUI (`?actionCard=<id>`)."
  def resolve_browser_card(%Actor{} = actor, card_id, decision)
      when decision in [:confirm, :cancel, "confirm", "cancel"] do
    decision = if to_string(decision) == "confirm", do: :confirm, else: :cancel
    human_actor = %{actor | turn_authority: nil}

    with {:ok, outcome} <-
           Repo.transact_top_level(
             fn -> resolve_browser_card_in_tx(human_actor, card_id, decision) end,
             after_commit: &__MODULE__.publish_after_commit/1
           ) do
      {:ok, browser_card_state(outcome.card, outcome.conversation)}
    end
  end

  @doc false
  def resolve_browser_card_in_tx(%Actor{} = actor, card_id, decision)
      when decision in [:confirm, :cancel] do
    now = DateTime.utc_now(:microsecond)

    with {:ok, card_id} <- cast_uuid(card_id, "card_id"),
         :ok <- Files.lock_tree_in_tx(),
         %ActionCard{} = snapshot <- get_card(card_id),
         {:ok, %Conversation{} = initial_conversation} <-
           Conversations.get_conversation(snapshot.conversation_id) do
      case initial_conversation.kind do
        :native ->
          resolve_native_after_tree_lock_in_tx(
            actor,
            initial_conversation.id,
            snapshot,
            decision,
            now
          )

        :external ->
          resolve_external_browser_in_tx(actor, initial_conversation, snapshot, decision, now)
      end
    else
      {:ok, nil} -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc "Confirms or cancels a Native room Action Card and returns updated conversation detail."
  def resolve_native(%Actor{} = actor, conversation_id, card_id, decision)
      when decision in [:confirm, :cancel, "confirm", "cancel"] do
    decision = if to_string(decision) == "confirm", do: :confirm, else: :cancel
    human_actor = %{actor | turn_authority: nil}

    with {:ok, outcome} <-
           Repo.transact_top_level(
             fn -> resolve_native_in_tx(human_actor, conversation_id, card_id, decision) end,
             after_commit: &__MODULE__.publish_after_commit/1
           ) do
      Conversations.get(human_actor, outcome.conversation_id)
    end
  end

  @doc false
  def resolve_native_in_tx(%Actor{} = actor, conversation_id, card_id, decision)
      when decision in [:confirm, :cancel] do
    now = DateTime.utc_now(:microsecond)

    with {:ok, conversation_id} <- Queries.cast_id(conversation_id),
         {:ok, card_id} <- cast_uuid(card_id, "card_id"),
         :ok <- Files.lock_tree_in_tx(),
         %ActionCard{conversation_id: ^conversation_id} = snapshot <- get_card(card_id) do
      resolve_native_after_tree_lock_in_tx(actor, conversation_id, snapshot, decision, now)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp resolve_native_after_tree_lock_in_tx(actor, conversation_id, snapshot, decision, now) do
    with :ok <- lock_target_roots_in_tx(snapshot),
         %Conversation{kind: :native} = visible <-
           Native.visible_conversation(actor, conversation_id),
         :ok <- lock_resolution_principals_in_tx(Actor.uid(actor), snapshot, visible),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx([
             {snapshot.agent_uid, snapshot.session_id},
             {snapshot.agent_uid, Ankole.Sessions.Key.conversation(conversation_id)}
           ]),
         %Conversation{} = conversation <-
           Native.visible_conversation(actor, conversation_id, lock: true),
         %ActionCard{} = card <- lock_card_in_tx(snapshot.id),
         %Signal{} = source <- Signals.lock_signal_in_tx(card.source_signal_id) do
      if card.status != :prepared do
        {:ok,
         %{
           conversation_id: conversation.id,
           conversation: conversation,
           card: card,
           side_effects: []
         }}
      else
        with {:ok, outcome} <-
               execute_resolution_in_tx(
                 actor,
                 conversation,
                 card,
                 source,
                 decision,
                 :native,
                 nil,
                 now
               ) do
          {:ok, Map.put(outcome, :conversation, conversation)}
        end
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp resolve_external_browser_in_tx(actor, initial_conversation, snapshot, decision, now) do
    with :ok <- lock_target_roots_in_tx(snapshot),
         :ok <- authorize_browser_card_view(actor, initial_conversation, snapshot),
         :ok <- lock_resolution_principals_in_tx(Actor.uid(actor), snapshot, initial_conversation),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx([
             {snapshot.agent_uid, snapshot.session_id}
           ]),
         %Conversation{} = conversation <- Queries.lock_conversation(initial_conversation.id),
         %ActionCard{} = card <- lock_card_in_tx(snapshot.id),
         %Signal{} = source <- Signals.lock_signal_in_tx(card.source_signal_id) do
      if card.status != :prepared do
        {:ok,
         %{
           conversation_id: conversation.id,
           conversation: conversation,
           card: card,
           side_effects: []
         }}
      else
        {tier, external_ctx} = browser_external_channel_context(actor, conversation, card, source)

        with {:ok, outcome} <-
               execute_resolution_in_tx(
                 actor,
                 conversation,
                 card,
                 source,
                 decision,
                 tier,
                 external_ctx,
                 now
               ) do
          {:ok, Map.put(outcome, :conversation, conversation)}
        end
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp browser_external_channel_context(actor, conversation, _card, source) do
    binding =
      if is_binary(source.reply_binding_name) do
        case Signals.get_binding(source.reply_binding_id) do
          {:ok, %Binding{} = found} -> found
          _ -> nil
        end
      end

    tier = if binding, do: channel_tier(binding), else: :tier3

    fact = %{
      binding_id: source.reply_binding_id,
      binding_name: source.reply_binding_name,
      conversation_id: conversation.id,
      provider_thread_id: source.provider_thread_id,
      provider_message_id: PreviewStates.get(source).provider_message_id
    }

    {tier, {fact, Actor.uid(actor)}}
  end

  @doc """
  Handles an external IM `action_event` targeting an `action_card:*` interaction
  inside `Observe.accept_action_in_tx` (caller already holds Rank 2 `drive-tree`).
  """
  def accept_external_in_tx(%Binding{} = binding, fact, channel, now) do
    value = get_in(fact.action || %{}, ["value"]) || %{}
    interaction_id = Map.get(value, "interactionId")
    source_signal_id = Map.get(value, "sourceSignalId")
    option_id = Map.get(value, "selectedOptionId") || Map.get(value, "optionValue")
    operator_uid = get_in(fact.action || %{}, ["operator_principal_uid"])
    operator_id = get_in(fact.action || %{}, ["operator_id"])
    sender_key = non_empty_string(operator_uid) || non_empty_string(operator_id) || "unknown"
    tier = channel_tier(binding)

    with {:ok, source_signal_id} <- cast_uuid(source_signal_id, "sourceSignalId"),
         decision when decision in [:confirm, :cancel] <- parse_decision(option_id),
         %ActionCard{} = snapshot <- get_card_by_interaction(source_signal_id, interaction_id),
         true <- snapshot.conversation_id == fact.conversation_id,
         :ok <- lock_target_roots_in_tx(snapshot),
         :ok <- lock_resolution_principals_in_tx(operator_uid, snapshot, channel),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx([
             {snapshot.agent_uid, snapshot.session_id}
           ]),
         %ActionCard{} = card <- lock_card_in_tx(snapshot.id),
         %Signal{} = source <- Signals.lock_signal_in_tx(card.source_signal_id),
         true <- external_surface_matches?(source, fact.provider_message_id, binding) do
      cond do
        card.status != :prepared ->
          maybe_notify_tier2_repeat_in_tx(tier, card, source, fact, sender_key)

        true ->
          case resolve_external_operator(operator_uid) do
            {:ok, human_actor} ->
              case execute_resolution_in_tx(
                     human_actor,
                     channel,
                     card,
                     source,
                     decision,
                     tier,
                     {fact, sender_key},
                     now
                   ) do
                {:ok, outcome} ->
                  {:ok,
                   %{
                     status: :accepted_action_card,
                     action_card_outcome: outcome
                   }}

                {:error, reason} when reason in [:forbidden, :forbidden_room_operation] ->
                  maybe_notify_unauthorized_in_tx(
                    tier,
                    card,
                    source,
                    fact,
                    sender_key,
                    "You do not have permission to confirm this action card. It remains open for an authorized manager."
                  )

                {:error, _reason} = error ->
                  error
              end

            {:error, :unauthorized_operator} ->
              maybe_notify_unauthorized_in_tx(
                tier,
                card,
                source,
                fact,
                sender_key,
                "Only linked active workspace members with the required permission can confirm this action card."
              )
          end
      end
    else
      false -> {:ok, %{status: :stale_action}}
      nil -> {:ok, %{status: :stale_action}}
      :invalid_decision -> {:error, :invalid_reply_interaction}
      {:error, _} -> {:error, :invalid_reply_interaction}
    end
  end

  defp execute_resolution_in_tx(
         actor,
         conversation,
         card,
         source,
         :cancel,
         channel_mode,
         external_ctx,
         now
       ) do
    with :ok <- authorize_cancel(actor, conversation, card, source) do
      note = "Cancelled by #{NativeRoom.display_name(actor.principal)}."

      with {:ok, card} <-
             transition_card_in_tx(card, :cancelled, actor, note, now),
           {:ok, _source} <-
             resolve_interaction_checkpoint_in_tx(
               source,
               card.interaction_id,
               actor,
               "cancel",
               note,
               now
             ),
           :ok <-
             maybe_commit_tier2_settlement_in_tx(channel_mode, card, source, external_ctx, note) do
        {:ok,
         %{
           conversation_id: conversation.id,
           card: card,
           side_effects: [conversation_broadcast_effect(conversation)]
         }}
      end
    end
  end

  defp execute_resolution_in_tx(
         actor,
         conversation,
         card,
         source,
         :confirm,
         channel_mode,
         external_ctx,
         now
       ) do
    case apply_domain_action_in_tx(actor, conversation, card) do
      {:ok, note, domain_effects} ->
        with {:ok, card} <- transition_card_in_tx(card, :executed, actor, note, now),
             {:ok, _source} <-
               resolve_interaction_checkpoint_in_tx(
                 source,
                 card.interaction_id,
                 actor,
                 "confirm",
                 note,
                 now
               ),
             :ok <-
               maybe_commit_tier2_settlement_in_tx(channel_mode, card, source, external_ctx, note),
             {:ok, wakeup_signal} <-
               enqueue_executed_wakeup_in_tx(actor, conversation, card, source, note, now) do
          {:ok,
           %{
             conversation_id: conversation.id,
             card: card,
             signal: wakeup_signal,
             side_effects: [conversation_broadcast_effect(conversation) | domain_effects]
           }}
        end

      {:stale, stale_note} ->
        with {:ok, card} <- transition_card_in_tx(card, :stale, actor, stale_note, now),
             {:ok, _source} <-
               resolve_interaction_checkpoint_in_tx(
                 source,
                 card.interaction_id,
                 actor,
                 "stale",
                 stale_note,
                 now
               ),
             :ok <-
               maybe_commit_tier2_settlement_in_tx(
                 channel_mode,
                 card,
                 source,
                 external_ctx,
                 stale_note
               ) do
          {:ok,
           %{
             conversation_id: conversation.id,
             card: card,
             side_effects: [conversation_broadcast_effect(conversation)]
           }}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_domain_action_in_tx(
         actor,
         _conversation,
         %ActionCard{action_kind: "pod.page.set_sharing"} = card
       ) do
    node_id = card.payload["node_id"] || card.target_node_id
    expected_sv = card.preconditions["expected_sharing_version"]

    attrs =
      %{sharing_version: expected_sv}
      |> maybe_put_map_key(:inherit_permissions, card.payload, "inherit_permissions")
      |> maybe_put_map_key(:grants, card.payload, "grants")

    case Sharing.set_sharing_in_tx(actor, node_id, attrs) do
      {:ok, page} ->
        {:ok, "Updated sharing permissions on \"#{page.title}\".",
         [fn -> Pages.committed(page) end]}

      {:error, :sharing_conflict} ->
        {:stale, "Sharing settings on this item changed after the card was drafted."}

      {:error, :not_found} ->
        {:stale, "Target item is no longer available."}

      {:error, _} = error ->
        error
    end
  end

  defp apply_domain_action_in_tx(
         actor,
         _conversation,
         %ActionCard{action_kind: "pod.page.delete"} = card
       ) do
    node_id = card.payload["node_id"] || card.target_node_id

    with {:ok, current_page} <- Pages.lock(node_id) do
      # Check human permission BEFORE CAS so an unauthorized clicker never marks the card :stale!
      required_action =
        if current_page.type in [:file, :folder], do: "node_edit", else: "node_manage"

      with {:ok, _} <- Access.authorize(actor, current_page, required_action) do
        if page_matches_preconditions?(current_page, card.preconditions, false) do
          case Pages.delete_in_tx(actor, node_id) do
            {:ok, deleted_page} ->
              {:ok, "Moved \"#{deleted_page.title}\" to trash.",
               [fn -> Pages.committed_access_tree(deleted_page) end]}

            {:error, _} = error ->
              error
          end
        else
          {:stale, "Item was modified or already moved to trash since this card was drafted."}
        end
      end
    else
      {:error, :not_found} -> {:stale, "Target item no longer exists."}
    end
  end

  defp apply_domain_action_in_tx(
         actor,
         _conversation,
         %ActionCard{action_kind: "pod.page.restore"} = card
       ) do
    node_id = card.payload["node_id"] || card.target_node_id

    with {:ok, current_page} <- Pages.lock(node_id) do
      with {:ok, _} <- Access.authorize(actor, current_page, "node_manage", trash: true) do
        if page_matches_preconditions?(current_page, card.preconditions, true) do
          case Pages.restore_in_tx(actor, node_id) do
            {:ok, restored_page} ->
              {:ok, "Restored \"#{restored_page.title}\" from trash.",
               [fn -> Pages.committed_access_tree(restored_page) end]}

            {:error, :cannot_restore} ->
              {:stale,
               "Item can no longer be restored (already restored, purged, or parent deleted)."}

            {:error, _} = error ->
              error
          end
        else
          {:stale, "Trashed item state changed since this card was drafted."}
        end
      end
    else
      {:error, :not_found} -> {:stale, "Target item no longer exists."}
    end
  end

  defp apply_domain_action_in_tx(
         actor,
         _conversation,
         %ActionCard{action_kind: "pod.base.delete_table"} = card
       ) do
    page_id = card.preconditions["page_id"] || card.payload["page_id"]
    table_id = card.preconditions["table_id"] || card.payload["table_id"]

    with {:ok, base_page} <- authorize_base_page_for_card(actor, page_id),
         {:ok, write} <- Bases.Write.open(actor, table_id, :delete_table),
         true <- base_table_matches_preconditions?(write.table, base_page, card.preconditions) do
      delete_base_table_in_tx(write)
    else
      false -> {:stale, "Base table or Base page changed since this card was drafted."}
      {:error, :not_found} -> {:stale, "Base table was already deleted."}
      other -> other
    end
  end

  defp apply_domain_action_in_tx(
         actor,
         %Conversation{kind: :native} = conversation,
         %ActionCard{action_kind: "conversation.add_participants"} = card
       ) do
    uids = card.payload["participant_uids"] || []

    if NativeRoom.participant(conversation.id, Actor.uid(actor)) ||
         NativeRoom.owner?(actor, conversation) do
      with {:ok, added} <- NativeRoom.ensure_members(actor, conversation, uids),
           {:ok, _promoted} <- NativeRoom.promote(conversation),
           :ok <- NativeRoom.notice_added(actor, conversation, added) do
        names =
          case added do
            [] -> "already members"
            list -> Enum.map_join(list, ", ", &NativeRoom.display_name/1)
          end

        {:ok, "Added participants (#{names}) to conversation.",
         [fn -> Conversations.Events.publish_status(conversation.id) end]}
      end
    else
      {:error, :forbidden_room_operation}
    end
  end

  defp apply_domain_action_in_tx(_actor, _conversation, _card), do: {:error, :invalid_request}

  defp authorize_base_page_for_card(actor, page_id) do
    with {:ok, base_page} <- Pages.lock(page_id),
         {:ok, _} <- Access.authorize(actor, base_page, "node_manage") do
      {:ok, base_page}
    else
      {:error, :not_found} -> {:stale, "Parent Base no longer exists."}
      {:error, _} = error -> error
    end
  end

  defp delete_base_table_in_tx(%Bases.Write{table: table} = write) do
    case Bases.Delete.mark_in_tx(write) do
      {:ok, marked} ->
        effect = fn ->
          try do
            _ = Bases.Delete.cleanup(marked.id)
          rescue
            err ->
              Logging.warning(
                "conversations.action_cards.base_table_cleanup_failed",
                "Base table shard cleanup failed after mark_in_tx; scheduled reconciler will retry",
                %{table_id: marked.id, error: Exception.message(err)}
              )
          catch
            kind, reason ->
              Logging.warning(
                "conversations.action_cards.base_table_cleanup_failed",
                "Base table shard cleanup exited after mark_in_tx; scheduled reconciler will retry",
                %{table_id: marked.id, kind: inspect(kind), reason: inspect(reason)}
              )
          end

          Bases.broadcast_schema([%{id: marked.id, data_version: marked.data_version + 1}])
        end

        {:ok, "Scheduled deletion of Base table \"#{marked.name}\".", [effect]}

      {:error, :table_referenced} ->
        {:stale,
         "Table \"#{table.name}\" is now referenced by a link field and cannot be deleted."}

      {:error, :not_found} ->
        {:stale, "Base table was already deleted."}

      {:error, _} = error ->
        error
    end
  end

  defp page_matches_preconditions?(%Page{} = page, preconditions, expected_deleted) do
    deleted_matches? = not is_nil(page.deleted_at) == expected_deleted

    updated_matches? =
      case preconditions["expected_updated_at"] do
        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _} -> DateTime.compare(page.updated_at, dt) == :eq
            _ -> false
          end

        _ ->
          true
      end

    revision_matches? =
      case preconditions["expected_revision"] do
        nil -> true
        rev -> page.revision == rev
      end

    deleted_matches? and updated_matches? and revision_matches?
  end

  defp base_table_matches_preconditions?(%BaseTable{} = table, %Page{} = page, preconditions) do
    table.page_id == preconditions["page_id"] and
      is_nil(table.deleting_at) and
      table.name == preconditions["expected_name"] and
      table.schema_version == preconditions["expected_schema_version"] and
      table.data_version == preconditions["expected_data_version"] and
      case preconditions["expected_updated_at"] do
        iso when is_binary(iso) ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _} -> DateTime.compare(page.updated_at, dt) == :eq
            _ -> false
          end

        _ ->
          true
      end
  end

  defp authorize_browser_card_view(actor, %Conversation{kind: :native} = conversation, _card) do
    if Native.visible_conversation?(actor, conversation.id), do: :ok, else: {:error, :not_found}
  end

  defp authorize_browser_card_view(actor, %Conversation{kind: :external}, %ActionCard{} = card) do
    if Actor.uid(actor) == card.resolved_by_uid or can_view_card_target?(actor, card) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp can_view_card_target?(actor, %ActionCard{target_node_id: node_id} = card)
       when is_binary(node_id) do
    case Pages.fetch(node_id) do
      {:ok, page} ->
        match?(
          {:ok, _},
          Access.authorize(actor, page, "node_view",
            trash: card.action_kind == "pod.page.restore"
          )
        )

      _ ->
        false
    end
  end

  defp can_view_card_target?(_actor, _card), do: false

  defp can_manage_card_target?(actor, %ActionCard{action_kind: "pod.base.delete_table"} = card) do
    with table_id when is_binary(table_id) <- card.payload["table_id"],
         {:ok, table} <- Bases.fetch_table(table_id),
         {:ok, _} <- Bases.table_access(actor, table, :delete_table) do
      true
    else
      _ -> false
    end
  end

  defp can_manage_card_target?(actor, %ActionCard{target_node_id: node_id} = card)
       when is_binary(node_id) do
    case Pages.fetch(node_id) do
      {:ok, page} ->
        required =
          if card.action_kind == "pod.page.delete" and page.type in [:file, :folder],
            do: "node_edit",
            else: "node_manage"

        match?(
          {:ok, _},
          Access.authorize(actor, page, required, trash: card.action_kind == "pod.page.restore")
        )

      _ ->
        false
    end
  end

  defp can_manage_card_target?(_actor, _card), do: false

  defp authorize_cancel(actor, %Conversation{kind: :native} = conversation, card, _source) do
    if Native.visible_conversation?(actor, conversation.id) and
         (NativeRoom.participant(conversation.id, Actor.uid(actor)) != nil or
            NativeRoom.owner?(actor, conversation) or
            AuthZ.authorize(
              actor,
              "agent:#{card.agent_uid}",
              "chat",
              Actor.request_context(actor)
            ) == :ok) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_cancel(
         actor,
         %Conversation{kind: :external},
         %ActionCard{} = card,
         %Signal{} = source
       ) do
    if (is_binary(source.human_uid) and Actor.uid(actor) == source.human_uid) or
         can_manage_card_target?(actor, card) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp transition_card_in_tx(card, status, actor, note, now) do
    Ankole.Ash.update(card, :resolve_in_tx, %{
      status: status,
      resolved_by_uid: Actor.uid(actor),
      resolved_by_name: NativeRoom.display_name(actor.principal),
      resolved_at: now,
      resolution_note: note
    })
  end

  defp resolve_interaction_checkpoint_in_tx(
         %Signal{} = source,
         interaction_id,
         actor,
         option_id,
         note,
         now
       ) do
    preview = PreviewStates.lock_in_tx(source)
    checkpoint = preview.checkpoint || %{}

    case InteractionState.interaction(checkpoint, interaction_id) do
      %{"state" => "pending"} ->
        resolution = %{
          "state" => if(option_id == "stale", do: "superseded", else: "answered"),
          "answer" => %{
            "kind" => "choice",
            "option_id" => option_id,
            "value" => note
          },
          "answered_by_uid" => Actor.uid(actor),
          "answered_by_name" => NativeRoom.display_name(actor.principal),
          "answered_at" => DateTime.to_iso8601(now),
          "resolved_at" => DateTime.to_iso8601(now),
          "choice_id" => option_id,
          "answer_text" => note
        }

        with {:ok, updated_checkpoint} <-
               InteractionState.resolve(checkpoint, interaction_id, resolution) do
          PreviewStates.put_checkpoint_in_tx(source, updated_checkpoint)
        else
          :stale -> {:ok, source}
        end

      _ ->
        {:ok, source}
    end
  end

  defp maybe_commit_tier2_settlement_in_tx(
         :tier2,
         %ActionCard{} = card,
         %Signal{} = source,
         {fact, _sender_key},
         note
       ) do
    status_label =
      case card.status do
        :executed -> "Executed"
        :cancelled -> "Cancelled"
        :stale -> "Expired (Stale)"
        other -> to_string(other)
      end

    text = "[Action Card #{status_label}] #{note}"
    outbound_key = "action-card-settlement:#{card.id}"

    commit_external_receipt_in_tx(source, fact, outbound_key, text)
  end

  defp maybe_commit_tier2_settlement_in_tx(_mode, _card, _source, _external_ctx, _note), do: :ok

  defp maybe_notify_tier2_repeat_in_tx(
         :tier2,
         %ActionCard{} = card,
         %Signal{} = source,
         fact,
         sender_key
       ) do
    if sender_key in (card.notified_senders || []) do
      {:ok, %{status: :duplicate_action}}
    else
      updated_senders = Enum.uniq((card.notified_senders || []) ++ [sender_key])

      with {:ok, _card} <-
             Ankole.Ash.update(card, :record_notified_senders_in_tx, %{
               notified_senders: updated_senders
             }),
           :ok <-
             commit_external_receipt_in_tx(
               source,
               fact,
               "action-card-repeat:#{card.id}:#{:crypto.hash(:sha256, sender_key) |> Base.encode16(case: :lower) |> binary_part(0, 16)}",
               "[Action Card] This card was already #{card.status}."
             ) do
        {:ok, %{status: :duplicate_action}}
      end
    end
  end

  defp maybe_notify_tier2_repeat_in_tx(_tier, _card, _source, _fact, _sender_key) do
    {:ok, %{status: :duplicate_action}}
  end

  defp maybe_notify_unauthorized_in_tx(
         :tier2,
         %ActionCard{} = card,
         %Signal{} = source,
         fact,
         sender_key,
         message
       ) do
    if sender_key in (card.notified_senders || []) do
      {:ok, %{status: :unauthorized_action}}
    else
      updated_senders = Enum.uniq((card.notified_senders || []) ++ [sender_key])

      with {:ok, _card} <-
             Ankole.Ash.update(card, :record_notified_senders_in_tx, %{
               notified_senders: updated_senders
             }),
           :ok <-
             commit_external_receipt_in_tx(
               source,
               fact,
               "action-card-unauth:#{card.id}:#{:crypto.hash(:sha256, sender_key) |> Base.encode16(case: :lower) |> binary_part(0, 16)}",
               "[Action Card] #{message}"
             ) do
        {:ok, %{status: :unauthorized_action}}
      end
    end
  end

  defp maybe_notify_unauthorized_in_tx(_tier, _card, _source, _fact, _sender_key, _message) do
    {:ok, %{status: :unauthorized_action}}
  end

  defp commit_external_receipt_in_tx(%Signal{} = source, fact, outbound_key, text) do
    binding_name = fact.binding_name || source.reply_binding_name
    conversation_id = fact.conversation_id || source.conversation_id

    if is_binary(binding_name) and is_binary(conversation_id) do
      attrs = %{
        agent_uid: source.agent_uid,
        binding_id: fact.binding_id || source.reply_binding_id,
        binding_name: binding_name,
        outbound_key: outbound_key,
        operation: if(is_binary(fact.provider_message_id), do: :reply, else: :post),
        delivery_class: :generic,
        conversation_id: conversation_id,
        source_signal_id: source.id,
        provider_thread_id: fact.provider_thread_id || source.provider_thread_id,
        reply_to_provider_message_id: fact.provider_message_id,
        payload: %{
          "text" => text,
          "metadata" => %{
            "source" => "action_card_receipt"
          }
        },
        fallback_visible_text: text,
        idempotency_key: outbound_key
      }

      case Delivery.commit_in_tx(attrs) do
        {:ok, _intent} ->
          :ok

        {:error, reason} ->
          if Delivery.unroutable_reply_reason?(reason), do: :ok, else: {:error, reason}
      end
    else
      :ok
    end
  end

  defp enqueue_executed_wakeup_in_tx(
         actor,
         conversation,
         %ActionCard{} = card,
         %Signal{} = source,
         note,
         now
       ) do
    text =
      "[Action Card Executed] #{card.action_kind}: #{card.summary}\nConfirmed by #{NativeRoom.display_name(actor.principal)}. #{note}"

    reply_route =
      if conversation.kind == :external and is_binary(source.reply_binding_name) do
        %{
          binding_id: source.reply_binding_id,
          binding_name: source.reply_binding_name,
          conversation_id: conversation.id,
          provider_thread_id: source.provider_thread_id,
          provider_message_id: source.provider_message_id
        }
      end

    target =
      if conversation.kind == :native do
        %{agent_uid: card.agent_uid, conversation_id: conversation.id}
      else
        %{agent_uid: card.agent_uid, session_id: card.session_id}
      end

    Signals.accept_in_tx(%{
      producer: :kernel,
      source: "control-plane://action-cards",
      id: "action-card-executed:#{card.id}",
      type: @wakeup_signal_type,
      subject: conversation.id,
      target: target,
      sender: Actor.uid(actor),
      time: now,
      reply_route: reply_route,
      data: %{
        "conversation_id" => conversation.id,
        "action_card_id" => card.id,
        "action_kind" => card.action_kind,
        "summary" => card.summary,
        "resolution_note" => note,
        "confirmed_by_uid" => Actor.uid(actor),
        "confirmed_by_name" => NativeRoom.display_name(actor.principal),
        "answered_interaction_id" => card.interaction_id,
        "text" => text
      }
    })
  end

  def publish_after_commit(%{side_effects: effects} = outcome) when is_list(effects) do
    if outcome[:signal], do: Signals.publish_committed([outcome.signal])
    Enum.each(effects, fn effect -> effect.() end)
    :ok
  end

  def publish_after_commit(_other), do: :ok

  defp conversation_broadcast_effect(%Conversation{kind: :native, id: id}) do
    fn -> Conversations.Events.publish_message(id) end
  end

  defp conversation_broadcast_effect(_conversation), do: fn -> :ok end

  defp lock_target_roots_in_tx(%ActionCard{target_node_id: node_id}) when is_binary(node_id) do
    Nodes.lock_roots(Nodes.root_ids([node_id]))
    :ok
  end

  defp lock_target_roots_in_tx(_card), do: :ok

  defp lock_resolution_principals_in_tx(actor_uid, %ActionCard{} = card, conversation) do
    added_uids =
      case card.payload["participant_uids"] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    grant_uids =
      case card.payload["grants"] do
        list when is_list(list) ->
          Enum.flat_map(list, fn
            %{"principal_uid" => uid} when is_binary(uid) -> [uid]
            _ -> []
          end)

        _ ->
          []
      end

    created_by = conversation && Map.get(conversation, :created_by)

    uids =
      ([actor_uid, card.agent_uid, created_by | added_uids] ++ grant_uids)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    {:ok, _} = Principals.lock_principals_in_tx(uids)
    :ok
  end

  defp get_card(card_id) do
    ActionCard
    |> Ash.Query.filter(id == ^card_id)
    |> Ankole.Ash.read_one!()
  end

  defp get_card_by_interaction(source_signal_id, interaction_id)
       when is_binary(source_signal_id) and is_binary(interaction_id) do
    ActionCard
    |> Ash.Query.filter(
      source_signal_id == ^source_signal_id and interaction_id == ^interaction_id
    )
    |> Ankole.Ash.read_one!()
  end

  defp get_card_by_interaction(_source_signal_id, _interaction_id), do: nil

  defp lock_card_in_tx(card_id) do
    ActionCard
    |> Ash.Query.filter(id == ^card_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {"conversation_action_cards", card_id})
  end

  defp external_surface_matches?(%Signal{} = event, provider_message_id, binding)
       when is_binary(provider_message_id) do
    PreviewStates.get(event).provider_message_id == provider_message_id or
      provider_message_id in PreviewAdapter.surface_entry_ids(
        PreviewAdapter.for_binding(binding),
        PreviewStates.get(event).checkpoint || %{}
      )
  end

  defp external_surface_matches?(_event, _provider_message_id, _binding), do: false

  defp resolve_external_operator(uid) when is_binary(uid) and uid != "" do
    case Principals.get_principal(uid) do
      {:ok, %{type: :human, status: :active} = principal} ->
        {:ok, %Actor{principal: principal, turn_authority: nil}}

      _ ->
        {:error, :unauthorized_operator}
    end
  end

  defp resolve_external_operator(_uid), do: {:error, :unauthorized_operator}

  defp parse_decision("confirm"), do: :confirm
  defp parse_decision("cancel"), do: :cancel
  defp parse_decision(_other), do: :invalid_decision

  defp cast_uuid(value, field) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "#{field} must be a valid UUID."}
    end
  end

  defp cast_uuid(_value, field), do: {:error, "#{field} must be a valid UUID."}

  defp verify_optional_page_id(nil, _expected), do: :ok
  defp verify_optional_page_id("", _expected), do: :ok

  defp verify_optional_page_id(provided, expected) when is_binary(provided) do
    case Ecto.UUID.cast(String.trim(provided)) do
      {:ok, ^expected} -> :ok
      _ -> {:error, "page_id does not match the owning Base of table_id."}
    end
  end

  defp verify_optional_page_id(_provided, _expected),
    do: {:error, "page_id must be a valid UUID."}

  defp normalize_grant_items(:unchanged), do: :unchanged

  defp normalize_grant_items(grants) when is_list(grants) do
    Enum.map(grants, fn
      grant when is_map(grant) ->
        Map.new(grant, fn {k, v} -> {to_string(k), v} end)

      other ->
        other
    end)
  end

  defp maybe_put_unchanged(map, _key, :unchanged), do: map
  defp maybe_put_unchanged(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_map_key(target, atom_key, source, string_key) when is_atom(atom_key) do
    if Map.has_key?(source, string_key),
      do: Map.put(target, atom_key, source[string_key]),
      else: target
  end

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed
  end

  defp non_empty_string(_), do: nil
end
