defmodule Ankole.Pod.Access.Explain do
  @moduledoc """
  Projects a deterministic four-stage explanation of a Page access decision
  without diverging from `Ankole.Pod.Access.authorize/4`.
  """

  import Bitwise
  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.Access
  alias Ankole.Pod.Access.Graph
  alias Ankole.Pod.Page
  alias Ankole.Pod.Pages.Tree, as: Pages

  @actions ~w(node_view node_contribute node_edit node_manage node_comment)

  @doc """
  Evaluates whether `subject_actor` may perform `action` on `page` and returns
  the authoritative verdict alongside the four evaluation stages:
  `subject_resolution`, `space_and_trash_gate`, `acl_anchor_chain`, and
  `brain_disclosure_gate`.

  Pass `viewer_actor:` (or `viewer_reachable:`) to redact ancestor and linked
  source-page titles that the inspecting caller cannot view.
  """
  def explain(%Actor{} = subject_actor, %Page{} = page, action, opts \\ [])
      when action in @actions do
    uid = Actor.uid(subject_actor)
    authority_uid = Ankole.Principals.authority_uid(uid)
    principal = subject_actor.principal
    agent_record = load_agent_record(principal)
    agent_type = if agent_record, do: Atom.to_string(agent_record.type)
    subject_name = Ankole.Principals.display_name(principal)

    viewer_reachable = resolve_viewer_reachable(opts)

    auth_opts =
      opts
      |> Keyword.drop([:viewer_actor, :viewer_reachable])
      |> default_trash_option(action)

    context_result = Graph.context_snapshot(subject_actor, auth_opts)

    auth_opts_with_ctx =
      case context_result do
        {:ok, ctx} -> Keyword.put(auth_opts, :context, ctx)
        _ -> auth_opts
      end

    verdict = Access.authorize(subject_actor, page, action, auth_opts_with_ctx)
    allowed = match?({:ok, _}, verdict)

    path =
      case Pages.path(page) do
        {:ok, nodes} -> nodes
        _ -> [page]
      end

    admin_override? = administrative_override?(subject_actor)

    stage_1 =
      build_subject_stage(
        uid,
        authority_uid,
        principal,
        agent_type,
        admin_override?,
        context_result
      )

    stage_2 =
      build_space_and_trash_stage(
        page,
        path,
        action,
        auth_opts,
        principal,
        stage_1.status
      )

    {stage_3, effective_role, effective_actions} =
      build_acl_anchor_stage(
        subject_actor,
        authority_uid,
        page,
        path,
        action,
        auth_opts_with_ctx,
        context_result,
        viewer_reachable,
        stage_1.status,
        stage_2.status
      )

    stage_4 =
      build_brain_disclosure_stage(
        subject_actor,
        page,
        path,
        action,
        auth_opts_with_ctx,
        allowed,
        stage_1.status,
        stage_2.status,
        stage_3.status
      )

    stages = [stage_1, stage_2, stage_3, stage_4]

    decision_reason =
      derive_decision_reason(allowed, action, effective_role, stages)

    %{
      subject_uid: uid,
      authority_uid: authority_uid,
      subject_name: subject_name,
      subject_kind: Atom.to_string(principal.type),
      agent_type: agent_type,
      action: action,
      allowed: allowed,
      effective_role: effective_role,
      effective_actions: effective_actions,
      decision_reason: decision_reason,
      stages: stages
    }
  end

  defp default_trash_option(opts, action) do
    if action == "node_view" and not Keyword.has_key?(opts, :trash),
      do: Keyword.put(opts, :trash, :self),
      else: opts
  end

  defp load_agent_record(%{type: :agent, agent: %Ankole.Principals.Agent{} = agent}), do: agent

  defp load_agent_record(%{type: :agent, uid: uid}) do
    case Ankole.Principals.get_agent_record(uid) do
      {:ok, %Ankole.Principals.Agent{} = agent} -> agent
      _ -> nil
    end
  end

  defp load_agent_record(_), do: nil

  defp resolve_viewer_reachable(opts) do
    cond do
      is_map(opts[:viewer_reachable]) ->
        opts[:viewer_reachable]

      match?(%Actor{}, opts[:viewer_actor]) ->
        case Graph.reachable_anchors(opts[:viewer_actor]) do
          {:ok, reachable} -> reachable
          _ -> %{}
        end

      true ->
        nil
    end
  end

  defp administrative_override?(%Actor{authn: %{"drive_admin_action" => action}} = actor)
       when action in ["read", "update", "delete"] do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :site_console),
         {:ok, tenant_id} <- Ankole.Tenants.privileged_id() do
      Ankole.Repo.with_tenant(tenant_id, fn ->
        Ankole.AuthZ.authorize(actor, "site_console:drive", action) == :ok
      end)
    else
      _ -> false
    end
  end

  defp administrative_override?(_actor), do: false

  defp build_subject_stage(
         uid,
         authority_uid,
         principal,
         agent_type,
         true,
         _context_result
       ) do
    %{
      id: "subject_resolution",
      status: "short_circuit",
      summary: "Site Console administrative authority grants access directly.",
      details: %{
        "uid" => uid,
        "authority_uid" => authority_uid,
        "principal_type" => Atom.to_string(principal.type),
        "agent_type" => agent_type,
        "membership" => Atom.to_string(principal.membership),
        "administrative" => true
      }
    }
  end

  defp build_subject_stage(
         uid,
         authority_uid,
         principal,
         agent_type,
         false,
         {:error, _reason}
       ) do
    %{
      id: "subject_resolution",
      status: "fail",
      summary: "Subject @#{uid} is inactive or restricted from Drive operations.",
      details: %{
        "uid" => uid,
        "authority_uid" => authority_uid,
        "principal_type" => Atom.to_string(principal.type),
        "agent_type" => agent_type,
        "membership" => Atom.to_string(principal.membership),
        "status" => Atom.to_string(principal.status)
      }
    }
  end

  defp build_subject_stage(
         uid,
         authority_uid,
         principal,
         agent_type,
         false,
         {:ok, {snapshot, evaluated}}
       ) do
    group_count = length(evaluated["effectiveGroupIDs"] || [])
    can_manage_space = snapshot["canManageSpace"] == true

    summary =
      cond do
        agent_type == "personal_assistant" and authority_uid != uid ->
          "Personal assistant (@#{uid}) evaluates Drive permissions through owner @#{authority_uid}."

        principal.type == :agent ->
          "AI colleague (@#{uid}) evaluates Drive permissions under its own agent grants."

        principal.membership == :guest ->
          "Guest account (@#{uid}) can access explicitly shared Space pages only."

        can_manage_space ->
          "Space administrator (@#{uid}) active with #{group_count} group membership(s)."

        true ->
          "Workspace member (@#{uid}) active with #{group_count} group membership(s)."
      end

    %{
      id: "subject_resolution",
      status: "pass",
      summary: summary,
      details: %{
        "uid" => uid,
        "authority_uid" => authority_uid,
        "principal_type" => Atom.to_string(principal.type),
        "agent_type" => agent_type,
        "membership" => Atom.to_string(principal.membership),
        "can_manage_space" => can_manage_space,
        "effective_group_count" => group_count
      }
    }
  end

  defp build_space_and_trash_stage(page, path, action, auth_opts, principal, stage_1_status) do
    root = hd(path)
    trashed_self = not is_nil(page.deleted_at)
    trashed_ancestor = Enum.any?(Enum.drop(path, -1), &(not is_nil(&1.deleted_at)))
    trash_mode = Keyword.get(auth_opts, :trash, false)

    scope_kind =
      cond do
        Map.get(root, :conversation_id) -> "conversation"
        root.private_owner_uid -> "private"
        root.system_key == "ankole_brain" -> "brain"
        true -> "space"
      end

    visible_ok? =
      case trash_mode do
        true -> true
        :self -> not trashed_ancestor
        _ -> not trashed_ancestor and not trashed_self
      end

    guest_blocked_private? =
      principal.membership == :guest and not is_nil(root.private_owner_uid)

    base_details = %{
      "scope_kind" => scope_kind,
      "private_owner_uid" => root.private_owner_uid,
      "trashed_self" => trashed_self,
      "trashed_ancestor" => trashed_ancestor,
      "guest_blocked_private" => guest_blocked_private?
    }

    cond do
      not visible_ok? and trashed_ancestor ->
        %{
          id: "space_and_trash_gate",
          status: "fail",
          summary: "Denied because an ancestor page is in Trash.",
          details: base_details
        }

      not visible_ok? and trashed_self ->
        %{
          id: "space_and_trash_gate",
          status: "fail",
          summary: "Page is in Trash; #{action_label(action)} requires restoring the page first.",
          details: base_details
        }

      stage_1_status in ["fail", "short_circuit"] ->
        %{
          id: "space_and_trash_gate",
          status: "skip",
          summary: "Skipped because subject resolution already decided access.",
          details: base_details
        }

      guest_blocked_private? ->
        %{
          id: "space_and_trash_gate",
          status: "fail",
          summary: "Guests cannot access pages inside a member's Private space.",
          details: base_details
        }

      trashed_self and trash_mode in [:self, true] ->
        %{
          id: "space_and_trash_gate",
          status: "pass",
          summary: "Page is in Trash; trash inspection permits checking ACL grants.",
          details: base_details
        }

      true ->
        %{
          id: "space_and_trash_gate",
          status: "pass",
          summary: "Live page in #{scope_label(scope_kind, root.private_owner_uid)}.",
          details: base_details
        }
    end
  end

  defp build_acl_anchor_stage(
         _subject_actor,
         _authority_uid,
         _page,
         path,
         _action,
         _auth_opts,
         _context_result,
         viewer_reachable,
         stage_1_status,
         stage_2_status
       )
       when stage_1_status in ["fail", "short_circuit"] or stage_2_status != "pass" do
    broken = broken_inheritance_node(path, viewer_reachable)

    stage = %{
      id: "acl_anchor_chain",
      status: "skip",
      summary:
        if(stage_1_status == "short_circuit",
          do: "Bypassed by administrative authority.",
          else: "Skipped because an earlier gate blocked access."
        ),
      details: %{
        "effective_role" => if(stage_1_status == "short_circuit", do: "manage", else: nil),
        "effective_actions" => if(stage_1_status == "short_circuit", do: @actions, else: []),
        "broken_inheritance" => broken,
        "matching_sources" => []
      }
    }

    role = if stage_1_status == "short_circuit", do: "manage", else: nil
    actions = if stage_1_status == "short_circuit", do: @actions, else: []
    {stage, role, actions}
  end

  defp build_acl_anchor_stage(
         subject_actor,
         authority_uid,
         page,
         path,
         action,
         auth_opts,
         {:ok, {snapshot, evaluated}},
         viewer_reachable,
         "pass",
         "pass"
       ) do
    page_opts =
      auth_opts
      |> Keyword.put(:target_ids, [page.acl_anchor_id])
      |> then(fn o ->
        if Keyword.get(o, :trash, false), do: Keyword.put(o, :trash_page_id, page.id), else: o
      end)

    reachable =
      case Graph.reachable_anchors(subject_actor, page_opts) do
        {:ok, rows} -> rows
        _ -> %{}
      end

    bits = Graph.page_bits(page, reachable)
    effective_role = Graph.role_for_actions(bits)
    effective_actions = Graph.project_permissions(page, bits).actions
    has_action? = band(bits, Graph.action_bit(action)) != 0

    broken = broken_inheritance_node(path, viewer_reachable)

    matching_sources =
      trace_matching_sources(
        subject_actor,
        authority_uid,
        page,
        path,
        action,
        snapshot,
        evaluated,
        viewer_reachable
      )

    summary =
      if has_action? do
        source_labels = Enum.map(matching_sources, & &1["label"]) |> Enum.uniq()

        via =
          if source_labels == [],
            do: "inherited anchor chain",
            else: Enum.join(source_labels, ", ")

        "Allowed (#{effective_role || action_label(action)}) via #{via}."
      else
        root = hd(path)

        cond do
          is_map(broken) ->
            "Inheritance is disabled on #{broken["title"]}, and no grant gives @#{authority_uid} #{action_label(action)}."

          not is_nil(root.private_owner_uid) ->
            "Private page owned by @#{root.private_owner_uid}; @#{authority_uid} has not been granted #{action_label(action)}."

          effective_role != nil ->
            "Current role is #{effective_role}, which does not include #{action_label(action)}."

          true ->
            "No Space baseline, inherited, direct, or group grant gives @#{authority_uid} #{action_label(action)}."
        end
      end

    stage = %{
      id: "acl_anchor_chain",
      status: if(has_action?, do: "pass", else: "fail"),
      summary: summary,
      details: %{
        "effective_role" => effective_role,
        "effective_actions" => effective_actions,
        "inherit_permissions" => page.inherit_permissions,
        "broken_inheritance" => broken,
        "matching_sources" => matching_sources
      }
    }

    {stage, effective_role, effective_actions}
  end

  defp trace_matching_sources(
         subject_actor,
         authority_uid,
         page,
         path,
         action,
         snapshot,
         evaluated,
         viewer_reachable
       ) do
    unbroken_chain = unbroken_inheritance_chain(path)
    root = hd(path)

    groups = MapSet.new(evaluated["effectiveGroupIDs"] || [])

    root_sources =
      if hd(unbroken_chain).id == root.id do
        root_matching_sources(root, authority_uid, Graph.action_bit(action), snapshot, evaluated)
      else
        []
      end

    chain_ids = Enum.map(unbroken_chain, & &1.id)
    candidates = Access.grants(target_node_id: [in: chain_ids], action: action)

    ctx = %{
      subject_actor: subject_actor,
      authority_uid: authority_uid,
      page: page,
      viewer_reachable: viewer_reachable,
      satisfied: MapSet.new(evaluated["satisfiedGrantIDs"] || []),
      groups: groups,
      group_names: load_group_names(MapSet.to_list(groups)),
      chain_by_id: Map.new(unbroken_chain, &{&1.id, &1}),
      source_pages: load_grant_source_pages(candidates)
    }

    root_sources ++ Enum.flat_map(candidates, &grant_matching_sources(&1, ctx))
  end

  defp root_matching_sources(root, authority_uid, required_bit, snapshot, evaluated) do
    space_bits = Graph.snapshot_space_bits_for_explain(snapshot, evaluated)
    conversation_ids = Map.get(snapshot, "conversationIDs", [])

    space_root? =
      is_nil(root.parent_id) and is_nil(root.private_owner_uid) and
        is_nil(Map.get(root, :conversation_id)) and root.inherit_permissions

    []
    |> maybe_append(
      space_root? and snapshot["canManageSpace"] == true,
      %{
        "kind" => "space_admin",
        "label" => "Space administrator baseline"
      }
    )
    |> maybe_append(
      space_root? and snapshot["canManageSpace"] != true and band(space_bits, required_bit) != 0,
      %{
        "kind" => "space_default",
        "label" => "Workspace Space access"
      }
    )
    |> maybe_append(
      not is_nil(Map.get(root, :conversation_id)) and
        Map.get(root, :conversation_id) in conversation_ids and
        band(7, required_bit) != 0,
      %{
        "kind" => "conversation_participant",
        "label" => "Conversation participant access"
      }
    )
    |> maybe_append(
      root.private_owner_uid == authority_uid,
      %{
        "kind" => "private_owner",
        "label" => "Private space owner (@#{authority_uid})"
      }
    )
  end

  defp load_grant_source_pages(candidates) do
    source_node_ids =
      candidates
      |> Enum.map(& &1.source_node_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if source_node_ids == [] do
      %{}
    else
      Page
      |> Ash.Query.filter(id in ^source_node_ids and is_nil(deleted_at))
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.id, &1})
    end
  end

  defp grant_matching_sources(grant, ctx) do
    applies_to_page? =
      grant.target_node_id == ctx.page.id or (grant.target_scope || "container") == "container"

    condition_ok? = grant.condition == "true" or MapSet.member?(ctx.satisfied, grant.id)

    if applies_to_page? and condition_ok? do
      grant_source(grant, grant_location_suffix(grant, ctx), ctx)
    else
      []
    end
  end

  defp grant_location_suffix(grant, ctx) do
    if grant.target_node_id == ctx.page.id do
      "on this page"
    else
      on_node = Map.get(ctx.chain_by_id, grant.target_node_id)
      "inherited from #{redacted_title(on_node, ctx.viewer_reachable)}"
    end
  end

  defp grant_source(grant, location_suffix, ctx) do
    cond do
      grant.principal_uid == ctx.authority_uid ->
        [
          %{
            "kind" => "direct_grant",
            "target_node_id" => grant.target_node_id,
            "conditional" => grant.condition != "true",
            "label" => "Direct grant to @#{ctx.authority_uid} (#{location_suffix})"
          }
        ]

      not is_nil(grant.group_id) and MapSet.member?(ctx.groups, grant.group_id) ->
        group_label = Map.get(ctx.group_names, grant.group_id, "group")

        [
          %{
            "kind" => "group_grant",
            "group_id" => grant.group_id,
            "target_node_id" => grant.target_node_id,
            "conditional" => grant.condition != "true",
            "label" => "Group grant via #{group_label} (#{location_suffix})"
          }
        ]

      not is_nil(grant.source_node_id) ->
        linked_grant_source(grant, location_suffix, ctx)

      true ->
        []
    end
  end

  defp linked_grant_source(grant, location_suffix, ctx) do
    with %Page{} = src_page <- Map.get(ctx.source_pages, grant.source_node_id),
         {:ok, _} <- Access.authorize(ctx.subject_actor, src_page, grant.source_action) do
      [
        %{
          "kind" => "source_node_grant",
          "source_node_id" => src_page.id,
          "target_node_id" => grant.target_node_id,
          "label" =>
            "Linked grant from #{redacted_title(src_page, ctx.viewer_reachable)} (#{location_suffix})"
        }
      ]
    else
      _ -> []
    end
  end

  defp unbroken_inheritance_chain(path) do
    path
    |> Enum.reverse()
    |> Enum.reduce_while([], fn node, acc ->
      next = [node | acc]

      if is_nil(node.parent_id) or node.inherit_permissions do
        {:cont, next}
      else
        {:halt, next}
      end
    end)
  end

  defp broken_inheritance_node(path, viewer_reachable) do
    path
    |> Enum.reverse()
    |> Enum.find(fn node -> not is_nil(node.parent_id) and not node.inherit_permissions end)
    |> case do
      nil ->
        nil

      node ->
        %{
          "page_id" => node.id,
          "is_self" => node.id == List.last(path).id,
          "title" => redacted_title(node, viewer_reachable)
        }
    end
  end

  defp redacted_title(nil, _viewer_reachable), do: "ancestor page"

  defp redacted_title(node, nil), do: non_empty_title(node)

  defp redacted_title(node, viewer_reachable) when is_map(viewer_reachable) do
    if band(Graph.page_bits(node, viewer_reachable), 1) != 0 do
      non_empty_title(node)
    else
      "a restricted page"
    end
  end

  defp non_empty_title(node) do
    title = Map.get(node, :title) || Map.get(node, :name) || ""
    if String.trim(title) == "", do: "Untitled", else: title
  end

  defp load_group_names([]), do: %{}

  defp load_group_names(group_ids) do
    Ankole.AuthZ.list_principal_groups()
    |> Enum.filter(&(&1.id in group_ids))
    |> Map.new(&{&1.id, &1.display_name || &1.name})
  end

  defp build_brain_disclosure_stage(
         subject_actor,
         page,
         path,
         action,
         auth_opts,
         allowed,
         stage_1_status,
         stage_2_status,
         stage_3_status
       ) do
    root = hd(path)
    turn_ref = brain_turn_ref(subject_actor)

    applicable? =
      not is_nil(turn_ref) and page.type in [:knowledge, :file] and
        root.system_key == "ankole_brain"

    cond do
      not applicable? ->
        %{
          id: "brain_disclosure_gate",
          status: "skip",
          summary: "Not applicable outside an Agent turn on a Brain node.",
          details: %{"applicable" => false}
        }

      stage_1_status != "pass" or stage_2_status != "pass" or stage_3_status != "pass" ->
        %{
          id: "brain_disclosure_gate",
          status: "skip",
          summary: "Skipped because an earlier gate already decided access.",
          details: %{"applicable" => true}
        }

      true ->
        case Ankole.Brain.RequestContext.build(Actor.uid(subject_actor), %{
               "signal_id" => turn_ref.signal_id
             }) do
          {:ok, brain_ctx} ->
            brain_disclosure_verdict(
              brain_ctx.disclosure,
              subject_actor,
              page,
              action,
              auth_opts,
              allowed
            )

          _ ->
            %{
              id: "brain_disclosure_gate",
              status: if(allowed, do: "pass", else: "fail"),
              summary:
                if(allowed,
                  do: "Brain turn context verified.",
                  else: "Unable to verify Brain turn disclosure context."
                ),
              details: %{"applicable" => true}
            }
        end
    end
  end

  defp brain_turn_ref(subject_actor) do
    case subject_actor.turn_authority do
      {ref, _}
      when is_struct(ref, Ankole.Sessions.RunRef) or
             is_struct(ref, Ankole.Sessions.JobTurnRef) ->
        ref

      _ ->
        nil
    end
  end

  defp brain_disclosure_verdict(disclosure, subject_actor, page, action, auth_opts, allowed) do
    recipients = disclosure_recipients(disclosure)

    missing_view_uids =
      Enum.filter(
        recipients,
        &principal_lacks_action?(&1, subject_actor, page, "node_view", auth_opts)
      )

    requester_action = Keyword.get(auth_opts, :requester_action, action)

    missing_requester_action? =
      is_binary(disclosure[:asker_uid]) and requester_action != "node_view" and
        principal_lacks_action?(
          disclosure.asker_uid,
          subject_actor,
          page,
          requester_action,
          auth_opts
        )

    details = %{
      "applicable" => true,
      "mode" => Atom.to_string(disclosure.mode),
      "asker_uid" => disclosure[:asker_uid],
      "recipient_count" => length(recipients),
      "missing_reader_uids" => missing_view_uids,
      "missing_requester_action" => missing_requester_action?
    }

    if allowed do
      %{
        id: "brain_disclosure_gate",
        status: "pass",
        summary:
          "All conversation recipients (#{length(recipients)}) are authorized to view this Brain node.",
        details: details
      }
    else
      summary =
        cond do
          disclosure.mode == :strict and recipients == [] ->
            "Blocked by strict Brain disclosure because the conversation audience has no verified workspace readers."

          missing_view_uids != [] ->
            "Blocked to prevent Brain disclosure leak: #{Enum.map_join(missing_view_uids, ", ", &("@" <> &1))} cannot view this node."

          missing_requester_action? ->
            "Blocked because requester @#{disclosure[:asker_uid]} lacks #{action_label(requester_action)} on this Brain node."

          true ->
            "Blocked by Brain conversation disclosure boundary."
        end

      %{
        id: "brain_disclosure_gate",
        status: "fail",
        summary: summary,
        details: details
      }
    end
  end

  defp principal_lacks_action?(uid, subject_actor, page, action, auth_opts) do
    case Ankole.Principals.get_principal(uid) do
      {:ok, principal} ->
        actor = Actor.new(principal, authn: subject_actor.authn)
        not match?({:ok, _}, Access.authorize(actor, page, action, auth_opts))

      _ ->
        true
    end
  end

  defp disclosure_recipients(%{mode: :strict} = disclosure),
    do: Enum.uniq(List.wrap(disclosure[:asker_uid]) ++ (disclosure[:present_uids] || []))

  defp disclosure_recipients(disclosure),
    do: List.wrap(disclosure[:asker_uid])

  defp derive_decision_reason(true, _action, effective_role, stages) do
    case Enum.find(stages, &(&1.status == "short_circuit")) do
      %{} = stage ->
        stage.summary

      nil ->
        case Enum.find(stages, &(&1.id == "acl_anchor_chain")) do
          %{} = acl -> acl.summary
          nil -> "Allowed (#{effective_role || "authorized"})."
        end
    end
  end

  defp derive_decision_reason(false, action, _effective_role, stages) do
    case Enum.find(stages, &(&1.status == "fail")) do
      %{} = failed -> failed.summary
      nil -> "Access denied for #{action_label(action)}."
    end
  end

  defp action_label("node_view"), do: "view"
  defp action_label("node_contribute"), do: "contribute"
  defp action_label("node_edit"), do: "edit"
  defp action_label("node_manage"), do: "manage"
  defp action_label("node_comment"), do: "comment"
  defp action_label(other), do: other

  defp scope_label("private", owner_uid) when is_binary(owner_uid),
    do: "@#{owner_uid}'s Private space"

  defp scope_label("private", _), do: "Private space"
  defp scope_label("conversation", _), do: "Conversation workspace"
  defp scope_label("brain", _), do: "Ankole Brain"
  defp scope_label(_, _), do: "Workspace Space"

  defp maybe_append(list, true, item), do: list ++ [item]
  defp maybe_append(list, _, _item), do: list
end
