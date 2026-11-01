defmodule Ankole.Pod.FileCommentsTest do
  use Ankole.DataCase, async: false
  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.Conversations
  alias Ankole.Pod.{Comments, Pages, PageUserState, RPCBroker}
  alias Ankole.Pod.Comments.Activity
  alias Ankole.RuntimeFabric.V1.PodRequest
  alias Ankole.Sessions.Prompt.Input
  alias Ankole.Sessions.RunRef
  alias Ankole.Signals.Signal

  setup do
    owner = human_fixture(%{display_name: "Alice"}).principal |> actor_fixture()
    commenter = human_fixture(%{display_name: "Bob"}).principal |> actor_fixture()
    viewer = human_fixture(%{display_name: "Viewer"}).principal |> actor_fixture()

    agent =
      Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: owner.principal.uid}).principal

    {:ok, private_root} =
      Repo.transact_top_level(fn ->
        Ankole.Files.ensure_private_root_in_tx(owner.principal.uid)
      end)

    {:ok, file_node} =
      Ankole.Files.create_node(owner, %{
        parent_id: private_root.id,
        kind: :file,
        name: "budget.csv"
      })

    # Verify Unified Drive invariant: a pure Drive `:file` node has no `pages` properties row.
    assert Repo.one(
             from(p in "pages", where: p.id == type(^file_node.id, :binary_id), select: p.id)
           ) == nil

    {:ok, uploaded_v1} =
      Ankole.Files.write_node(
        owner,
        file_node.id,
        "Department,Amount\nR&D,1200\nMarketing,800\n"
      )

    {:ok, file_page} = Pages.fetch(file_node.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.principal.uid, file_page.id, %{
        grants: [
          %{principal_uid: commenter.principal.uid, role: "contribute", target_scope: "self"},
          %{principal_uid: viewer.principal.uid, role: "view", target_scope: "self"},
          %{principal_uid: agent.uid, role: "contribute", target_scope: "self"}
        ]
      })

    Ankole.ConversationsFixtures.grant_chat(owner.principal.uid, agent.uid)
    Ankole.ConversationsFixtures.grant_chat(commenter.principal.uid, agent.uid)

    %{
      owner: owner,
      commenter: commenter,
      viewer: viewer,
      agent: agent,
      file_page: file_page,
      object_v1: uploaded_v1.object_id
    }
  end

  test "supports all four multimodal file anchors, object_id version pinning,anchor_outdated on replacement, and PageUserState watermarks without a pages row",
       ctx do
    # 1. CSV row anchor
    assert {:ok, %{comment: csv_thread}} =
             Comments.create(ctx.commenter, ctx.file_page.id, %{
               body: "Verify R&D budget figure.",
               quote: "Row 1 (Amount): 1200",
               anchor: %{
                 "object_id" => ctx.object_v1,
                 "kind" => "csv_rows",
                 "start_row" => 1,
                 "end_row" => 1,
                 "column" => "Amount"
               }
             })

    assert csv_thread.anchor == %{
             "kind" => "csv_rows",
             "start_row" => 1,
             "end_row" => 1,
             "column" => "Amount",
             "object_id" => ctx.object_v1
           }

    assert csv_thread.anchor_present == true
    assert csv_thread.anchor_outdated == false

    # 2. Lines, Markdown section, and media timestamp anchors
    for {anchor, quote} <- [
          {%{"kind" => "lines", "start_line" => 2, "end_line" => 3}, "R&D,1200\nMarketing,800"},
          {%{"kind" => "md_section", "heading" => "Summary", "level" => 2, "start_line" => 10},
           "## Summary"},
          {%{"kind" => "media_timestamp", "time_sec" => 42.5, "end_time_sec" => 48.0}, "@ 00:42"}
        ] do
      assert {:ok, %{comment: created}} =
               Comments.create(ctx.commenter, ctx.file_page.id, %{
                 body: "Anchored note",
                 quote: quote,
                 anchor: Map.put(anchor, "object_id", ctx.object_v1)
               })

      assert created.anchor["object_id"] == ctx.object_v1
      assert created.anchor_present == true
      assert created.anchor_outdated == false
    end

    # Reject doc-style revision/offset anchors on `:file` and reject malformed anchors
    assert {:error, :invalid_comment_anchor} =
             Comments.create(ctx.commenter, ctx.file_page.id, %{
               body: "Wrong anchor shape",
               base_revision: 0,
               from: 0,
               to: 5
             })

    assert {:error, :invalid_comment_anchor} =
             Comments.create(ctx.commenter, ctx.file_page.id, %{
               body: "Reversed lines",
               anchor: %{"kind" => "lines", "start_line" => 9, "end_line" => 2}
             })

    # Read summary & acknowledge watermark on `:file` node (exercises `page_user_states -> drive_nodes` FK)
    assert {:ok, %{unread_count: 4, activity_at: watermark}} =
             Activity.summary(ctx.owner, ctx.file_page.id)

    assert {:ok, %{unread_count: 0}} =
             Activity.acknowledge(ctx.owner, ctx.file_page.id, watermark)

    assert Repo.get_by!(PageUserState,
             principal_uid: ctx.owner.principal.uid,
             page_id: ctx.file_page.id
           ).comments_read_at == watermark

    # Replace file bytes -> `object_id` advances -> existing anchors report `anchor_outdated: true`
    {:ok, uploaded_v2} =
      Ankole.Files.write_node(
        ctx.owner,
        ctx.file_page.id,
        "Department,Amount\nR&D,1500\nMarketing,900\nSales,400\n"
      )

    refute uploaded_v2.object_id == ctx.object_v1

    assert {:ok, %{thread: outdated_thread}} =
             Comments.read(ctx.owner, ctx.file_page.id, csv_thread.id)

    assert outdated_thread.anchor_outdated == true
    assert outdated_thread.anchor_present == false

    assert {:error, :file_anchor_outdated} =
             Comments.create(ctx.commenter, ctx.file_page.id, %{
               body: "A stale preview must not attach to the new bytes",
               anchor: %{
                 "kind" => "lines",
                 "start_line" => 1,
                 "end_line" => 2,
                 "object_id" => ctx.object_v1
               }
             })

    # Re-anchor onto the new file version
    assert {:ok, %{comment: reanchored}} =
             Comments.anchor(ctx.commenter, ctx.file_page.id, csv_thread.id, %{
               version: outdated_thread.version,
               quote: "Row 1 (Amount): 1500",
               anchor: %{
                 "object_id" => uploaded_v2.object_id,
                 "kind" => "csv_rows",
                 "start_row" => 1,
                 "end_row" => 1,
                 "column" => "Amount"
               }
             })

    assert reanchored.anchor["object_id"] == uploaded_v2.object_id
    assert reanchored.anchor_outdated == false
    assert reanchored.anchor_present == true
  end

  test "wakes @mentioned Agent under LockOrder only when all three AuthZ gates and primary model pass, and opens RPCBroker comment operations",
       ctx do
    # Positive path: commenter has `node_comment` + `"chat"` on agent + agent has `node_view` + primary model ready
    assert {:ok, %{comment: root}} =
             Comments.create(ctx.commenter, ctx.file_page.id, %{
               body: "@#{ctx.agent.display_name} please double-check row 1.",
               quote: "Row 1 (Amount): 1200",
               anchor: %{
                 "object_id" => ctx.object_v1,
                 "kind" => "csv_rows",
                 "start_row" => 1,
                 "end_row" => 1,
                 "column" => "Amount"
               },
               mentioned_agent_uids: [ctx.agent.uid]
             })

    assert [%Signal{type: "pod.page_comment.addressed", agent_uid: agent_uid} = wakeup] =
             Repo.all(
               from(s in Signal,
                 where: s.type == "pod.page_comment.addressed" and s.subject == ^ctx.file_page.id
               )
             )

    assert agent_uid == ctx.agent.uid
    assert wakeup.data["comment_id"] == root.id
    assert wakeup.data["node_type"] == "file"

    # Prompt rendering wraps untrusted quote & body inside delimiters
    rendered = Input.text(Signal.envelope(wakeup), wakeup.type)
    assert rendered =~ "mentioned you in a Pod comment thread"
    assert rendered =~ "Row 1 (Amount): 1200"
    assert rendered =~ "ankole-pod comments reply"

    # Agent uses `RPCBroker` during the turn to list, show, reply (requires non-empty root_id), and resolve
    run_ref = %RunRef{
      agent_uid: ctx.agent.uid,
      session_id: wakeup.session_id,
      signal_id: wakeup.id
    }

    rpc_ctx = %{worker_id: ctx.agent.uid, route: "pod-comments-rpc", request_id: "req-1"}

    assert {:ok, %{"result" => %{"threads" => [listed]}}} =
             RPCBroker.handle_read(
               run_ref,
               %PodRequest{
                 operation: "comments.list",
                 params_json: Ankole.JSON.encode!(%{id: ctx.file_page.id, status: "open"})
               },
               rpc_ctx
             )

    assert listed["id"] == root.id

    assert {:ok, %{"result" => %{"thread" => shown}}} =
             RPCBroker.handle_read(
               run_ref,
               %PodRequest{
                 operation: "comments.show",
                 params_json: Ankole.JSON.encode!(%{id: ctx.file_page.id, comment_id: root.id})
               },
               rpc_ctx
             )

    assert shown["id"] == root.id

    # Root-less reply via `comments.reply` is rejected
    assert {:error, %{"code" => "invalid_comment_reply"}} =
             RPCBroker.handle_write(
               run_ref,
               %PodRequest{
                 operation: "comments.reply",
                 params_json:
                   Ankole.JSON.encode!(%{id: ctx.file_page.id, root_id: "", body: "No root"})
               },
               rpc_ctx
             )

    assert {:ok, %{"result" => %{"comment" => agent_reply}}} =
             RPCBroker.handle_write(
               run_ref,
               %PodRequest{
                 operation: "comments.reply",
                 params_json:
                   Ankole.JSON.encode!(%{
                     id: ctx.file_page.id,
                     root_id: root.id,
                     body: "Checked: R&D matches the ledger."
                   })
               },
               rpc_ctx
             )

    assert agent_reply["root_id"] == root.id
    assert agent_reply["author"]["kind"] == "agent"

    # Negative Gate A: human without `"chat"` permission on a second agent cannot wake that agent
    restricted_agent =
      Ankole.SessionsCase.agent_fixture(%{
        owner_principal_uid: ctx.owner.principal.uid,
        display_name: "RestrictedBot"
      }).principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.principal.uid, ctx.file_page.id, %{
        grants: [
          %{principal_uid: ctx.commenter.principal.uid, role: "contribute", target_scope: "self"},
          %{principal_uid: restricted_agent.uid, role: "view", target_scope: "self"}
        ]
      })

    assert {:ok, _} =
             Comments.create(ctx.commenter, ctx.file_page.id, %{
               body: "@RestrictedBot wake up!",
               mentioned_agent_uids: [restricted_agent.uid]
             })

    assert Repo.all(
             from(s in Signal,
               where:
                 s.type == "pod.page_comment.addressed" and s.agent_uid == ^restricted_agent.uid
             )
           ) == []

    # Negative Gate B: agent without `node_view` on a private file is NOT woken even if human has `"chat"`
    {:ok, secret_file} =
      Pages.create(ctx.owner, %{
        type: "file",
        title: "secret.txt",
        private_owner_uid: ctx.owner.principal.uid
      })

    assert {:ok, _} =
             Comments.create(ctx.owner, secret_file.id, %{
               body: "@#{ctx.agent.display_name} inspect secret",
               mentioned_agent_uids: [ctx.agent.uid]
             })

    assert Repo.all(
             from(s in Signal,
               where: s.type == "pod.page_comment.addressed" and s.subject == ^secret_file.id
             )
           ) == []

    # Verify the anchor_page conversation created on wakeup is visible on the `:file` page
    assert {:ok, conversations} = Conversations.list_for_page(ctx.owner, ctx.file_page.id)
    assert Enum.any?(conversations, &(&1.conversation.id == wakeup.conversation_id))
  end

  test "wakes newly @mentioned Agent on comment update, deduplicates edit cycles, and promotes anchor_page conversation to :group when a second human mentions the Agent",
       ctx do
    # 1. Create without mention, then update to add @agent -> wakes cleanly under LockOrder
    assert {:ok, %{comment: draft_comment}} =
             Comments.create(ctx.commenter, ctx.file_page.id, %{
               body: "Initial note without mention.",
               mentioned_agent_uids: []
             })

    assert Repo.all(
             from(s in Signal,
               where: s.type == "pod.page_comment.addressed" and s.subject == ^ctx.file_page.id
             )
           ) == []

    assert {:ok, %{comment: v2_comment}} =
             Comments.update(ctx.commenter, ctx.file_page.id, draft_comment.id, %{
               version: draft_comment.version,
               body: "Hey @#{ctx.agent.display_name}, please check this.",
               mentioned_agent_uids: [ctx.agent.uid]
             })

    assert [%Signal{id: first_signal_id, conversation_id: anchor_conv_id}] =
             Repo.all(
               from(s in Signal,
                 where: s.type == "pod.page_comment.addressed" and s.subject == ^ctx.file_page.id
               )
             )

    {:ok, detail_after_first} = Conversations.get(ctx.commenter, anchor_conv_id)
    assert detail_after_first.conversation.room_mode == :dm

    # 2. Edit cycle: remove @agent, then re-add @agent on the same comment -> no duplicate Signal
    assert {:ok, %{comment: v3_comment}} =
             Comments.update(ctx.commenter, ctx.file_page.id, draft_comment.id, %{
               version: v2_comment.version,
               body: "Temporarily removed mention.",
               mentioned_agent_uids: [],
               previous_mentioned_agent_uids: [ctx.agent.uid]
             })

    assert {:ok, %{comment: _v4_comment}} =
             Comments.update(ctx.commenter, ctx.file_page.id, draft_comment.id, %{
               version: v3_comment.version,
               body: "Re-adding @#{ctx.agent.display_name} on the same comment.",
               mentioned_agent_uids: [ctx.agent.uid],
               previous_mentioned_agent_uids: []
             })

    assert [%Signal{id: ^first_signal_id}] =
             Repo.all(
               from(s in Signal,
                 where: s.type == "pod.page_comment.addressed" and s.subject == ^ctx.file_page.id
               )
             )

    # 3. Second human (`owner`) mentions the same @agent in a reply -> joins & promotes `:dm` -> `:group`
    assert {:ok, %{comment: owner_reply}} =
             Comments.create(ctx.owner, ctx.file_page.id, %{
               root_id: draft_comment.id,
               body: "@#{ctx.agent.display_name} also compare Q3.",
               mentioned_agent_uids: [ctx.agent.uid]
             })

    signals =
      Repo.all(
        from(s in Signal,
          where: s.type == "pod.page_comment.addressed" and s.subject == ^ctx.file_page.id,
          order_by: [asc: s.queue_sequence]
        )
      )

    assert Enum.map(signals, & &1.data["comment_id"]) == [draft_comment.id, owner_reply.id]
    assert Enum.all?(signals, &(&1.conversation_id == anchor_conv_id))

    {:ok, detail_after_second} = Conversations.get(ctx.owner, anchor_conv_id)
    assert detail_after_second.conversation.room_mode == :group
  end
end
