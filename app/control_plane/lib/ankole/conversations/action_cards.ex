defmodule Ankole.Conversations.ActionCards do
  @moduledoc """
  Drafts, authorizes, and executes privilege-escalated Action Cards across
  Pod native rooms and external messaging channels.
  """

  require Ash.Query

  alias Ankole.{AuthZ, Principals, Repo, Signals}
  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations
  alias Ankole.Conversations.{ActionCard, Conversation, Native, NativeRoom, Queries}
  alias Ankole.Conversations.ActionCards.DomainActions

  alias Ankole.Conversations.Delivery

  alias Ankole.Conversations.Delivery.{
    ActionCardPrompt,
    Adapter,
    InteractionState,
    PreviewAdapter,
    PreviewStates
  }

  alias Ankole.Pod.Access
  alias Ankole.Pod.Pages.Tree, as: Nodes
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
         :ok <- supported_conversation_action(conversation, args["action_kind"]),
         {:ok, summary} <- ActionCardPrompt.sanitize_summary(Map.get(args, "summary")),
         {:ok, %{type: :agent, status: :active} = agent_principal} <-
           Principals.get_principal(run.agent_uid),
         agent_actor = Actor.new(agent_principal),
         {:ok, target_node_id, payload, preconditions} <-
           (if Map.get(args, "action_kind") == "library.skill.save" do
              draft_skill_save(run, conversation, args)
            else
              draft_action(agent_actor, conversation, Map.get(args, "action_kind"), args)
            end),
         :ok <- knowledge_disclosure(run, args["action_kind"], target_node_id) do
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

  defp knowledge_disclosure(run, kind, id)
       when kind in ["pod.knowledge.save", "brain.object.create"] do
    with {:ok, context} <-
           Ankole.Brain.RequestContext.build(run.agent_uid, %{"signal_id" => run.signal_id}),
         {:ok, page} <- Pages.fetch(id),
         {:ok, _} <- Ankole.Pod.AgentPages.visible(context, page),
         do: :ok
  end

  defp knowledge_disclosure(_run, _kind, _id), do: :ok

  defp draft_action(actor, _conversation, "brain.object.create", args) do
    with {:ok, category} <- Ankole.Brain.ObjectWrites.category(args["category"]),
         {:ok, _} <- Pages.authorize(actor, category.id, "node_view"),
         title when is_binary(title) and title != "" <- args["title"],
         markdown when is_binary(markdown) <- args["markdown"],
         {:ok, _} <- Ankole.Kernel.knowledge_parse(markdown) do
      {:ok, category.id,
       %{
         "node_id" => category.id,
         "category" => category.name,
         "node_title" => title,
         "markdown" => markdown,
         "diff" => markdown
       }, %{}}
    else
      nil -> {:error, :invalid_request}
      error -> error
    end
  end

  defp draft_action(actor, _conversation, "pod.knowledge.save", args) do
    with {:ok, id} <- cast_uuid(args["node_id"], "node_id"),
         {:ok, %{page: %{type: :knowledge} = page, content: content}} <- Pages.get(actor, id),
         true <- args["base_revision"] == page.revision,
         markdown when is_binary(markdown) <- args["markdown"],
         {:ok, _} <- Ankole.Kernel.knowledge_parse(markdown),
         {:ok, previous} <- Ankole.Kernel.knowledge_export(content.content, page.metadata) do
      diff =
        String.myers_difference(previous, markdown)
        |> Enum.map_join(fn
          {:eq, text} -> text
          {:del, text} -> "\n- " <> text
          {:ins, text} -> "\n+ " <> text
        end)

      {:ok, id,
       %{"node_id" => id, "node_title" => page.title, "markdown" => markdown, "diff" => diff},
       %{"node_id" => id, "expected_revision" => page.revision}}
    else
      false -> {:error, "The page changed. Read it again before proposing the edit."}
      {:ok, _} -> {:error, "The target must be a knowledge page."}
      nil -> {:error, "pod.knowledge.save requires complete markdown."}
      error -> error
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
          normalized_grants = normalize_grant_items(grants)

          payload =
            %{
              "node_id" => page.id,
              "node_title" => page.title
            }
            |> maybe_put_unchanged("inherit_permissions", inherit_permissions)
            |> maybe_put_unchanged("grants", normalized_grants)
            |> maybe_put_sharing_explain_summaries(agent_actor, page, normalized_grants)

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

  defp draft_skill_save(run, conversation, args) do
    alias Ankole.AIAgent.Library.{SkillLinter, Skills}

    with {:ok, %{slug: slug, content: content}} <-
           SkillLinter.validate_and_parse(args["markdown"], args["slug"]),
         {:ok, target} <- resolve_skill_save_target(run, conversation, args["target"]) do
      case Skills.get(slug) do
        {:error, :not_found} ->
          payload =
            %{
              "operation" => "create",
              "slug" => slug,
              "skill_name" => content.name,
              "description" => content.description,
              "target" => target.scope,
              "agent_uid" => target.agent_uid,
              "bind_agent_uid" => target.bind_agent_uid,
              "markdown" => content.manifest_markdown,
              "diff" => content.manifest_markdown
            }
            |> maybe_put_non_nil("scope_note", target.scope_note)

          {:ok, nil, payload, %{"slug" => slug, "expected_missing" => true}}

        {:ok, existing} ->
          cond do
            existing.source_kind != :custom ->
              {:error,
               "Slug \"#{slug}\" belongs to a built-in or plugin Skill and cannot be overwritten. Choose another slug."}

            is_binary(existing.agent_uid) and existing.agent_uid != target.agent_uid ->
              {:error,
               "Slug \"#{slug}\" is already taken in this workspace. Choose another descriptive slug."}

            is_nil(existing.agent_uid) and target.scope != "workspace" ->
              {:error,
               "Slug \"#{slug}\" already exists as a workspace Skill. Choose a distinct slug for your personal Skill, or pass target: \"workspace\" with base_revision: #{existing.revision} to update the workspace Skill."}

            is_binary(existing.agent_uid) and target.scope == "workspace" ->
              {:error,
               "Slug \"#{slug}\" is currently a personal Skill. Pass target: \"personal\" with base_revision: #{existing.revision} to update it, or choose a new slug for the workspace Skill."}

            args["base_revision"] != existing.revision ->
              {:error,
               "Skill \"#{slug}\" is at revision #{existing.revision}. Read its latest content with skill_view and pass base_revision: #{existing.revision}."}

            true ->
              diff =
                List.myers_difference(
                  String.split(existing.manifest_markdown, "\n"),
                  String.split(content.manifest_markdown, "\n")
                )
                |> Enum.flat_map(fn
                  {:eq, lines} -> Enum.map(lines, &("  " <> &1))
                  {:del, lines} -> Enum.map(lines, &("- " <> &1))
                  {:ins, lines} -> Enum.map(lines, &("+ " <> &1))
                end)
                |> Enum.join("\n")

              payload =
                %{
                  "operation" => "update",
                  "slug" => existing.slug,
                  "skill_name" => content.name,
                  "description" => content.description,
                  "target" => target.scope,
                  "agent_uid" => existing.agent_uid,
                  "bind_agent_uid" => target.bind_agent_uid,
                  "markdown" => content.manifest_markdown,
                  "diff" => diff,
                  "base_revision" => existing.revision
                }
                |> maybe_put_non_nil("scope_note", target.scope_note)

              preconditions = %{
                "skill_id" => existing.id,
                "slug" => existing.slug,
                "expected_revision" => existing.revision
              }

              {:ok, nil, payload, preconditions}
          end
      end
    end
  end

  defp resolve_skill_save_target(run, conversation, raw_target) do
    alias Ankole.AIAgent.Library.Management

    requested = if raw_target == "workspace", do: "workspace", else: "personal"
    requester_uid = requester_human_uid(run, conversation)

    requester_actor =
      case requester_uid && Principals.get_principal(requester_uid) do
        {:ok, %{type: :human, status: :active, membership: :member} = principal} ->
          Actor.new(principal)

        _ ->
          nil
      end

    case {requested, requester_actor} do
      {"workspace", %Actor{} = human_actor} ->
        if Management.authorize(human_actor, "tenant_console:custom_skills") == :ok and
             Management.binding(human_actor, run.agent_uid) == :ok do
          {:ok,
           %{
             scope: "workspace",
             agent_uid: nil,
             bind_agent_uid: run.agent_uid,
             scope_note: nil
           }}
        else
          with {:ok, %{principal: assistant}} <-
                 Principals.ensure_personal_assistant(human_actor.principal.uid) do
            {:ok,
             %{
               scope: "personal",
               agent_uid: assistant.uid,
               bind_agent_uid: nil,
               scope_note:
                 "Drafted for your personal assistant because saving workspace skills requires custom-skill permission."
             }}
          end
        end

      {"workspace", nil} ->
        {:ok,
         %{
           scope: "workspace",
           agent_uid: nil,
           bind_agent_uid: run.agent_uid,
           scope_note: nil
         }}

      {"personal", %Actor{} = human_actor} ->
        with {:ok, %{principal: assistant}} <-
               Principals.ensure_personal_assistant(human_actor.principal.uid) do
          {:ok,
           %{
             scope: "personal",
             agent_uid: assistant.uid,
             bind_agent_uid: nil,
             scope_note: nil
           }}
        end

      {"personal", nil} ->
        {:error,
         "Saving a personal Skill requires an active workspace member account. Link your account or pass target: \"workspace\" for a workspace Skill."}
    end
  end

  defp requester_human_uid(run, conversation) do
    data = run.event.data || %{}

    run.event.human_uid ||
      get_in(data, ["confirmed_by_uid"]) ||
      get_in(data, ["action", "operator_principal_uid"]) ||
      get_in(data, ["entry", "author", "principal_uid"]) ||
      Principals.served_human_uid(run.agent_uid, nil) ||
      if(conversation && conversation.kind == :native && conversation.room_mode == :dm,
        do: conversation.created_by
      )
  end

  defp maybe_put_non_nil(map, _key, nil), do: map
  defp maybe_put_non_nil(map, key, value), do: Map.put(map, key, value)

  defp supported_conversation_action(%Conversation{kind: :native}, kind)
       when kind in ["pod.knowledge.save", "brain.object.create"], do: :ok

  defp supported_conversation_action(_, kind)
       when kind in ["pod.knowledge.save", "brain.object.create"],
       do:
         {:error,
          "Shared knowledge edits require an authorized owner to confirm in Pod. Provide the proposed draft here and identify the owner; do not save it to private memory."}

  defp supported_conversation_action(conversation, "conversation.add_participants") do
    if conversation.native_access_scope == :agent_peer or NativeRoom.protected_dm?(conversation),
      do: {:error, "Create a new group to add participants to a private conversation."},
      else: :ok
  end

  defp supported_conversation_action(_, _), do: :ok

  @doc "Records a prepared `connectors.tool.call` ActionCard during a live conversation turn."
  def prepare_connector_action_card(turn, digest, summary, payload)
      when is_map(turn) and is_binary(digest) and is_binary(summary) and is_map(payload) do
    run_tx = fn ->
      Ankole.AdvisoryLock.lock!(
        Repo,
        "connector_card_prepare:#{Repo.tenant_id!()}:#{turn.signal_id}"
      )

      prepared =
        ActionCard
        |> Ash.Query.filter(
          source_signal_id == ^turn.signal_id and status == :prepared and
            action_kind == "connectors.tool.call"
        )
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ankole.Ash.read!()

      case prepared do
        [%ActionCard{} = existing | _] ->
          if existing.preconditions["args_sha256"] == digest do
            {:ok, existing}
          else
            {:error, {:approval_already_pending_in_turn, existing}}
          end

        [] ->
          card_id = Ankole.Ecto.UUIDv7.autogenerate()

          Ankole.Ash.create(ActionCard, :prepare_in_tx, %{
            id: card_id,
            conversation_id: turn.conversation_id,
            session_id: turn.session_id,
            agent_uid: turn.agent_uid,
            source_signal_id: turn.signal_id,
            interaction_id: "action_card:#{card_id}",
            action_kind: "connectors.tool.call",
            summary: summary,
            target_node_id: nil,
            payload: payload,
            preconditions: %{"args_sha256" => digest}
          })
      end
    end

    if Repo.in_transaction?(), do: run_tx.(), else: Repo.transact_top_level(run_tx)
  end

  @doc "Returns the ActionCardPrompt for the latest prepared connector ActionCard of `signal_id`."
  def prepared_prompt_for_signal(signal_id) when is_binary(signal_id) do
    case Ecto.UUID.cast(signal_id) do
      {:ok, signal_id} ->
        ActionCard
        |> Ash.Query.filter(
          source_signal_id == ^signal_id and status == :prepared and
            action_kind == "connectors.tool.call"
        )
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(1)
        |> Ankole.Ash.read_one!()
        |> case do
          %ActionCard{} = card -> ActionCardPrompt.from_card(card)
          nil -> nil
        end

      :error ->
        nil
    end
  end

  def prepared_prompt_for_signal(_), do: nil

  @doc "Idempotently attaches a prepared connector ActionCard prompt onto `completion` or `statement`."
  def attach_prepared_completion(completion, signal_id) when is_map(completion) do
    cond do
      Map.has_key?(completion, :action_card_attached) ->
        completion

      completion[:action_card_prompt] != nil or completion[:clarify_prompt] != nil ->
        Map.put(completion, :action_card_attached, true)

      true ->
        prompt = prepared_prompt_for_signal(signal_id)

        completion
        |> Map.put(:action_card_attached, true)
        |> then(fn map -> if prompt, do: Map.put(map, :action_card_prompt, prompt), else: map end)
    end
  end

  def attach_prepared_prompt(
        %Ankole.Conversations.Statement{
          notice: nil,
          signal: %Signal{id: signal_id},
          completion: %{} = completion
        } = statement
      ) do
    %{statement | completion: attach_prepared_completion(completion, signal_id)}
  end

  def attach_prepared_prompt(
        %Ankole.Conversations.Statement{completion: %{} = completion} = statement
      ) do
    %{statement | completion: Map.put_new(completion, :action_card_attached, true)}
  end

  def attach_prepared_prompt(statement), do: statement

  @doc "Persists a prepared ActionCard row inside the turn-completion transaction."
  def commit_prepared_in_tx(%Signal{} = event, conversation_id, prompt) when is_map(prompt) do
    case get_card(prompt["card_id"]) do
      %ActionCard{} = existing ->
        {:ok, existing}

      nil ->
        conversation_id =
          case Conversations.peer_exchange(event.conversation_id) do
            %{origin_conversation_id: id} when not is_nil(id) -> id
            _ -> conversation_id
          end

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

  @doc "Returns the subset of conversation IDs that have at least one unresolved (`prepared` or `executing`) Action Card."
  def open_conversation_ids([]), do: MapSet.new()

  def open_conversation_ids(conversation_ids) when is_list(conversation_ids) do
    ActionCard
    |> Ash.Query.filter(
      conversation_id in ^conversation_ids and status in [:prepared, :executing]
    )
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

  @doc "Cancels any prepared ActionCards for `signal_id` except `keep_card_id` inside the caller's transaction."
  def cancel_unattached_prepared_in_tx(signal_id, keep_card_id \\ nil)

  def cancel_unattached_prepared_in_tx(signal_id, keep_card_id) when is_binary(signal_id) do
    case Ecto.UUID.cast(signal_id) do
      {:ok, id} -> cancel_unattached_prepared_for_signals_in_tx([id], keep_card_id)
      :error -> :ok
    end
  end

  def cancel_unattached_prepared_in_tx(_, _), do: :ok

  @doc "Cancels any prepared ActionCards across `signal_ids` except `keep_card_id` inside the caller's transaction."
  def cancel_unattached_prepared_for_signals_in_tx([], _keep_card_id), do: :ok

  def cancel_unattached_prepared_for_signals_in_tx(signal_ids, keep_card_id)
      when is_list(signal_ids) do
    :ok = Repo.require_transaction()
    now = DateTime.utc_now(:microsecond)

    cards =
      ActionCard
      |> Ash.Query.filter(source_signal_id in ^signal_ids and status == :prepared)
      |> Ash.Query.sort(id: :asc)
      |> Ankole.Ash.read!()

    Enum.reduce_while(cards, :ok, fn %ActionCard{} = card, :ok ->
      if card.id == keep_card_id or
           (card.action_kind == "connectors.tool.call" and
              DomainActions.connector_execution_started?(card, now)) do
        {:cont, :ok}
      else
        case Ankole.Ash.update(card, :resolve_in_tx, %{
               status: :cancelled,
               resolved_by_uid: nil,
               resolved_by_name: nil,
               resolved_at: now,
               resolution_note: "Turn ended without attaching this approval card."
             }) do
          {:ok, _updated} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  @doc "Marks pre-locked prepared Action Cards cancelled when their source Signal entry was removed."
  def cancel_locked_for_signals_in_tx([], _superseded_signal_ids, _now), do: :ok
  def cancel_locked_for_signals_in_tx(_locked_cards, [], _now), do: :ok

  def cancel_locked_for_signals_in_tx(locked_cards, superseded_signal_ids, %DateTime{} = now)
      when is_list(locked_cards) and is_list(superseded_signal_ids) do
    superseded_set = MapSet.new(superseded_signal_ids)

    Enum.reduce_while(locked_cards, :ok, fn %ActionCard{} = card, :ok ->
      if card.status == :prepared and MapSet.member?(superseded_set, card.source_signal_id) and
           not DomainActions.connector_execution_started?(card, now) do
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
  def native_cards(messages, viewer_actor \\ nil) when is_list(messages) do
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
            {message.id, client_card_state(card, viewer_actor)}

          nil ->
            {message.id, %{}}
        end
      end)
    end
  end

  def client_card_state(%ActionCard{} = card, viewer_actor \\ nil) do
    redacted_connector? = redacted_connector_card?(viewer_actor, card)

    can_recover =
      card.status == :executing and
        not DomainActions.active_execution_claim?(card, DateTime.utc_now(:microsecond))

    %{
      "card_id" => card.id,
      "interaction_id" => card.source_signal_id <> ":" <> card.interaction_id,
      "action_kind" => card.action_kind,
      "summary" => card.summary,
      "target_node_id" => card.target_node_id,
      "payload" => client_payload(card, viewer_actor, redacted_connector?),
      "status" => to_string(card.status),
      "can_recover" => can_recover,
      "resolved_by_uid" => card.resolved_by_uid,
      "resolved_by_name" => card.resolved_by_name,
      "resolved_at" => card.resolved_at && DateTime.to_iso8601(card.resolved_at),
      "resolution_note" => if(redacted_connector?, do: nil, else: card.resolution_note)
    }
  end

  defp client_payload(
         %ActionCard{action_kind: "pod.knowledge.save"} = card,
         _viewer_actor,
         _redacted?
       ),
       do: Map.put(card.payload, "base_revision", card.preconditions["expected_revision"])

  defp client_payload(
         %ActionCard{action_kind: "library.skill.save"} = card,
         viewer_actor,
         _redacted?
       ) do
    payload =
      case card.preconditions["expected_revision"] do
        rev when is_integer(rev) -> Map.put(card.payload, "base_revision", rev)
        _ -> card.payload
      end

    if is_binary(payload["agent_uid"]) and not viewer_can_read_skill_card?(viewer_actor, card) do
      payload
      |> Map.drop(["diff", "markdown"])
      |> Map.put("redacted", true)
    else
      payload
    end
  end

  defp client_payload(
         %ActionCard{action_kind: "connectors.tool.call"} = card,
         _viewer_actor,
         true
       ) do
    card.payload
    |> Map.drop(["arguments", "arguments_preview"])
    |> Map.put("redacted", true)
  end

  defp client_payload(
         %ActionCard{action_kind: "connectors.tool.call"} = card,
         _viewer_actor,
         false
       ),
       do: Map.delete(card.payload, "arguments")

  defp client_payload(%ActionCard{} = card, _viewer_actor, _redacted?), do: card.payload

  defp redacted_connector_card?(
         %Actor{} = viewer_actor,
         %ActionCard{action_kind: "connectors.tool.call"} = card
       ) do
    card.payload["subject_kind"] == "human" and
      Actor.uid(viewer_actor) != card.resolved_by_uid and
      not DomainActions.can_manage_card_target?(%{viewer_actor | turn_authority: nil}, card)
  end

  defp redacted_connector_card?(_viewer_actor, _card), do: false

  defp viewer_can_read_skill_card?(%Actor{} = viewer_actor, %ActionCard{} = card),
    do: DomainActions.can_view_card_target?(%{viewer_actor | turn_authority: nil}, card)

  defp viewer_can_read_skill_card?(_, _card), do: false

  def browser_card_state(
        %ActionCard{} = card,
        %Conversation{} = conversation,
        viewer_actor \\ nil
      ) do
    card
    |> client_card_state(viewer_actor)
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
         :ok <- DomainActions.authorize_browser_card_view(human_actor, conversation, card) do
      {:ok, browser_card_state(card, conversation, human_actor)}
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

    step = fn settlement ->
      Repo.transact_top_level(
        fn -> resolve_browser_card_in_tx(human_actor, card_id, decision, settlement) end,
        after_commit: &__MODULE__.publish_after_commit/1
      )
    end

    with {:ok, outcome} <- DomainActions.run_web_lifecycle(human_actor, step) do
      {:ok, browser_card_state(outcome.card, outcome.conversation, human_actor)}
    end
  end

  @doc false
  def resolve_browser_card_in_tx(%Actor{} = actor, card_id, decision, settlement \\ nil)
      when decision in [:confirm, :cancel] do
    now = DateTime.utc_now(:microsecond)

    with {:ok, card_id} <- cast_uuid(card_id, "card_id"),
         :ok <- Ankole.Pod.lock_tree_in_tx(),
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
            now,
            settlement
          )

        :external ->
          resolve_external_browser_in_tx(
            actor,
            initial_conversation,
            snapshot,
            decision,
            now,
            settlement
          )
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

    step = fn settlement ->
      Repo.transact_top_level(
        fn ->
          resolve_native_in_tx(human_actor, conversation_id, card_id, decision, settlement)
        end,
        after_commit: &__MODULE__.publish_after_commit/1
      )
    end

    with {:ok, outcome} <- DomainActions.run_web_lifecycle(human_actor, step) do
      Conversations.get(human_actor, outcome.conversation_id)
    end
  end

  @doc false
  def resolve_native_in_tx(
        %Actor{} = actor,
        conversation_id,
        card_id,
        decision,
        settlement \\ nil
      )
      when decision in [:confirm, :cancel] do
    now = DateTime.utc_now(:microsecond)

    with {:ok, conversation_id} <- Queries.cast_id(conversation_id),
         {:ok, card_id} <- cast_uuid(card_id, "card_id"),
         :ok <- Ankole.Pod.lock_tree_in_tx(),
         %ActionCard{conversation_id: ^conversation_id} = snapshot <- get_card(card_id) do
      resolve_native_after_tree_lock_in_tx(
        actor,
        conversation_id,
        snapshot,
        decision,
        now,
        settlement
      )
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp resolve_native_after_tree_lock_in_tx(
         actor,
         conversation_id,
         snapshot,
         decision,
         now,
         settlement
       ) do
    with :ok <- lock_target_roots_in_tx(snapshot),
         %Conversation{kind: :native} = visible <-
           Native.visible_conversation(actor, conversation_id),
         {:ok, conversation, card, source} <-
           lock_resolution_entities_in_tx(
             Actor.uid(actor),
             snapshot,
             visible,
             [{snapshot.agent_uid, Ankole.Sessions.Key.conversation(conversation_id)}],
             fn -> Native.visible_conversation(actor, conversation_id, lock: true) end
           ) do
      if ActionCard.terminal_status?(card.status) do
        {:ok,
         %{
           conversation_id: conversation.id,
           conversation: conversation,
           card: card,
           side_effects: []
         }}
      else
        with {:ok, outcome} <-
               DomainActions.advance_locked_in_tx(
                 actor,
                 conversation,
                 card,
                 decision,
                 now,
                 settlement,
                 &execute_resolution_in_tx(
                   actor,
                   conversation,
                   card,
                   source,
                   decision,
                   :native,
                   nil,
                   now,
                   &1
                 )
               ) do
          {:ok, Map.put(outcome, :conversation, conversation)}
        end
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp resolve_external_browser_in_tx(
         actor,
         initial_conversation,
         snapshot,
         decision,
         now,
         settlement
       ) do
    with :ok <- lock_target_roots_in_tx(snapshot),
         :ok <- DomainActions.authorize_browser_card_view(actor, initial_conversation, snapshot),
         {:ok, conversation, card, source} <-
           lock_resolution_entities_in_tx(
             Actor.uid(actor),
             snapshot,
             initial_conversation,
             [],
             fn -> Queries.lock_conversation(initial_conversation.id) end
           ) do
      if ActionCard.terminal_status?(card.status) do
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
               DomainActions.advance_locked_in_tx(
                 actor,
                 conversation,
                 card,
                 decision,
                 now,
                 settlement,
                 &execute_resolution_in_tx(
                   actor,
                   conversation,
                   card,
                   source,
                   decision,
                   tier,
                   external_ctx,
                   now,
                   &1
                 )
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
    route =
      if Conversations.peer_exchange(source.conversation_id),
        do: source.data["origin_reply_route"],
        else: Conversations.Route.snapshot(%{signal_id: source.id})

    binding =
      if is_binary(route["binding_name"]) do
        case Signals.get_binding(route["binding_id"]) do
          {:ok, %Binding{} = found} -> found
          _ -> nil
        end
      end

    tier = if binding, do: channel_tier(binding), else: :tier3

    fact = %{
      binding_id: route["binding_id"],
      binding_name: route["binding_name"],
      conversation_id: conversation.id,
      provider_thread_id: route["provider_thread_id"],
      provider_message_id: PreviewStates.get(source).provider_message_id
    }

    {tier, {fact, Actor.uid(actor)}}
  end

  @doc """
  Handles an external IM `action_event` targeting an `action_card:*` interaction
  inside `Observe.accept_action_in_tx` (caller already holds Rank 2 `page-tree`).
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
           Ankole.Sessions.Queue.lock_sessions_in_tx(resolution_sessions(snapshot)),
         %ActionCard{} = card <- lock_card_in_tx(snapshot.id),
         %Signal{} = source <- Signals.lock_signal_in_tx(card.source_signal_id),
         true <- external_surface_matches?(source, fact.provider_message_id, binding) do
      cond do
        ActionCard.terminal_status?(card.status) ->
          maybe_notify_tier2_repeat_in_tx(tier, card, source, fact, sender_key)

        card.status == :executing and DomainActions.active_execution_claim?(card, now) ->
          {:ok, %{status: :duplicate_action}}

        true ->
          resolve_prepared_external_card_in_tx(
            operator_uid,
            channel,
            card,
            source,
            decision,
            tier,
            binding,
            {fact, sender_key},
            now
          )
      end
    else
      false -> {:ok, %{status: :stale_action}}
      nil -> {:ok, %{status: :stale_action}}
      :invalid_decision -> {:error, :invalid_reply_interaction}
      {:error, _} -> {:error, :invalid_reply_interaction}
    end
  end

  defp resolve_prepared_external_card_in_tx(
         operator_uid,
         channel,
         card,
         source,
         decision,
         tier,
         binding,
         {fact, sender_key} = external_ctx,
         now
       ) do
    case resolve_external_operator(operator_uid) do
      {:error, :unauthorized_operator} ->
        maybe_notify_unauthorized_in_tx(
          tier,
          card,
          source,
          fact,
          sender_key,
          "Only linked active workspace members with the required permission can confirm this action card."
        )

      {:ok, human_actor} ->
        if decision == :confirm and card.action_kind == "connectors.tool.call" do
          settlement_tier =
            if tier == :tier1 and binding.adapter == "wecom", do: :tier2, else: tier

          accept_external_connector_confirm_in_tx(
            human_actor,
            channel,
            card,
            source,
            tier,
            settlement_tier,
            external_ctx,
            now
          )
        else
          execute_sync_external_card_in_tx(
            human_actor,
            channel,
            card,
            source,
            decision,
            tier,
            external_ctx,
            now
          )
        end
    end
  end

  defp execute_sync_external_card_in_tx(
         human_actor,
         channel,
         card,
         source,
         decision,
         tier,
         {fact, sender_key} = external_ctx,
         now
       ) do
    case execute_resolution_in_tx(
           human_actor,
           channel,
           card,
           source,
           decision,
           tier,
           external_ctx,
           now,
           nil
         ) do
      {:ok, outcome} ->
        {:ok, %{status: :accepted_action_card, action_card_outcome: outcome}}

      {:error, :conflict} ->
        {:ok, %{status: :duplicate_action}}

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
  end

  defp accept_external_connector_confirm_in_tx(
         human_actor,
         channel,
         card,
         source,
         tier,
         settlement_tier,
         {fact, sender_key} = external_ctx,
         now
       ) do
    case DomainActions.claim_connector_execution_in_tx(human_actor, channel, card, now) do
      {:ok, claimed_card, claim_id} ->
        tenant_id = Repo.tenant_id!()

        effect = fn ->
          Task.Supervisor.start_child(Ankole.Conversations.ActionCardTasks, fn ->
            Repo.with_tenant(tenant_id, fn ->
              settle_external_connector_card(
                human_actor,
                channel,
                claimed_card,
                claim_id,
                settlement_tier,
                external_ctx
              )
            end)
          end)
        end

        {:ok,
         %{
           status: :accepted_action_card,
           action_card_outcome: %{
             conversation_id: channel.id,
             card: claimed_card,
             side_effects: [effect]
           }
         }}

      {:error, :conflict} ->
        {:ok, %{status: :duplicate_action}}

      {:error, :forbidden} ->
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
  end

  defp settle_external_connector_card(
         human_actor,
         channel,
         claimed_card,
         claim_id,
         tier,
         external_ctx
       ) do
    case DomainActions.execute_claimed_connector_card(claimed_card, human_actor) do
      {:error, :conflict} ->
        :ok

      normalized_outcome ->
        case Repo.transact_top_level(
               fn ->
                 now = DateTime.utc_now(:microsecond)

                 with :ok <- Ankole.Pod.lock_tree_in_tx(),
                      :ok <- lock_target_roots_in_tx(claimed_card),
                      {:ok, locked_conv, card, source} <-
                        lock_resolution_entities_in_tx(
                          Actor.uid(human_actor),
                          claimed_card,
                          channel,
                          [],
                          fn -> Queries.lock_conversation(channel.id) end,
                          expected_status: :executing
                        ),
                      true <- DomainActions.claim_matches?(card, claim_id) do
                   execute_resolution_in_tx(
                     human_actor,
                     locked_conv,
                     card,
                     source,
                     :confirm,
                     tier,
                     external_ctx,
                     now,
                     normalized_outcome
                   )
                 else
                   false -> {:ok, %{side_effects: []}}
                   {:unexpected_status, _card} -> {:ok, %{side_effects: []}}
                   nil -> {:error, :not_found}
                   {:error, _} = error -> error
                 end
               end,
               after_commit: &__MODULE__.publish_after_commit/1
             ) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Ankole.Logging.warning(
              "conversations.action_card_external_settle_failed",
              "Failed to settle external connector ActionCard after upstream execution",
              %{
                card_id: claimed_card.id,
                conversation_id: channel.id,
                reason: inspect(reason)
              }
            )

            :ok
        end
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
         now,
         _precomputed
       ) do
    with false <- DomainActions.connector_execution_started?(card, now),
         :ok <- authorize_cancel(actor, conversation, card, source) do
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
    else
      true -> {:error, :conflict}
      error -> error
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
         now,
         precomputed
       ) do
    outcome =
      case DomainActions.apply_in_tx(actor, conversation, card, connector_outcome: precomputed) do
        {:ok, note, domain_effects} -> {:ok, :succeeded, note, domain_effects}
        other -> other
      end

    case outcome do
      {:ok, outcome_kind, note, domain_effects} ->
        target_status = confirmed_outcome_status(outcome_kind)
        checkpoint_option = confirmed_checkpoint_option(target_status)

        with {:ok, card} <- transition_card_in_tx(card, target_status, actor, note, now),
             {:ok, _source} <-
               resolve_interaction_checkpoint_in_tx(
                 source,
                 card.interaction_id,
                 actor,
                 checkpoint_option,
                 note,
                 now
               ),
             :ok <-
               maybe_commit_tier2_settlement_in_tx(channel_mode, card, source, external_ctx, note),
             {:ok, wakeup_signal} <-
               enqueue_executed_wakeup_in_tx(
                 actor,
                 conversation,
                 card,
                 source,
                 note,
                 now
               ) do
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

  defp authorize_cancel(actor, %Conversation{kind: :native} = conversation, card, _source) do
    personal_skill_card? =
      card.action_kind == "library.skill.save" and is_binary(card.payload["agent_uid"])

    if Native.visible_conversation?(actor, conversation.id) and
         (not personal_skill_card? or DomainActions.can_manage_card_target?(actor, card)) and
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
         DomainActions.can_manage_card_target?(actor, card) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp confirmed_outcome_status(:succeeded), do: :executed
  defp confirmed_outcome_status(:failed_uncertain), do: :execution_uncertain
  defp confirmed_outcome_status(:failed_not_sent), do: :failed

  defp confirmed_checkpoint_option(:executed), do: "confirm"
  defp confirmed_checkpoint_option(:execution_uncertain), do: "execution_uncertain"
  defp confirmed_checkpoint_option(:failed), do: "failed"

  defp transition_card_in_tx(card, status, actor, note, now) do
    Ankole.Ash.update(card, :resolve_in_tx, %{
      status: status,
      resolved_by_uid: Actor.uid(actor),
      resolved_by_name: NativeRoom.display_name(actor.principal),
      resolved_at: now,
      resolution_note: note,
      execution_claim_id: nil,
      execution_claim_expires_at: nil
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
        :execution_uncertain -> "Outcome Uncertain"
        :failed -> "Failed"
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

  defp wakeup_header_and_guard(%ActionCard{action_kind: "connectors.tool.call", status: :failed}),
    do:
      {"Failed",
       "\nNOTE: The approved connector call failed before mutating upstream state. Do not assume the action succeeded."}

  defp wakeup_header_and_guard(%ActionCard{
         action_kind: "connectors.tool.call",
         status: :execution_uncertain
       }),
       do:
         {"Outcome Uncertain",
          "\nIMPORTANT: The approved connector call ended with an uncertain upstream outcome. Inspect upstream state before proposing another write."}

  defp wakeup_header_and_guard(%ActionCard{
         action_kind: "connectors.tool.call",
         status: :executed
       }),
       do:
         {"Executed",
          "\nIMPORTANT: This approved connector call has already been executed once with the locked arguments. Do not call this tool again; continue using the result above."}

  defp wakeup_header_and_guard(_card), do: {"Executed", ""}

  defp enqueue_executed_wakeup_in_tx(
         actor,
         conversation,
         %ActionCard{} = card,
         %Signal{} = source,
         note,
         now
       ) do
    {status_label, followup_guard} = wakeup_header_and_guard(card)

    text =
      "[Action Card #{status_label}] #{card.action_kind}: #{card.summary}\nConfirmed by #{NativeRoom.display_name(actor.principal)}. #{note}#{followup_guard}"

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

    peer = Conversations.peer_exchange(source.conversation_id)

    target =
      cond do
        peer ->
          %{agent_uid: card.agent_uid, conversation_id: peer.id}

        conversation.kind == :native ->
          %{agent_uid: card.agent_uid, conversation_id: conversation.id}

        true ->
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
      data:
        Map.merge(if(peer, do: Map.merge(source.data, %{"peer_hop_count" => 0}), else: %{}), %{
          "conversation_id" => conversation.id,
          "action_card_id" => card.id,
          "action_kind" => card.action_kind,
          "status" => to_string(card.status),
          "summary" => card.summary,
          "resolution_note" => note,
          "confirmed_by_uid" => Actor.uid(actor),
          "confirmed_by_name" => NativeRoom.display_name(actor.principal),
          "answered_interaction_id" => card.interaction_id,
          "text" => text
        })
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

  defp resolution_sessions(card, extra \\ []) do
    source = Signals.get_signal!(card.source_signal_id)
    Conversations.peer_session_keys(source) ++ extra
  end

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
    source = Signals.get_signal!(card.source_signal_id)

    peer_uids =
      case Conversations.peer_exchange(source.conversation_id) do
        nil -> []
        peer -> [peer.peer_sender_uid, peer.peer_target_uid]
      end

    skill_uids =
      [card.payload["agent_uid"], card.payload["bind_agent_uid"]]
      |> Enum.filter(&is_binary/1)

    uids =
      ([actor_uid, source.human_uid, card.agent_uid, created_by | added_uids] ++
         grant_uids ++ peer_uids ++ skill_uids)
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

  defp lock_resolution_entities_in_tx(
         actor_uid,
         snapshot,
         conversation_for_principals,
         extra_sessions,
         lock_conversation_fn,
         opts \\ []
       ) do
    expected_status = Keyword.get(opts, :expected_status)

    with :ok <- lock_resolution_principals_in_tx(actor_uid, snapshot, conversation_for_principals),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx(
             resolution_sessions(snapshot, extra_sessions)
           ),
         %Conversation{} = conversation <- lock_conversation_fn.(),
         %ActionCard{} = card <- lock_card_in_tx(snapshot.id) do
      if is_nil(expected_status) or card.status == expected_status do
        case Signals.lock_signal_in_tx(card.source_signal_id) do
          %Signal{} = source -> {:ok, conversation, card, source}
          other -> other
        end
      else
        {:unexpected_status, card}
      end
    end
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

  defp maybe_put_sharing_explain_summaries(payload, _agent_actor, _page, :unchanged), do: payload

  defp maybe_put_sharing_explain_summaries(payload, agent_actor, page, grants)
       when is_list(grants) do
    summaries =
      grants
      |> Enum.flat_map(fn
        %{"principal_uid" => uid} when is_binary(uid) -> [uid]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.take(8)
      |> Enum.flat_map(fn uid ->
        case Sharing.explain_access(agent_actor, page.id, uid, "node_view") do
          {:ok, explained} ->
            [
              %{
                "subject_uid" => explained.subject_uid,
                "subject_name" => explained.subject_name,
                "current_allowed" => explained.allowed,
                "current_role" => explained.effective_role,
                "decision_reason" => explained.decision_reason
              }
            ]

          _ ->
            []
        end
      end)

    if summaries == [], do: payload, else: Map.put(payload, "explain_summaries", summaries)
  end

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed
  end

  defp non_empty_string(_), do: nil
end
