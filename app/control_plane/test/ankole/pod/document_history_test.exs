defmodule Ankole.Pod.DocumentHistoryTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.Pod.{
    Comments,
    Documents,
    PageChange,
    PageComment,
    PageContent,
    Pages,
    PageSnapshot
  }

  alias Ankole.Pod.Documents.History

  setup do
    owner = human_fixture(%{display_name: "Creator"}).principal
    editor = human_fixture(%{display_name: "Editor"}).principal
    viewer = human_fixture(%{display_name: "Viewer"}).principal
    actor = actor_fixture(owner)

    {:ok, page} =
      Pages.create(actor, %{
        title: "Original",
        icon: "📄",
        private_owner_uid: owner.uid,
        xml: "<page><p>Original body</p></page>"
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{principal_uid: editor.uid, role: "edit"},
          %{principal_uid: viewer.uid, role: "view"}
        ]
      })

    %{owner: actor, editor: actor_fixture(editor), viewer: actor_fixture(viewer), page: page}
  end

  test "creation and five-minute precommit checkpoints preserve whole document versions", ctx do
    assert {:ok, %{snapshots: [%{reason: :created} = original], next_cursor: nil}} =
             History.list(ctx.editor, ctx.page.id)

    assert original.revision == 0
    assert original.title == "Original"

    assert {:ok, _} =
             Documents.write(ctx.editor, ctx.page.id, 0, "<page><p>First edit</p></page>")

    assert {:ok, _} =
             Documents.write(ctx.editor, ctx.page.id, 1, "<page><p>Second edit</p></page>")

    assert length(Repo.all(PageSnapshot)) == 1
    age_checkpoint(original.id)

    assert {:ok, _} = Documents.write(ctx.owner, ctx.page.id, 2, "<page><p>Third edit</p></page>")
    assert {:ok, %{snapshots: [checkpoint, _]}} = History.list(ctx.editor, ctx.page.id)
    assert checkpoint.reason == :checkpoint
    assert checkpoint.revision == 2
    assert checkpoint.author.name == "Editor"

    assert {:ok, %{snapshot: %{content: "<page><p>Second edit</p></page>"}}} =
             History.read(ctx.editor, ctx.page.id, checkpoint.id)
  end

  test "metadata edits checkpoint the previous title and icon without changing document revision",
       ctx do
    assert {:ok, first} =
             Pages.update(ctx.editor, ctx.page.id, %{
               title: "First title",
               expected_title: ctx.page.title,
               icon: "📚"
             })

    [original] = Repo.all(PageSnapshot)
    age_checkpoint(original.id)

    assert {:ok, second} =
             Pages.update(ctx.owner, ctx.page.id, %{
               title: "Second title",
               expected_title: first.title
             })

    assert first.revision == second.revision
    assert {:ok, %{snapshots: [checkpoint, _]}} = History.list(ctx.owner, ctx.page.id)
    assert checkpoint.title == "First title"
    assert checkpoint.icon == "📚"
    assert checkpoint.author.name == "Editor"

    assert {:ok, _} =
             Pages.update(ctx.owner, ctx.page.id, %{
               title: "Second title",
               expected_title: second.title
             })

    assert length(Repo.all(PageSnapshot)) == 2
  end

  test "restore creates a new OT revision with before and after checkpoints while keeping location and permissions",
       ctx do
    [original] = Repo.all(PageSnapshot)
    {:ok, _} = Documents.write(ctx.editor, ctx.page.id, 0, "<page><p>Edited body</p></page>")

    {:ok, changed} =
      Pages.update(ctx.editor, ctx.page.id, %{
        title: "Edited title",
        expected_title: ctx.page.title,
        icon: "📚"
      })

    assert {:ok, %{page: restored, content: content}} =
             History.restore(
               ctx.editor,
               ctx.page.id,
               original.id,
               changed.revision,
               changed.updated_at
             )

    assert restored.revision == changed.revision + 1
    assert restored.title == "Original"
    assert restored.icon == "📄"
    assert restored.private_owner_uid == changed.private_owner_uid
    assert restored.acl_anchor_id == changed.acl_anchor_id
    assert content.content == "<page><p>Original body</p></page>"
    assert content.updated_by == Ankole.ActorRef.from_actor(ctx.editor)
    assert {:ok, %{role: "edit"}} = Pages.get(ctx.editor, ctx.page.id)
    assert {:ok, %{role: "view"}} = Pages.get(ctx.viewer, ctx.page.id)

    assert {:ok, %{changes: [%{kind: :change, revision: 2, changes: changes}]}} =
             Documents.since(ctx.editor, ctx.page.id, changed.revision)

    assert changes != []

    assert {:ok, %{snapshots: [%{reason: :restored}, before, %{reason: :created}]}} =
             History.list(ctx.editor, ctx.page.id)

    assert before.reason == :before_restore
    assert before.title == "Edited title"

    assert {:ok, %{snapshot: %{content: "<page><p>Edited body</p></page>"}}} =
             History.read(ctx.editor, ctx.page.id, before.id)

    assert {:ok, %{page: %{revision: 3} = same_body_restored, content: same_body_content}} =
             History.restore(
               ctx.editor,
               ctx.page.id,
               original.id,
               restored.revision,
               restored.updated_at
             )

    assert {:ok, %{changes: [%{kind: :change, revision: 3, changes: [span]}]}} =
             Documents.since(ctx.editor, ctx.page.id, restored.revision)

    assert is_integer(span) and span >= 2

    assert Ankole.Kernel.page_apply(same_body_content.content, [span]) ==
             {:ok, %{xml: same_body_content.content, plain_text: same_body_content.plain_text}}

    {:ok, metadata_only} =
      Pages.update(ctx.editor, ctx.page.id, %{
        title: "Metadata only edit",
        expected_title: same_body_restored.title,
        icon: "🧭"
      })

    assert {:ok,
            %{
              page: %{revision: 4, title: "Original", icon: "📄"},
              content: meta_restored_content
            }} =
             History.restore(
               ctx.editor,
               ctx.page.id,
               original.id,
               metadata_only.revision,
               metadata_only.updated_at
             )

    assert {:ok, %{changes: [%{kind: :change, revision: 4, changes: [meta_span]}]}} =
             Documents.since(ctx.editor, ctx.page.id, metadata_only.revision)

    assert is_integer(meta_span) and meta_span >= 2

    assert Ankole.Kernel.page_apply(meta_restored_content.content, [meta_span]) ==
             {:ok,
              %{xml: meta_restored_content.content, plain_text: meta_restored_content.plain_text}}
  end

  test "restore rejects stale content or metadata without creating snapshots", ctx do
    [original] = Repo.all(PageSnapshot)

    {:ok, %{page: edited}} =
      Documents.write(ctx.editor, ctx.page.id, 0, "<page><p>Fresh</p></page>")

    assert {:error, {:document_conflict, %{revision: 1}}} =
             History.restore(ctx.editor, ctx.page.id, original.id, 0, ctx.page.updated_at)

    {:ok, renamed} =
      Pages.update(ctx.editor, ctx.page.id, %{
        title: "Fresh title",
        expected_title: ctx.page.title
      })

    assert {:error, {:document_conflict, %{revision: 1}}} =
             History.restore(
               ctx.editor,
               ctx.page.id,
               original.id,
               edited.revision,
               edited.updated_at
             )

    assert length(Repo.all(PageSnapshot)) == 1
    assert Repo.get!(PageContent, ctx.page.id).content == "<page><p>Fresh</p></page>"
    assert renamed.title == "Fresh title"
  end

  test "full history requires current edit access and snapshots cannot cross pages or tenants",
       ctx do
    [original] = Repo.all(PageSnapshot)
    assert {:error, :forbidden} = History.list(ctx.viewer, ctx.page.id)
    assert {:error, :forbidden} = History.read(ctx.viewer, ctx.page.id, original.id)

    assert {:error, :forbidden} =
             History.restore(ctx.viewer, ctx.page.id, original.id, 0, ctx.page.updated_at)

    contributor = human_fixture().principal

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.page.private_owner_uid, ctx.page.id, %{
               grants: [%{principal_uid: contributor.uid, role: "contribute"}]
             })

    contributor = actor_fixture(contributor)
    assert {:error, :forbidden} = History.list(contributor, ctx.page.id)
    assert {:error, :forbidden} = History.read(contributor, ctx.page.id, original.id)

    assert {:error, :forbidden} =
             History.restore(contributor, ctx.page.id, original.id, 0, ctx.page.updated_at)

    {:ok, other} = Pages.create(ctx.owner, %{private_owner_uid: ctx.page.private_owner_uid})
    assert {:error, :not_found} = History.read(ctx.owner, other.id, original.id)
    tenant = create_tenant()

    Repo.with_tenant(tenant.id, fn ->
      assert {:error, :not_found} = History.read(ctx.owner, ctx.page.id, original.id)
    end)
  end

  test "annotation-only updates stay out of history and restore preserves current marks and resolution",
       ctx do
    [original] = Repo.all(PageSnapshot)
    age_checkpoint(original.id)

    assert {:ok, %{comment: comment, revision: 1}} =
             Comments.create(ctx.editor, ctx.page.id, %{
               body: "Keep this wording",
               base_revision: 0,
               from: 1,
               to: 9
             })

    assert comment.quote == "Original"
    assert length(Repo.all(PageSnapshot)) == 1

    assert {:ok, %{contributors: [%{name: "Creator"}]}} =
             Ankole.Pod.Documents.Insights.read(ctx.owner, ctx.page.id)

    assert {:ok, %{page: marked}} = Pages.get(ctx.owner, ctx.page.id)
    assert marked.updated_at == ctx.page.updated_at

    assert {:ok, %{page: changed}} =
             Documents.write(
               ctx.owner,
               ctx.page.id,
               1,
               "<page><p>Original body with more detail</p></page>"
             )

    assert {:ok, %{comment: resolved}} =
             Comments.resolve(ctx.editor, ctx.page.id, comment.id, %{
               version: comment.version,
               resolved: true
             })

    assert resolved.resolved_at

    assert {:ok, %{content: content}} =
             History.restore(
               ctx.editor,
               ctx.page.id,
               original.id,
               changed.revision,
               changed.updated_at
             )

    assert {:ok, %{ids: [id]}} = Ankole.Kernel.page_comment_info(content.content)
    assert id == comment.id

    assert {:ok, %{threads: [%{anchor_present: true, resolved_at: resolved_at}]}} =
             Comments.list(ctx.owner, ctx.page.id, %{status: :resolved})

    assert resolved_at == resolved.resolved_at
    assert Enum.all?(Repo.all(PageSnapshot), &(not String.contains?(&1.content, "<comment")))
  end

  test "restoring text never resurrects an orphaned historical comment anchor", ctx do
    [original] = Repo.all(PageSnapshot)

    assert {:ok, %{comment: comment}} =
             Comments.create(ctx.editor, ctx.page.id, %{
               body: "A comment",
               base_revision: 0,
               from: 1,
               to: 9
             })

    assert {:ok, %{page: changed}} =
             Documents.write(
               ctx.owner,
               ctx.page.id,
               1,
               "<page><p>Unrelated replacement</p></page>"
             )

    assert {:ok, %{threads: [%{anchor_present: false}]}} = Comments.list(ctx.owner, ctx.page.id)

    assert {:ok, %{content: content}} =
             History.restore(
               ctx.editor,
               ctx.page.id,
               original.id,
               changed.revision,
               changed.updated_at
             )

    assert content.content == "<page><p>Original body</p></page>"

    assert {:ok, %{threads: [%{id: id, anchor_present: false}]}} =
             Comments.list(ctx.owner, ctx.page.id)

    assert id == comment.id
  end

  test "history pagination excludes full XML and is independent of OT pruning",
       ctx do
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.ot_replay_window", 1)
    [original] = Repo.all(PageSnapshot)

    {:ok, %{page: changed}} =
      Documents.write(ctx.editor, ctx.page.id, 0, "<page><p>Edited</p></page>")

    assert {:ok, _} =
             History.restore(
               ctx.editor,
               ctx.page.id,
               original.id,
               changed.revision,
               changed.updated_at
             )

    assert [%{revision: 2}] = Repo.all(PageChange)

    assert {:ok, %{snapshots: [first], next_cursor: cursor}} =
             History.list(ctx.editor, ctx.page.id, %{limit: 1})

    refute Map.has_key?(first, :content)
    assert is_binary(cursor)

    assert {:ok, %{snapshots: [second], next_cursor: cursor}} =
             History.list(ctx.editor, ctx.page.id, %{limit: 1, cursor: cursor})

    assert first.id != second.id

    assert {:ok, %{snapshots: [third], next_cursor: nil}} =
             History.list(ctx.editor, ctx.page.id, %{limit: 1, cursor: cursor})

    assert third.id == original.id

    assert {:ok, %{comment: comment}} =
             Comments.create(ctx.editor, ctx.page.id, %{body: "Keep this thread in trash"})

    assert {:ok, _} =
             Comments.create(ctx.editor, ctx.page.id, %{body: "A reply", root_id: comment.id})

    assert {:ok, _} = Pages.delete(ctx.owner, ctx.page.id)
    assert length(Repo.all(PageSnapshot)) == 3
    assert length(Repo.all(PageComment)) == 2
    assert {:ok, _} = Pages.purge(ctx.owner, ctx.page.id)

    assert :ok =
             Ankole.Pod.Jobs.PurgePage.perform(%Oban.Job{
               args: %{"tenant_id" => Repo.tenant_id!(), "page_id" => ctx.page.id}
             })

    assert Repo.all(PageSnapshot) == []
    assert Repo.all(PageComment) == []
  end

  test "restore checkpoints share the 200-version cap with ordinary checkpoints", ctx do
    [original] = Repo.all(PageSnapshot)
    now = DateTime.utc_now(:microsecond)

    for offset <- 1..199 do
      assert {:ok, _} =
               Ankole.Ash.create(PageSnapshot, :append, %{
                 page_id: ctx.page.id,
                 revision: 0,
                 title: original.title,
                 icon: original.icon,
                 content: original.content,
                 author: original.author,
                 document_updated_at: original.document_updated_at,
                 created_at: DateTime.add(now, -offset * 300, :second),
                 reason: Enum.at([:checkpoint, :before_restore, :restored], rem(offset, 3))
               })
    end

    oldest = Repo.all(PageSnapshot) |> Enum.sort_by(& &1.created_at, DateTime) |> Enum.take(2)

    assert {:ok, _} =
             History.restore(ctx.owner, ctx.page.id, original.id, 0, ctx.page.updated_at)

    retained = Repo.all(PageSnapshot)
    assert length(retained) == 200
    refute Enum.any?(retained, fn snapshot -> Enum.any?(oldest, &(&1.id == snapshot.id)) end)

    assert [%{reason: :restored}, %{reason: :before_restore} | _] =
             Enum.sort_by(retained, & &1.created_at, {:desc, DateTime})
  end

  test "expired versions cannot be listed, read, or restored before idle cleanup runs", ctx do
    [original] = Repo.all(PageSnapshot)
    old = DateTime.add(DateTime.utc_now(:microsecond), -31 * 86_400, :second)
    Repo.update_all(from(s in PageSnapshot, where: s.id == ^original.id), set: [created_at: old])

    assert {:ok, %{snapshots: []}} = History.list(ctx.owner, ctx.page.id)
    assert {:error, :not_found} = History.read(ctx.owner, ctx.page.id, original.id)

    assert {:error, :not_found} =
             History.restore(ctx.owner, ctx.page.id, original.id, 0, ctx.page.updated_at)

    assert :ok = History.expire(DateTime.utc_now(:microsecond))
    assert Repo.all(PageSnapshot) == []
  end

  test "the next write replaces an expired checkpoint and prunes it", ctx do
    [original] = Repo.all(PageSnapshot)
    old = DateTime.add(DateTime.utc_now(:microsecond), -31 * 86_400, :second)
    Repo.update_all(from(s in PageSnapshot, where: s.id == ^original.id), set: [created_at: old])

    assert {:ok, _} = Documents.write(ctx.owner, ctx.page.id, 0, "<page><p>New</p></page>")
    assert [checkpoint] = Repo.all(PageSnapshot)
    assert checkpoint.id != original.id
    assert checkpoint.content == original.content
  end

  test "empty OT change arrays are rejected and checkpointing uses a consistent retention timestamp",
       ctx do
    assert {:error, :invalid_request} =
             Documents.apply(ctx.editor, ctx.page.id, %{
               base_revision: 0,
               client_id: "editor-client",
               client_seq: 1,
               changes: []
             })

    [original] = Repo.all(PageSnapshot)
    now = DateTime.utc_now(:microsecond)
    boundary = DateTime.add(now, -30 * 86_400, :second)

    Repo.update_all(
      from(s in PageSnapshot, where: s.id == ^original.id),
      set: [created_at: boundary]
    )

    content = Repo.get!(PageContent, ctx.page.id)

    assert {:ok, :ok} =
             Repo.transact_top_level(fn ->
               {:ok, History.checkpoint_in_tx(ctx.page, content, now)}
             end)
  end

  defp age_checkpoint(id) do
    snapshot = Repo.get!(PageSnapshot, id)

    Repo.update!(
      Ecto.Changeset.change(snapshot,
        created_at: DateTime.add(snapshot.created_at, -301, :second)
      )
    )
  end
end
