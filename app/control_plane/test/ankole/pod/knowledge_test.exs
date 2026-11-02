defmodule Ankole.Pod.KnowledgeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ecto.Query, only: [from: 2]
  alias Ankole.Pod.{Documents, Knowledge, Pages, PageSnapshot}
  alias Ankole.Pod.Documents.History

  setup do
    owner = human_fixture().principal
    actor = actor_fixture(owner)

    {:ok, page} =
      Pages.create(actor, %{
        type: :knowledge,
        private_owner_uid: owner.uid,
        title: "DESIGN.md",
        xml: "<page><p>Brand</p></page>",
        metadata: %{"colors" => %{"primary" => "#123456"}}
      })

    %{actor: actor, owner: owner, page: page}
  end

  test "business metadata preserves draft dates while projecting valid calendar dates", ctx do
    xml = "<page><p>Draft schedule.</p></page>"

    assert {:ok, _} =
             Knowledge.write(ctx.actor, ctx.page.id, 0, xml, %{"effective_date" => "2026-02-31"})

    assert {:ok, page} = Ankole.Brain.Objects.get_by_slug(ctx.page.id)
    assert page.meta["effective_date"] == "2026-02-31"
    assert page.effective_date == nil

    assert {:ok, _} =
             Knowledge.write(ctx.actor, ctx.page.id, page.revision, xml, %{
               "effective_date" => "2026-02-28"
             })

    assert {:ok, page} = Ankole.Brain.Objects.get_by_slug(ctx.page.id)
    assert page.effective_date == ~D[2026-02-28]
  end

  test "structured properties remain readable without becoming summary text", ctx do
    metadata = %{"summary" => %{"total" => 120}, "description" => ["Draft", "Reviewed"]}

    assert {:ok, %{page: page}} =
             Knowledge.write(ctx.actor, ctx.page.id, 0, "<page><p>Brand</p></page>", metadata)

    context = %{
      querier_uid: ctx.owner.uid,
      disclosure: Ankole.Brain.Access.open_disclosure()
    }

    assert {:ok, preview} = Ankole.Pod.AgentPages.read(ctx.actor, context, page.id, "L0")
    assert preview.summary == ""
    assert {:ok, full} = Ankole.Pod.AgentPages.read(ctx.actor, context, page.id, "L2")
    assert full.metadata == metadata
  end

  test "explicit property-only saves each keep an independently restorable revision", ctx do
    assert {:ok, %{page: first}} =
             Knowledge.write(ctx.actor, ctx.page.id, 0, "<page><p>Brand</p></page>", %{
               "colors" => %{"primary" => "#abcdef"}
             })

    assert {:ok, %{page: second}} =
             Knowledge.write(ctx.actor, ctx.page.id, 1, "<page><p>Brand</p></page>", %{
               "colors" => %{"primary" => "#ffffff"}
             })

    assert first.revision == 1
    assert second.revision == 2

    assert {:ok, %{snapshots: [latest, previous, original]}} =
             History.list(ctx.actor, ctx.page.id)

    assert latest.metadata["colors"]["primary"] == "#ffffff"
    assert previous.metadata["colors"]["primary"] == "#abcdef"
    assert original.metadata["colors"]["primary"] == "#123456"

    assert {:ok, %{page: restored, content: content}} =
             History.restore(
               ctx.actor,
               ctx.page.id,
               previous.id,
               second.revision,
               second.updated_at
             )

    assert restored.metadata == first.metadata
    assert restored.revision == 3
    assert content.content == "<page><p>Brand</p></page>"
  end

  test "knowledge history is readable and restorable past thirty days and survives expiry", ctx do
    old = DateTime.add(DateTime.utc_now(:microsecond), -90 * 86_400, :second)

    Repo.update_all(from(s in PageSnapshot, where: s.page_id == ^ctx.page.id),
      set: [created_at: old]
    )

    assert :ok = History.expire(DateTime.utc_now(:microsecond))
    assert {:ok, %{snapshots: [snapshot]}} = History.list(ctx.actor, ctx.page.id)

    assert {:ok, %{snapshot: %{metadata: metadata}}} =
             History.read(ctx.actor, ctx.page.id, snapshot.id)

    assert metadata == ctx.page.metadata
    assert {:ok, _} = History.restore(ctx.actor, ctx.page.id, snapshot.id, 0, ctx.page.updated_at)
  end

  test "the same CAS covers body and properties and doc OT cannot bypass it", ctx do
    assert {:ok, _} =
             Knowledge.write(ctx.actor, ctx.page.id, 0, "<page><p>Committed</p></page>", %{
               "summary" => "committed"
             })

    assert {:error, {:revision_conflict, 1}} =
             Knowledge.write(ctx.actor, ctx.page.id, 0, "<page><p>Stale</p></page>", %{
               "summary" => "stale"
             })

    assert {:error, :invalid_page_type} =
             Documents.write(ctx.actor, ctx.page.id, 1, "<page><p>Bypass</p></page>")

    assert {:ok, %{page: %{metadata: %{"summary" => "committed"}}, content: content}} =
             Pages.get(ctx.actor, ctx.page.id)

    assert content.content == "<page><p>Committed</p></page>"
  end

  test "system synchronization state never enters exported frontmatter", ctx do
    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               {:ok, _} = Pages.lock(ctx.page.id)

               Knowledge.put_in_tx(
                 ctx.page.id,
                 %{
                   xml: "<page><p>Brand</p></page>",
                   metadata: %{"colors" => %{"primary" => "red"}},
                   upstream_state: %{"upstream_base_hash" => "internal-hash"}
                 },
                 actor: ctx.actor
               )
             end)

    assert {:ok, markdown} = Knowledge.export(ctx.page.id)
    assert markdown =~ "primary: red"
    refute markdown =~ "upstream"
    refute markdown =~ "internal-hash"
  end

  test "unsupported layouts and inline comment anchors cannot enter a knowledge page", ctx do
    assert {:error, _} =
             Knowledge.write(
               ctx.actor,
               ctx.page.id,
               0,
               "<page><columns><column><p>A</p></column><column><p>B</p></column></columns></page>",
               %{}
             )

    assert {:ok, %{page: %{revision: 0}}} = Pages.get(ctx.actor, ctx.page.id)
  end

  test "knowledge supports whole-page discussion without changing content or accepting anchors",
       ctx do
    alias Ankole.Pod.Comments

    assert {:ok, %{comment: comment, revision: 0}} =
             Comments.create(ctx.actor, ctx.page.id, %{body: "Review this rule"})

    refute comment.can_reanchor
    refute comment.anchor_present
    assert {:ok, %{threads: [%{id: id}]}} = Comments.list(ctx.actor, ctx.page.id)
    assert id == comment.id

    assert {:error, :invalid_comment_anchor} =
             Comments.create(ctx.actor, ctx.page.id, %{
               body: "Inline",
               base_revision: 0,
               from: 0,
               to: 2
             })

    assert {:ok, _} =
             Comments.delete(ctx.actor, ctx.page.id, comment.id, %{version: comment.version})

    assert {:ok, %{threads: []}} = Comments.list(ctx.actor, ctx.page.id)
    assert {:ok, %{page: %{revision: 0}, content: content}} = Pages.get(ctx.actor, ctx.page.id)
    assert content.plain_text == "Brand"
  end

  test "Agent saves require both editors and every room member to see the page", ctx do
    agent = agent_fixture(%{owner_principal_uid: ctx.owner.uid}).principal
    colleague = human_fixture().principal

    context = %{
      Ankole.Brain.Tools.Context.for_subject(agent.uid)
      | disclosure: %{
          mode: :strict,
          asker_uid: ctx.owner.uid,
          present_uids: [ctx.owner.uid, colleague.uid]
        }
    }

    actor = actor_fixture(agent)
    grants = [%{principal_uid: agent.uid, role: "edit"}]
    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.page.id, %{grants: grants})
    assert {:error, :not_found} = Ankole.Pod.AgentPages.read(actor, context, ctx.page.id)

    assert {:error, :not_found} =
             Ankole.Pod.AgentPages.save(actor, context, ctx.page.id, 0, "Hidden change")

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.page.id, %{
        grants: grants ++ [%{principal_uid: colleague.uid, role: "view"}]
      })

    assert {:ok, %{page: %{revision: 1}}} =
             Ankole.Pod.AgentPages.save(actor, context, ctx.page.id, 0, "Shared change")

    assert {:ok, %{body: body}} = Ankole.Pod.AgentPages.read(actor, context, ctx.page.id)
    assert body =~ "Shared change"

    viewer_request = put_in(context.disclosure.asker_uid, colleague.uid)

    assert {:error, :forbidden} =
             Ankole.Pod.AgentPages.save(
               actor,
               viewer_request,
               ctx.page.id,
               1,
               "Unapproved change"
             )

    assert {:ok, %{page: %{revision: 1}}} = Pages.get(ctx.actor, ctx.page.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.page.id, %{
        grants: [
          %{principal_uid: agent.uid, role: "view"},
          %{principal_uid: colleague.uid, role: "view"}
        ]
      })

    assert {:error, :forbidden} =
             Ankole.Pod.AgentPages.save(actor, context, ctx.page.id, 1, "Agent lacks edit")
  end
end
