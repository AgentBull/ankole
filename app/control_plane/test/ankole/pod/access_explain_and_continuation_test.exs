defmodule Ankole.Pod.AccessExplainAndContinuationTest do
  use Ankole.DataCase, async: false
  import Ankole.BrainFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ.Actor
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Conversations
  alias Ankole.Conversations.ActionCards
  alias Ankole.Pod.{Access, Pages, RPCBroker}
  alias Ankole.Pod.Access.{BlockedWaits, Explain}
  alias Ankole.Pod.Chat.Presentation
  alias Ankole.RuntimeFabric.V1.PodRequest
  alias Ankole.Sessions.Presentation.Execution

  setup do
    {:ok, _} = SchemaPacks.install_packs([])
    owner = human_fixture(%{display_name: "Owner Alice"}).principal
    member = human_fixture(%{display_name: "Member Bob"}).principal
    outsider = human_fixture(%{display_name: "Outsider Carol"}).principal
    guest = human_fixture(%{display_name: "Guest Dan", membership: :guest}).principal

    colleague =
      agent_fixture(%{
        type: :ai_colleague,
        display_name: "Analyst Bot",
        owner_principal_uid: owner.uid
      }).principal

    owner_pa =
      agent_fixture(%{
        type: :personal_assistant,
        display_name: "Owner PA",
        owner_principal_uid: owner.uid
      }).principal

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    # Grant human members permission to chat with colleague
    for h <- [owner, member, outsider] do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: h.uid,
          resource_pattern: "agent:#{colleague.uid}",
          action: "chat"
        })
    end

    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{name: "finance-team", display_name: "Finance Team"})

    {:ok, _} = Ankole.AuthZ.add_principal_to_group(member.uid, group.id)

    %{
      owner: owner,
      owner_actor: actor_fixture(owner),
      owner_pa: owner_pa,
      member: member,
      member_actor: actor_fixture(member),
      outsider: outsider,
      outsider_actor: actor_fixture(outsider),
      guest: guest,
      guest_actor: actor_fixture(guest),
      colleague: colleague,
      colleague_actor: actor_fixture(colleague),
      group: group
    }
  end

  defp assert_explain_matches_authorize!(subject_actor, page, action, opts \\ []) do
    auth_opts = Keyword.drop(opts, [:viewer_actor, :viewer_reachable])
    expected = match?({:ok, _}, Access.authorize(subject_actor, page, action, auth_opts))
    explained = Explain.explain(subject_actor, page, action, opts)

    assert explained.allowed == expected,
           "Expected Explain.allowed (#{explained.allowed}) == Access.authorize (#{expected}) for #{Actor.uid(subject_actor)} #{action} on #{page.id}"

    assert length(explained.stages) == 4
    explained
  end

  test "Explain matches Access.authorize across Space, Private, Guest, PA, Group, Source-Node, Broken Inheritance, Trash, and Brain Disclosure",
       ctx do
    # 1. Public Space page
    {:ok, space_page} = Pages.create(ctx.owner_actor, %{title: "Company Handbook"})

    for actor <- [
          ctx.owner_actor,
          ctx.member_actor,
          ctx.outsider_actor,
          actor_fixture(ctx.owner_pa)
        ],
        action <- Access.page_actions() do
      assert_explain_matches_authorize!(actor, space_page, action)
    end

    # Guest denied on unshared Space page, then allowed once granted view
    guest_denied = assert_explain_matches_authorize!(ctx.guest_actor, space_page, "node_view")
    refute guest_denied.allowed

    {:ok, _} =
      Pages.update_sharing(ctx.owner_actor, space_page.id, %{
        upserts: [%{principal_uid: ctx.guest.uid, role: :view, target_scope: "container"}]
      })

    {:ok, space_page} = Pages.fetch(space_page.id)
    guest_allowed = assert_explain_matches_authorize!(ctx.guest_actor, space_page, "node_view")
    assert guest_allowed.allowed

    # Guest cannot probe unseen workspace subjects via Pages.explain_sharing
    assert {:error, :not_found} =
             Pages.explain_sharing(ctx.guest_actor, space_page.id, ctx.outsider.uid, :node_view)

    # 2. Private page: owner & owner's PA allowed; member, colleague & guest denied
    {:ok, private_page} =
      Pages.create(ctx.owner_actor, %{
        title: "Secret M&A Memo",
        private_owner_uid: ctx.owner.uid
      })

    owner_explained =
      assert_explain_matches_authorize!(ctx.owner_actor, private_page, "node_manage")

    assert owner_explained.allowed

    pa_explained =
      assert_explain_matches_authorize!(actor_fixture(ctx.owner_pa), private_page, "node_edit")

    assert pa_explained.allowed
    assert pa_explained.authority_uid == ctx.owner.uid

    guest_priv = assert_explain_matches_authorize!(ctx.guest_actor, private_page, "node_view")
    refute guest_priv.allowed
    assert Enum.find(guest_priv.stages, &(&1.id == "space_and_trash_gate")).status == "fail"

    colleague_priv =
      assert_explain_matches_authorize!(ctx.colleague_actor, private_page, "node_view")

    refute colleague_priv.allowed

    # 3. Broken inheritance + group grant + ancestor title redaction
    {:ok, secret_parent} =
      Pages.create(ctx.owner_actor, %{
        title: "Classified Parent Folder"
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, secret_parent.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.owner.uid, role: "manage"}]
      })

    {:ok, child_page} =
      Pages.create(ctx.owner_actor, %{
        title: "Finance Subpage",
        parent_id: secret_parent.id
      })

    {:ok, _} =
      Pages.update_sharing(ctx.owner_actor, child_page.id, %{
        inherit_permissions: false,
        upserts: [%{group_id: ctx.group.id, role: :edit, target_scope: "container"}]
      })

    {:ok, child_page} = Pages.fetch(child_page.id)

    member_group =
      assert_explain_matches_authorize!(ctx.member_actor, child_page, "node_edit",
        viewer_actor: ctx.member_actor
      )

    assert member_group.allowed

    outsider_broken =
      assert_explain_matches_authorize!(ctx.outsider_actor, child_page, "node_view",
        viewer_actor: ctx.member_actor
      )

    refute outsider_broken.allowed
    assert Enum.find(outsider_broken.stages, &(&1.id == "acl_anchor_chain")).status == "fail"

    # Source-node linked grant
    {:ok, linked_target} =
      Pages.create(ctx.owner_actor, %{
        title: "Linked Appendix",
        private_owner_uid: ctx.owner.uid
      })

    {:ok, sharing} = Pages.sharing(ctx.owner_actor, linked_target.id)

    {:ok, _} =
      Pages.set_sharing(ctx.owner_actor, linked_target.id, %{
        sharing_version: sharing.sharing_version,
        inherit_permissions: true,
        grants: [
          %{
            source_node_id: child_page.id,
            source_action: "node_edit",
            target_scope: "container",
            condition: "true",
            role: :view
          }
        ]
      })

    {:ok, linked_target} = Pages.fetch(linked_target.id)
    linked_ok = assert_explain_matches_authorize!(ctx.member_actor, linked_target, "node_view")
    assert linked_ok.allowed

    linked_denied =
      assert_explain_matches_authorize!(ctx.outsider_actor, linked_target, "node_view")

    refute linked_denied.allowed

    # 4. Trash gate: trashed self allows node_view to authorized reader, denies node_edit; trashed ancestor denies node_view
    {:ok, trash_parent} = Pages.create(ctx.owner_actor, %{title: "Archive Folder"})

    {:ok, trash_child} =
      Pages.create(ctx.owner_actor, %{title: "Archive Note", parent_id: trash_parent.id})

    {:ok, trashed_child} = Pages.delete(ctx.owner_actor, trash_child.id)

    trash_view = assert_explain_matches_authorize!(ctx.owner_actor, trashed_child, "node_view")
    assert trash_view.allowed
    trash_edit = assert_explain_matches_authorize!(ctx.owner_actor, trashed_child, "node_edit")
    refute trash_edit.allowed

    {:ok, _} = Pages.restore(ctx.owner_actor, trashed_child.id)
    {:ok, _} = Pages.delete(ctx.owner_actor, trash_parent.id)
    {:ok, child_under_trashed} = Pages.fetch(trash_child.id)

    ancestor_trashed =
      assert_explain_matches_authorize!(ctx.owner_actor, child_under_trashed, "node_view")

    refute ancestor_trashed.allowed

    # 5. Brain turn disclosure gate: colleague has view on restricted Brain node, but asker (outsider) does not
    {:ok, brain_node} =
      page_fixture_result(
        %{slug: "projects/stealth", type: "project", title: "Stealth Initiative"},
        ctx.owner.uid
      )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, brain_node.id, %{
        inherit_permissions: false,
        grants: [
          %{principal_uid: ctx.owner.uid, role: "manage"},
          %{principal_uid: ctx.colleague.uid, role: "view"}
        ]
      })

    {:ok, brain_page} = Pages.fetch(brain_node.id)

    {:ok, conv_detail} =
      Ankole.ConversationsFixtures.create(ctx.outsider.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.colleague.uid,
        text: "Tell me about Stealth Initiative"
      })

    [signal] =
      Ankole.Signals.list_signals!(
        query: [filter: [conversation_id: conv_detail.conversation.id]]
      )

    run_ref = %Ankole.Sessions.RunRef{
      agent_uid: ctx.colleague.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    turn_actor = Actor.new(ctx.colleague, turn_authority: {run_ref, ctx.colleague.uid})
    disclosure_denied = assert_explain_matches_authorize!(turn_actor, brain_page, "node_view")
    refute disclosure_denied.allowed
    stage_4 = Enum.find(disclosure_denied.stages, &(&1.id == "brain_disclosure_gate"))
    assert stage_4.status == "fail"
    assert ctx.outsider.uid in stage_4.details["missing_reader_uids"]

    # 6. ActionCards pod.page.set_sharing embeds explain_summaries
    {:ok, owner_conv} =
      Ankole.ConversationsFixtures.create(ctx.owner.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.owner_pa.uid,
        text: "Share Secret M&A Memo with Analyst Bot"
      })

    [pa_signal] =
      Ankole.Signals.list_signals!(query: [filter: [conversation_id: owner_conv.conversation.id]])

    run = %{
      agent_uid: ctx.owner_pa.uid,
      signal_id: pa_signal.id,
      event: pa_signal
    }

    assert {:ok, draft} =
             ActionCards.prepare_draft(run, nil, %{
               "action_kind" => "pod.page.set_sharing",
               "summary" => "Grant Analyst Bot view access",
               "node_id" => private_page.id,
               "grants" => [%{"principal_uid" => ctx.colleague.uid, "role" => "view"}]
             })

    assert [%{"subject_uid" => subject_uid, "current_allowed" => false}] =
             draft["payload"]["explain_summaries"]

    assert subject_uid == ctx.colleague.uid
  end

  test "blocked page node_view turn redacts page title for unauthorized viewers and wakes via signal.action.invoked when manager grants access",
       ctx do
    {:ok, restricted_page} =
      Pages.create(ctx.owner_actor, %{
        title: "Board Compensation Plan",
        private_owner_uid: ctx.owner.uid
      })

    # Create a group room with owner (has node_manage), member (lacks node_view), and colleague (@analyst)
    {:ok, room_detail} =
      Ankole.ConversationsFixtures.create(ctx.owner.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.colleague.uid,
        participant_uids: [ctx.member.uid],
        text: "Summarize the Board Compensation Plan"
      })

    conversation = room_detail.conversation

    [signal] =
      Ankole.Signals.list_signals!(query: [filter: [conversation_id: conversation.id]])

    run_ref = %Ankole.Sessions.RunRef{
      agent_uid: ctx.colleague.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    # Colleague attempts `pages.read` via RPCBroker and gets denied
    request = %PodRequest{
      operation: "pages.read",
      params_json: Torque.encode!(%{"id" => restricted_page.id})
    }

    rpc_ctx = %{worker_id: ctx.colleague.uid, request_id: "req-1"}
    assert {:error, %{"code" => code}} = RPCBroker.handle_read(run_ref, request, rpc_ctx)
    assert code in ["not_found", "forbidden"]

    # BlockedWaits recorded the wait and Execution marks the ankole-pod step "blocked"
    blocked_ids = BlockedWaits.blocked_page_ids_for_signal(signal.id)
    assert MapSet.member?(blocked_ids, restricted_page.id)

    at = DateTime.utc_now(:second)

    execution =
      Execution.from_chain(
        [
          %{
            id: "round-1",
            content: [
              %{
                "type" => "function_call",
                "call_id" => "call_pod",
                "name" => "command",
                "arguments" =>
                  Torque.encode!(%{
                    "command" => "ankole-pod pages.read --id #{restricted_page.id}"
                  })
              },
              %{
                "type" => "function_call_output",
                "call_id" => "call_pod",
                "output" => "exit_code=1\nduration=12ms\n{\"code\":\"forbidden\"}"
              }
            ],
            metadata: %{},
            inserted_at: at,
            updated_at: at
          }
        ],
        %{},
        "completed",
        blocked_page_ids: blocked_ids
      )

    assert [%{"status" => "blocked"}] = execution["steps"]

    post_turn_reply!(
      ctx.colleague.uid,
      conversation,
      signal,
      "I need view access to that page to summarize it.",
      execution
    )

    # Verify DB row stores NO page_title in rich_content
    raw_msg =
      Ankole.Conversations.list_messages!(
        query: [filter: [conversation_id: conversation.id, signal_id: signal.id]]
      )
      |> List.last()

    refute Map.has_key?(raw_msg.rich_content["access_blocked"], "page_title")
    interaction_id = raw_msg.rich_content["access_blocked"]["interaction_id"]

    # 1. Member without node_view sees NO page_title, NO explain waterfall, and can_grant == false
    {:ok, member_detail} = Conversations.get(ctx.member_actor, conversation.id)
    member_projected = Presentation.detail(member_detail)
    assert member_projected.conversation.rowStatus == "waiting_choice"
    member_msg = List.last(member_projected.messages)
    assert member_msg.richContent["access_blocked"]["state"] == "pending"
    assert is_nil(member_msg.richContent["access_blocked"]["page_title"])
    assert member_msg.richContent["access_blocked"]["can_grant"] == false
    assert is_nil(member_msg.richContent["access_blocked"]["explain"])

    # Unauthorized member cannot grant access (rolls back cleanly, leaving state pending)
    assert {:error, :forbidden} =
             BlockedWaits.grant_and_continue(ctx.member_actor, conversation.id, interaction_id)

    # 2. Owner with node_manage sees page_title, can_grant == true, and 4-stage explain waterfall
    {:ok, owner_detail} = Conversations.get(ctx.owner_actor, conversation.id)
    owner_msg = owner_detail |> Presentation.detail() |> Map.fetch!(:messages) |> List.last()
    assert owner_msg.richContent["access_blocked"]["page_title"] == "Board Compensation Plan"
    assert owner_msg.richContent["access_blocked"]["can_grant"] == true
    assert length(owner_msg.richContent["access_blocked"]["explain"]["stages"]) == 4

    # 3. Owner clicks Grant View & Continue -> LockOrder passes, colleague receives view, signal.action.invoked enqueued
    assert {:ok, updated_detail} =
             BlockedWaits.grant_and_continue(ctx.owner_actor, conversation.id, interaction_id)

    {:ok, reloaded_page} = Pages.fetch(restricted_page.id)
    assert {:ok, _} = Access.authorize(ctx.colleague_actor, reloaded_page, "node_view")

    wakes =
      Ankole.Signals.list_signals!(
        query: [filter: [conversation_id: conversation.id, type: "signal.action.invoked"]]
      )

    assert [wake] = wakes
    assert wake.data["action"]["value"]["source_signal_id"] == signal.id
    assert wake.data["action"]["value"]["answer"]["kind"] == "access_granted"

    refute Enum.any?(
             Ankole.Signals.list_signals!(query: [filter: [conversation_id: conversation.id]]),
             &(&1.type == "command.retry")
           )

    updated_msg =
      updated_detail
      |> Presentation.detail()
      |> Map.fetch!(:messages)
      |> Enum.find(&(&1.id == raw_msg.id))

    assert updated_msg.richContent["access_blocked"]["state"] == "answered"
    assert updated_msg.richContent["access_blocked"]["can_grant"] == false
  end

  test "grant_and_continue preserves an existing edit role instead of downgrading to view",
       ctx do
    {:ok, restricted_page} =
      Pages.create(ctx.owner_actor, %{
        title: "Engineering Architecture Plan",
        private_owner_uid: ctx.owner.uid
      })

    {:ok, room_detail} =
      Ankole.ConversationsFixtures.create(ctx.owner.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.colleague.uid,
        text: "Review and annotate the Engineering Architecture Plan"
      })

    conversation = room_detail.conversation

    [signal] =
      Ankole.Signals.list_signals!(query: [filter: [conversation_id: conversation.id]])

    run_ref = %Ankole.Sessions.RunRef{
      agent_uid: ctx.colleague.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    request = %PodRequest{
      operation: "pages.read",
      params_json: Torque.encode!(%{"id" => restricted_page.id})
    }

    assert {:error, _} =
             RPCBroker.handle_read(
               run_ref,
               request,
               %{worker_id: ctx.colleague.uid, request_id: "req-preserve-edit"}
             )

    post_turn_reply!(
      ctx.colleague.uid,
      conversation,
      signal,
      "I need access to read that page.",
      nil
    )

    raw_msg =
      Ankole.Conversations.list_messages!(
        query: [filter: [conversation_id: conversation.id, signal_id: signal.id]]
      )
      |> List.last()

    interaction_id = raw_msg.rich_content["access_blocked"]["interaction_id"]

    # Owner grants :edit directly via page sharing before clicking the blocked wait card.
    {:ok, _} =
      Pages.update_sharing(ctx.owner_actor, restricted_page.id, %{
        upserts: [%{principal_uid: ctx.colleague.uid, role: :edit, target_scope: "container"}]
      })

    assert {:ok, _updated_detail} =
             BlockedWaits.grant_and_continue(ctx.owner_actor, conversation.id, interaction_id)

    {:ok, reloaded_page} = Pages.fetch(restricted_page.id)
    assert {:ok, _} = Access.authorize(ctx.colleague_actor, reloaded_page, "node_edit")

    assert [wake] =
             Ankole.Signals.list_signals!(
               query: [filter: [conversation_id: conversation.id, type: "signal.action.invoked"]]
             )

    assert wake.data["action"]["value"]["answer"]["kind"] == "access_granted"
  end

  defp post_turn_reply!(agent_uid, conversation, signal, text, execution) do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        :ok = Ankole.Sessions.Queue.lock_sessions_in_tx([{agent_uid, signal.session_id}])

        target = %Ankole.Conversations.Target{
          kind: :native,
          conversation_id: conversation.id
        }

        statement = %Ankole.Conversations.Statement{
          signal: signal,
          completion: %{
            answer_text: text,
            execution: execution,
            attachments: []
          },
          now: DateTime.utc_now(:microsecond)
        }

        Ankole.Conversations.post_in_tx(target, statement)
      end)
  end
end
