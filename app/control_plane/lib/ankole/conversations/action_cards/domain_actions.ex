defmodule Ankole.Conversations.ActionCards.DomainActions do
  @moduledoc """
  Target authorization and in-transaction domain execution for Conversation Action Cards.
  """

  alias Ankole.AuthZ
  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations
  alias Ankole.Conversations.{ActionCard, Conversation, Native}
  alias Ankole.Conversations.NativeRoom
  alias Ankole.Logging
  alias Ankole.Pod.{Access, BaseTable, Bases, Page, Pages}
  alias Ankole.Pod.Pages.Sharing

  @doc "Executes a confirmed card's locked mutation inside the caller's transaction."
  def apply_in_tx(actor, conversation, card, opts \\ [])

  def apply_in_tx(
        actor,
        _conversation,
        %ActionCard{action_kind: "brain.object.create"} = card,
        _opts
      ) do
    with {:ok, category} <- Ankole.Brain.ObjectWrites.category(card.payload["category"]),
         true <- category.id == card.target_node_id,
         {:ok, parsed} <- Ankole.Kernel.knowledge_parse(card.payload["markdown"]),
         {:ok, page} <-
           Pages.create_in_tx(actor, %{
             type: :knowledge,
             parent_id: category.id,
             title: card.payload["node_title"],
             xml: parsed.xml,
             metadata: parsed.metadata
           }) do
      {:ok, "Created Brain object \"#{page.title}\".",
       [fn -> Pages.committed_tree(%{page: page}) end]}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def apply_in_tx(
        actor,
        _conversation,
        %ActionCard{action_kind: "pod.knowledge.save"} = card,
        _opts
      ) do
    with {:ok, page} <- Pages.lock(card.target_node_id),
         {:ok, _} <- Access.authorize(actor, page, "node_edit"),
         {:ok, parsed} <- Ankole.Kernel.knowledge_parse(card.payload["markdown"]) do
      case Ankole.Pod.Knowledge.put_in_tx(page.id, parsed,
             actor: actor,
             base_revision: card.preconditions["expected_revision"]
           ) do
        {:ok, %{page: saved}} ->
          {:ok, "Saved knowledge page \"#{saved.title}\".",
           [fn -> Pages.committed_page(saved) end]}

        {:error, {:revision_conflict, _}} ->
          {:stale,
           "The knowledge page changed after the proposed edit. Read it again and prepare a new draft."}

        error ->
          error
      end
    end
  end

  def apply_in_tx(
        actor,
        _conversation,
        %ActionCard{action_kind: "pod.page.set_sharing"} = card,
        _opts
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

  def apply_in_tx(
        actor,
        _conversation,
        %ActionCard{action_kind: "pod.page.delete"} = card,
        _opts
      ) do
    node_id = card.payload["node_id"] || card.target_node_id

    with {:ok, current_page} <- Pages.lock(node_id) do
      required_action = if current_page.type == :file, do: "node_edit", else: "node_manage"

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

  def apply_in_tx(
        actor,
        _conversation,
        %ActionCard{action_kind: "pod.page.restore"} = card,
        _opts
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

  def apply_in_tx(
        actor,
        _conversation,
        %ActionCard{action_kind: "pod.base.delete_table"} = card,
        _opts
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

  def apply_in_tx(
        actor,
        %Conversation{kind: :native} = conversation,
        %ActionCard{action_kind: "conversation.add_participants"} = card,
        _opts
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

  def apply_in_tx(
        actor,
        _conversation,
        %ActionCard{action_kind: "library.skill.save"} = card,
        _opts
      ) do
    case Ankole.AIAgent.Library.Skills.upsert_from_action_card_in_tx(
           actor,
           card.payload,
           card.preconditions
         ) do
      {:ok, saved, effects} ->
        verb = if card.payload["operation"] == "update", do: "Updated", else: "Saved"
        scope = if is_binary(saved.agent_uid), do: "personal Skill", else: "workspace Skill"
        {:ok, "#{verb} #{scope} \"#{saved.name}\" (/#{saved.slug}).", effects}

      {:stale, _note} = stale ->
        stale

      {:error, _reason} = error ->
        error
    end
  end

  def apply_in_tx(
        actor,
        conversation,
        %ActionCard{action_kind: "connectors.tool.call"} = card,
        opts
      ) do
    if not can_confirm_connector_card?(actor, conversation, card) do
      {:error, :forbidden}
    else
      case Keyword.get(opts, :connector_outcome) do
        {:ok, outcome_kind, note} -> {:ok, outcome_kind, note, []}
        {:ok, note} -> {:ok, :succeeded, note, []}
        {:stale, _note} = stale -> stale
        {:error, _reason} = error -> error
        nil -> {:error, :connector_outcome_missing}
      end
    end
  end

  def apply_in_tx(_actor, _conversation, _card, _opts), do: {:error, :invalid_request}

  @execution_claim_ttl_seconds 120

  @doc "Returns true when `card` is in `:executing` with an unexpired execution lease at `now`."
  def active_execution_claim?(
        %ActionCard{status: :executing, execution_claim_expires_at: %DateTime{} = expires_at},
        %DateTime{} = now
      ) do
    DateTime.compare(expires_at, now) == :gt
  end

  def active_execution_claim?(_card, _now), do: false

  def claim_matches?(
        %ActionCard{status: :executing, execution_claim_id: current_claim_id},
        claim_id
      )
      when is_binary(claim_id),
      do: current_claim_id == claim_id

  def claim_matches?(_card, _claim_id), do: false

  def connector_execution_started?(%ActionCard{} = card, %DateTime{} = now) do
    card.status == :executing or
      active_execution_claim?(card, now) or
      Ankole.Connectors.WriteReceipts.exists_for_scope?("action_card:" <> card.id)
  end

  @doc "Authorizes and transitions a locked `connectors.tool.call` card into `:executing` with a bounded lease."
  def claim_connector_execution_in_tx(
        %Actor{} = human_actor,
        %Conversation{} = conversation,
        %ActionCard{action_kind: "connectors.tool.call", status: status} = card,
        %DateTime{} = now
      )
      when status in [:prepared, :executing] do
    cond do
      not can_confirm_connector_card?(human_actor, conversation, card) ->
        {:error, :forbidden}

      active_execution_claim?(card, now) ->
        {:error, :conflict}

      true ->
        claim_id = Ankole.Ecto.UUIDv7.autogenerate()
        expires_at = DateTime.add(now, @execution_claim_ttl_seconds, :second)

        with {:ok, claimed_card} <-
               Ankole.Ash.update(card, :claim_execution_in_tx, %{
                 status: :executing,
                 resolved_by_uid: Actor.uid(human_actor),
                 resolved_by_name: NativeRoom.display_name(human_actor.principal),
                 execution_claim_id: claim_id,
                 execution_claim_expires_at: expires_at,
                 execution_attempts: (card.execution_attempts || 0) + 1
               }) do
          {:ok, claimed_card, claim_id}
        end
    end
  end

  def claim_connector_execution_in_tx(_actor, _conversation, _card, _now),
    do: {:error, :conflict}

  @doc "Executes a claimed `connectors.tool.call` card outside database locks and normalizes its settlement outcome."
  def execute_claimed_connector_card(%ActionCard{} = claimed_card, %Actor{} = human_actor) do
    try do
      case Ankole.Connectors.Gateway.execute_approved_card(claimed_card, human_actor) do
        {:error, :conflict} ->
          {:error, :conflict}

        {:stale, _note} = stale ->
          stale

        {:ok, _outcome_kind, _note} = ok ->
          ok

        {:error, reason} ->
          {:ok, :failed_not_sent,
           "Connector call could not be completed: #{String.slice(inspect(reason), 0, 500)}"}
      end
    rescue
      exception ->
        settlement_from_crash(claimed_card.id, Exception.message(exception))
    catch
      kind, reason ->
        settlement_from_crash(claimed_card.id, "#{kind}: #{inspect(reason)}")
    end
  end

  defp settlement_from_crash(card_id, summary) do
    detail = String.slice(summary, 0, 400)

    if Ankole.Connectors.WriteReceipts.exists_for_scope?("action_card:" <> card_id) do
      {:ok, :failed_uncertain,
       "Connector call ended before reporting completion (upstream outcome uncertain; inspect before retrying): #{detail}"}
    else
      {:ok, :failed_not_sent, "Connector call could not be completed: #{detail}"}
    end
  end

  @doc "Runs the claim -> external execute -> settle sequence for Web ActionCard endpoints."
  def run_web_lifecycle(%Actor{} = human_actor, step_fn) when is_function(step_fn, 1) do
    case step_fn.(nil) do
      {:ok, %{claimed: {claimed_card, claim_id}}} ->
        case execute_claimed_connector_card(claimed_card, human_actor) do
          {:error, :conflict} -> {:error, :conflict}
          connector_outcome -> step_fn.({claim_id, connector_outcome})
        end

      other ->
        other
    end
  end

  @doc "Dispatches locked Phase 1 claim, Phase 3 settlement, or synchronous resolution."
  def advance_locked_in_tx(
        actor,
        conversation,
        %ActionCard{action_kind: "connectors.tool.call"} = card,
        :confirm,
        now,
        nil,
        _settle_fn
      ) do
    with {:ok, claimed_card, claim_id} <-
           claim_connector_execution_in_tx(actor, conversation, card, now) do
      effects =
        if conversation.kind == :native do
          [fn -> Ankole.Conversations.Events.publish_message(conversation.id) end]
        else
          []
        end

      {:ok,
       %{
         claimed: {claimed_card, claim_id},
         conversation_id: conversation.id,
         card: claimed_card,
         side_effects: effects
       }}
    end
  end

  def advance_locked_in_tx(
        _actor,
        _conversation,
        %ActionCard{action_kind: "connectors.tool.call"} = card,
        :confirm,
        _now,
        {claim_id, connector_outcome},
        settle_fn
      ) do
    if claim_matches?(card, claim_id),
      do: settle_fn.(connector_outcome),
      else: {:error, :conflict}
  end

  def advance_locked_in_tx(_actor, _conversation, _card, _decision, _now, precomputed, settle_fn),
    do: settle_fn.(precomputed)

  def authorize_browser_card_view(
        actor,
        %Conversation{kind: :native} = conversation,
        %ActionCard{} = card
      ) do
    personal_skill_card? =
      card.action_kind == "library.skill.save" and is_binary(card.payload["agent_uid"])

    if Native.visible_conversation?(actor, conversation.id) and
         (not personal_skill_card? or Actor.uid(actor) == card.resolved_by_uid or
            can_view_card_target?(actor, card)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  def authorize_browser_card_view(actor, %Conversation{kind: :external}, %ActionCard{} = card) do
    if Actor.uid(actor) == card.resolved_by_uid or can_view_card_target?(actor, card) do
      :ok
    else
      {:error, :not_found}
    end
  end

  def can_view_card_target?(actor, %ActionCard{target_node_id: node_id} = card)
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

  def can_view_card_target?(actor, %ActionCard{action_kind: "library.skill.save"} = card) do
    case card.payload["agent_uid"] do
      uid when is_binary(uid) ->
        Ankole.AIAgent.Library.Management.agent(actor, uid, "read") == :ok

      _ ->
        Ankole.AIAgent.Library.Management.member(actor) == :ok
    end
  end

  def can_view_card_target?(actor, %ActionCard{action_kind: "connectors.tool.call"} = card),
    do: can_manage_card_target?(actor, card)

  def can_view_card_target?(_actor, _card), do: false

  def can_confirm_connector_card?(actor, %Conversation{kind: :native} = conv, card) do
    Native.visible_conversation?(actor, conv.id) and
      (NativeRoom.participant(conv.id, Actor.uid(actor)) != nil or
         NativeRoom.owner?(actor, conv) or
         AuthZ.pod_admin?(Actor.uid(actor))) and
      can_manage_card_target?(actor, card)
  end

  def can_confirm_connector_card?(actor, %Conversation{kind: :external}, card),
    do: can_manage_card_target?(actor, card)

  def can_manage_card_target?(actor, %ActionCard{action_kind: "connectors.tool.call"} = card) do
    uid = Actor.uid(actor)
    active_human? = actor.principal.type == :human and actor.principal.status == :active

    cond do
      not active_human? ->
        false

      AuthZ.pod_admin?(uid) ->
        true

      card.payload["subject_kind"] == "human" and is_binary(card.payload["account_owner_uid"]) ->
        uid == card.payload["account_owner_uid"]

      is_binary(card.payload["auth_config_id"]) ->
        actor.principal.membership == :member and
          case Ankole.Connectors.Store.get_auth_config_for_configuration(
                 card.payload["auth_config_id"]
               ) do
            {:ok, config} ->
              Ankole.Connectors.ConnectionAccess.authorize(actor.principal, config) == :ok

            _ ->
              false
          end

      true ->
        actor.principal.membership == :member
    end
  end

  def can_manage_card_target?(actor, %ActionCard{action_kind: "library.skill.save"} = card) do
    alias Ankole.AIAgent.Library.Management

    case card.payload["agent_uid"] do
      uid when is_binary(uid) ->
        Management.agent(actor, uid, "update") == :ok

      _ ->
        Management.authorize(actor, "tenant_console:custom_skills") == :ok and
          (is_nil(card.payload["bind_agent_uid"]) or
             Management.binding(actor, card.payload["bind_agent_uid"]) == :ok)
    end
  end

  def can_manage_card_target?(actor, %ActionCard{action_kind: "pod.base.delete_table"} = card) do
    with table_id when is_binary(table_id) <- card.payload["table_id"],
         {:ok, table} <- Bases.fetch_table(table_id),
         {:ok, _} <- Bases.table_access(actor, table, :delete_table) do
      true
    else
      _ -> false
    end
  end

  def can_manage_card_target?(actor, %ActionCard{target_node_id: node_id} = card)
      when is_binary(node_id) do
    case Pages.fetch(node_id) do
      {:ok, page} ->
        required =
          if card.action_kind in ["pod.knowledge.save", "brain.object.create"] or
               (card.action_kind == "pod.page.delete" and page.type == :file),
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

  def can_manage_card_target?(_actor, _card), do: false

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
      updated_at_matches?(page.updated_at, preconditions["expected_updated_at"])

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
      updated_at_matches?(page.updated_at, preconditions["expected_updated_at"])
  end

  defp updated_at_matches?(updated_at, expected) when is_binary(expected) do
    case Ankole.Attrs.parse_datetime(expected) do
      %DateTime{} = datetime -> DateTime.compare(updated_at, datetime) == :eq
      nil -> false
    end
  end

  defp updated_at_matches?(_updated_at, _expected), do: true

  defp maybe_put_map_key(map, dest_key, source, source_key) do
    if Map.has_key?(source, source_key) do
      Map.put(map, dest_key, Map.get(source, source_key))
    else
      map
    end
  end
end
