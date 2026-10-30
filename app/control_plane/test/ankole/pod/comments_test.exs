defmodule Ankole.Pod.CommentsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Comments, Documents, Pages, PageComment, PageContent, PageSnapshot}
  alias Ankole.Pod.Comments.Activity

  setup do
    owner = human_fixture(%{display_name: "Owner"}).principal |> actor_fixture()
    contributor = human_fixture(%{display_name: "Commenter"}).principal |> actor_fixture()
    colleague = human_fixture(%{display_name: "Another commenter"}).principal |> actor_fixture()
    viewer = human_fixture().principal |> actor_fixture()

    {:ok, page} =
      Pages.create(owner, %{title: "Reviewed document", private_owner_uid: owner.principal.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.principal.uid, page.id, %{
        grants: [
          %{principal_uid: contributor.principal.uid, role: "contribute"},
          %{principal_uid: colleague.principal.uid, role: "contribute"},
          %{principal_uid: viewer.principal.uid, role: "view"}
        ]
      })

    {:ok, %{page: page}} = Documents.write(owner, page.id, 0, "<page><p>Hello world</p></page>")
    %{owner: owner, contributor: contributor, colleague: colleague, viewer: viewer, page: page}
  end

  test "a new reply brings an old thread to the first page without changing its edit version",
       ctx do
    {:ok, %{comment: old}} =
      Comments.create(ctx.contributor, ctx.page.id, %{body: "Old question"})

    {:ok, %{comment: newer}} =
      Comments.create(ctx.contributor, ctx.page.id, %{body: "New question"})

    assert {:ok, %{threads: [first], next_cursor: cursor}} =
             Comments.list(ctx.owner, ctx.page.id, %{limit: 1})

    assert first.id == newer.id

    assert {:ok, %{threads: [last], next_cursor: nil}} =
             Comments.list(ctx.owner, ctx.page.id, %{limit: 1, cursor: cursor})

    assert last.id == old.id

    {:ok, _} =
      Comments.create(ctx.colleague, ctx.page.id, %{root_id: old.id, body: "The missing answer"})

    assert {:ok, %{threads: [first], next_cursor: cursor}} =
             Comments.list(ctx.owner, ctx.page.id, %{limit: 1})

    assert first.id == old.id
    assert first.version == old.version
    assert hd(first.replies).body == "The missing answer"

    assert {:ok, %{threads: [last], next_cursor: nil}} =
             Comments.list(ctx.owner, ctx.page.id, %{limit: 1, cursor: cursor})

    assert last.id == newer.id
  end

  test "read acknowledgments are durable, private, and do not consume activity arriving after the observed watermark",
       ctx do
    {:ok, %{comment: old}} = Comments.create(ctx.contributor, ctx.page.id, %{body: "Review this"})
    assert {:ok, %{unread_count: 0}} = Activity.summary(ctx.contributor, ctx.page.id)

    assert {:ok, %{unread_count: 1, activity_at: observed}} =
             Activity.summary(ctx.owner, ctx.page.id)

    assert {:ok, %{threads: [_]}} = Comments.list(ctx.owner, ctx.page.id, %{status: :unread})

    {:ok, _} =
      Comments.create(ctx.colleague, ctx.page.id, %{
        root_id: old.id,
        body: "Arrived after the summary"
      })

    assert {:ok, %{unread_count: 1, activity_at: latest}} =
             Activity.acknowledge(ctx.owner, ctx.page.id, observed)

    assert {:ok, %{unread_count: 0}} = Activity.acknowledge(ctx.owner, ctx.page.id, latest)
    assert {:ok, %{threads: []}} = Comments.list(ctx.owner, ctx.page.id, %{status: :unread})
    assert {:ok, %{unread_count: 1}} = Activity.summary(ctx.viewer, ctx.page.id)
    assert {:ok, %{unread_count: 0}} = Activity.acknowledge(ctx.viewer, ctx.page.id, latest)

    {:ok, _} = Pages.state(ctx.owner, ctx.page.id, %{visited: false, favorite: false})
    assert {:ok, %{unread_count: 0}} = Activity.summary(ctx.owner, ctx.page.id)

    assert Repo.get_by!(Ankole.Pod.PageUserState,
             principal_uid: ctx.owner.principal.uid,
             page_id: ctx.page.id
           ).comments_read_at == latest

    assert {:ok, %{unread_count: 0}} = Activity.acknowledge(ctx.owner, ctx.page.id, observed)

    outsider = human_fixture().principal |> actor_fixture()
    assert {:error, :forbidden} = Activity.summary(outsider, ctx.page.id)
    assert {:error, :forbidden} = Activity.acknowledge(outsider, ctx.page.id, latest)
  end

  test "a contributor anchors a discussion through a real OT commit without text edit authority",
       ctx do
    assert {:ok, %{comment: comment, revision: 2}} =
             Comments.create(ctx.contributor, ctx.page.id, %{
               body: "Please explain **Hello**.",
               base_revision: 1,
               from: 1,
               to: 6
             })

    assert comment.quote == "Hello"
    assert comment.anchor_present
    assert comment.author.name == "Commenter"
    assert {:ok, %{page: page, content: content}} = Pages.get(ctx.owner, ctx.page.id)
    assert content.content =~ ~s(<comment ids="#{comment.id}">Hello</comment>)
    assert content.plain_text == "Hello world"
    assert content.updated_by.uid == ctx.owner.principal.uid
    assert page.updated_at == ctx.page.updated_at

    assert {:error, :forbidden} =
             Documents.write(
               ctx.contributor,
               page.id,
               page.revision,
               "<page><p>Replace text</p></page>"
             )

    assert {:ok, %{threads: [thread]}} = Comments.list(ctx.viewer, page.id)
    refute thread.can_edit
    refute thread.can_resolve
    assert {:error, :forbidden} = Comments.create(ctx.viewer, page.id, %{body: "Not permitted"})
  end

  test "stale or invalid anchors roll back both thread and document", ctx do
    assert {:error, {:revision_conflict, 1}} =
             Comments.create(ctx.contributor, ctx.page.id, %{
               body: "Stale",
               base_revision: 0,
               from: 1,
               to: 6
             })

    assert {:error, _} =
             Comments.create(ctx.contributor, ctx.page.id, %{
               body: "Outside",
               base_revision: 1,
               from: 900,
               to: 901
             })

    assert Repo.all(PageComment) == []
    assert Repo.get!(PageContent, ctx.page.id).content == "<page><p>Hello world</p></page>"
  end

  test "creating, moving and removing overlapping anchors retain the document tokens and edit history",
       ctx do
    {:ok, %{content: original}} = Pages.get(ctx.owner, ctx.page.id)
    {:ok, insights} = Ankole.Pod.Documents.Insights.read(ctx.owner, ctx.page.id)

    for snapshot <- Repo.all(PageSnapshot) do
      Repo.update!(
        Ecto.Changeset.change(snapshot,
          created_at: DateTime.add(snapshot.created_at, -301, :second)
        )
      )
    end

    snapshots = Repo.all(PageSnapshot)

    {:ok, %{comment: first, revision: 2}} =
      Comments.create(ctx.contributor, ctx.page.id, %{
        body: "First question",
        base_revision: 1,
        from: 1,
        to: 6
      })

    marked = assert_annotation_commit(ctx, 1, original.content)

    {:ok, %{comment: second, revision: 3}} =
      Comments.create(ctx.colleague, ctx.page.id, %{
        body: "Another question about the same words",
        base_revision: 2,
        from: 1,
        to: 6
      })

    overlapped = assert_annotation_commit(ctx, 2, marked)
    ids = Enum.sort([first.id, second.id]) |> Enum.join(" ")
    assert overlapped =~ ~s(<comment ids="#{ids}">Hello</comment>)

    {:ok, %{comment: moved, revision: 4}} =
      Comments.anchor(ctx.contributor, ctx.page.id, first.id, %{
        version: first.version,
        base_revision: 3,
        from: 7,
        to: 12
      })

    reanchored = assert_annotation_commit(ctx, 3, overlapped)
    assert reanchored =~ ~s(<comment ids="#{second.id}">Hello</comment>)
    assert reanchored =~ ~s(<comment ids="#{first.id}">world</comment>)

    {:ok, %{comment: resolved, revision: 4}} =
      Comments.resolve(ctx.contributor, ctx.page.id, first.id, %{
        version: moved.version,
        resolved: true
      })

    {:ok, %{comment: reopened, revision: 4}} =
      Comments.resolve(ctx.contributor, ctx.page.id, first.id, %{
        version: resolved.version,
        resolved: false
      })

    assert {:ok, %{changes: [], reset_required: false}} =
             Documents.since(ctx.owner, ctx.page.id, 4)

    assert Repo.get!(PageContent, ctx.page.id).content == reanchored

    assert {:ok, %{revision: 5}} =
             Comments.delete(ctx.contributor, ctx.page.id, first.id, %{version: reopened.version})

    remaining = assert_annotation_commit(ctx, 4, reanchored)
    assert remaining == ~s(<page><p><comment ids="#{second.id}">Hello</comment> world</p></page>)

    assert {:ok, %{revision: 6}} =
             Comments.delete(ctx.colleague, ctx.page.id, second.id, %{version: second.version})

    assert assert_annotation_commit(ctx, 5, remaining) == original.content
    assert {:ok, %{page: page, content: content}} = Pages.get(ctx.owner, ctx.page.id)
    assert page.updated_at == ctx.page.updated_at
    assert content.updated_at == original.updated_at
    assert content.updated_by == original.updated_by
    assert Repo.all(PageSnapshot) == snapshots
    assert {:ok, current_insights} = Ankole.Pod.Documents.Insights.read(ctx.owner, ctx.page.id)
    assert Map.drop(current_insights, [:daily]) == Map.drop(insights, [:daily])
    assert Enum.all?(current_insights.daily, &(&1.edits == 1))
    assert Enum.sum(Enum.map(current_insights.daily, & &1.comments)) == 2
  end

  test "whole-page threads and replies preserve independent versions and require an existing root",
       ctx do
    assert {:ok, %{comment: root, revision: 1}} =
             Comments.create(ctx.contributor, ctx.page.id, %{body: "Whole page"})

    assert root.quote == nil

    assert {:ok, %{comment: reply, revision: 1}} =
             Comments.create(ctx.colleague, ctx.page.id, %{root_id: root.id, body: "A reply"})

    assert {:error, :invalid_comment_reply} =
             Comments.create(ctx.colleague, ctx.page.id, %{
               root_id: reply.id,
               body: "Nested reply"
             })

    assert {:error, :invalid_comment_reply} =
             Comments.create(ctx.colleague, ctx.page.id, %{
               root_id: root.id,
               body: "Anchored reply",
               base_revision: 1,
               from: 1,
               to: 6
             })

    assert {:error, :forbidden} =
             Comments.update(ctx.colleague, ctx.page.id, root.id, %{
               version: root.version,
               body: "Someone else's comment"
             })

    assert {:ok, %{comment: updated}} =
             Comments.update(ctx.contributor, ctx.page.id, root.id, %{
               version: root.version,
               body: "Clarified question"
             })

    assert updated.version == root.version + 1

    assert {:error, :comment_conflict} =
             Comments.update(ctx.contributor, ctx.page.id, root.id, %{
               version: root.version,
               body: "Stale edit"
             })

    assert {:ok, %{comment: managed}} =
             Comments.update(ctx.owner, ctx.page.id, root.id, %{
               version: updated.version,
               body: "Manager edit"
             })

    assert managed.author.principal_uid == ctx.contributor.principal.uid
    assert Repo.get!(PageComment, root.id).updated_by.uid == ctx.owner.principal.uid
    assert {:ok, %{threads: [%{replies: [presented]}]}} = Comments.list(ctx.viewer, ctx.page.id)
    assert presented.id == reply.id
  end

  test "resolution is explicit and a new reply does not resolve or reopen the thread", ctx do
    {:ok, %{comment: root}} = Comments.create(ctx.contributor, ctx.page.id, %{body: "Question"})

    assert {:error, :forbidden} =
             Comments.resolve(ctx.colleague, ctx.page.id, root.id, %{
               version: root.version,
               resolved: true
             })

    assert {:ok, %{comment: resolved}} =
             Comments.resolve(ctx.owner, ctx.page.id, root.id, %{
               version: root.version,
               resolved: true
             })

    assert resolved.resolved_by.uid == ctx.owner.principal.uid
    assert {:ok, %{threads: []}} = Comments.list(ctx.viewer, ctx.page.id)
    assert {:ok, %{threads: [_]}} = Comments.list(ctx.viewer, ctx.page.id, %{status: :resolved})

    assert {:ok, _} =
             Comments.create(ctx.colleague, ctx.page.id, %{root_id: root.id, body: "Follow-up"})

    assert Repo.get!(PageComment, root.id).resolved_at == resolved.resolved_at

    assert {:ok, %{comment: reopened}} =
             Comments.resolve(ctx.contributor, ctx.page.id, root.id, %{
               version: resolved.version,
               resolved: false
             })

    assert reopened.resolved_at == nil
    assert reopened.resolved_by == nil
  end

  test "deleting a root preserves replies and removes its mark only when the discussion is empty",
       ctx do
    {:ok, %{comment: root}} =
      Comments.create(ctx.contributor, ctx.page.id, %{
        body: "Question",
        base_revision: 1,
        from: 1,
        to: 6
      })

    {:ok, %{comment: reply}} =
      Comments.create(ctx.colleague, ctx.page.id, %{body: "Answer", root_id: root.id})

    assert {:ok, %{comment: deleted}} =
             Comments.delete(ctx.contributor, ctx.page.id, root.id, %{version: root.version})

    assert deleted.body == nil
    assert deleted.anchor_present

    assert {:ok, %{threads: [%{body: nil, replies: [_]}]}} =
             Comments.list(ctx.viewer, ctx.page.id)

    assert {:ok, _} =
             Comments.delete(ctx.colleague, ctx.page.id, reply.id, %{version: reply.version})

    assert {:ok, %{threads: []}} = Comments.list(ctx.viewer, ctx.page.id)
    assert Repo.get!(PageContent, ctx.page.id).content == "<page><p>Hello world</p></page>"
    assert Repo.get!(PageComment, root.id).deleted_by.uid == ctx.contributor.principal.uid
  end

  test "Agent replies retain Principal attribution and leave resolution to an explicit action",
       ctx do
    agent =
      agent_fixture(%{owner_principal_uid: ctx.owner.principal.uid}).principal |> actor_fixture()

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.principal.uid, ctx.page.id, %{
        grants: [%{principal_uid: agent.principal.uid, role: "contribute"}]
      })

    {:ok, %{comment: root}} = Comments.create(ctx.owner, ctx.page.id, %{body: "Please review"})

    assert {:ok, %{comment: reply}} =
             Comments.create(agent, ctx.page.id, %{root_id: root.id, body: "Suggested revision"})

    assert reply.author.kind == :agent
    assert reply.author.principal_uid == agent.principal.uid
    assert Repo.get!(PageComment, root.id).resolved_at == nil

    assert {:error, :forbidden} =
             Comments.resolve(agent, ctx.page.id, root.id, %{
               version: root.version,
               resolved: true
             })
  end

  test "deleted original text leaves a detached discussion until an authorized explicit reanchor",
       ctx do
    {:ok, %{comment: root, revision: revision}} =
      Comments.create(ctx.contributor, ctx.page.id, %{
        body: "Question",
        base_revision: 1,
        from: 1,
        to: 6
      })

    {:ok, %{page: page}} =
      Documents.write(ctx.owner, ctx.page.id, revision, "<page><p>Replacement</p></page>")

    assert {:ok, %{threads: [thread]}} = Comments.list(ctx.viewer, page.id)
    refute thread.anchor_present
    assert thread.quote == "Hello"

    assert {:ok, %{comment: anchored, revision: reanchored_revision}} =
             Comments.anchor(ctx.contributor, page.id, root.id, %{
               version: root.version,
               base_revision: page.revision,
               from: 1,
               to: 12
             })

    assert anchored.anchor_present
    assert anchored.quote == "Hello"
    assert anchored.anchor_revision == root.anchor_revision

    assert Repo.get!(PageContent, page.id).content =~
             ~s(<comment ids="#{root.id}">Replacement</comment>)

    assert {:error, :invalid_comment_anchor} =
             Documents.write(
               ctx.owner,
               page.id,
               reanchored_revision,
               ~s(<page><p><comment ids="#{Ankole.Ecto.UUIDv7.autogenerate()}">Unknown</comment></p></page>)
             )
  end

  test "pagination, page scope and access loss do not expose another discussion", ctx do
    {:ok, %{comment: first}} = Comments.create(ctx.contributor, ctx.page.id, %{body: "First"})
    {:ok, %{comment: second}} = Comments.create(ctx.contributor, ctx.page.id, %{body: "Second"})

    assert {:ok, %{threads: [%{id: second_id}], next_cursor: cursor}} =
             Comments.list(ctx.viewer, ctx.page.id, %{limit: 1})

    assert second_id == second.id

    assert {:ok, %{threads: [%{id: first_id}], next_cursor: nil}} =
             Comments.list(ctx.viewer, ctx.page.id, %{limit: 1, cursor: cursor})

    assert first_id == first.id
    {:ok, other} = Pages.create(ctx.owner, %{private_owner_uid: ctx.owner.principal.uid})

    assert {:error, :not_found} =
             Comments.update(ctx.owner, other.id, first.id, %{
               version: first.version,
               body: "Wrong page"
             })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.principal.uid, ctx.page.id, %{grants: []})

    assert {:error, :forbidden} = Comments.list(ctx.viewer, ctx.page.id)

    assert {:error, :forbidden} =
             Comments.update(ctx.contributor, ctx.page.id, first.id, %{
               version: first.version,
               body: "Lost access"
             })
  end

  defp assert_annotation_commit(ctx, base_revision, source) do
    assert {:ok, %{changes: [%{kind: :change, changes: changes}], reset_required: false}} =
             Documents.since(ctx.owner, ctx.page.id, base_revision)

    changed_sections = Enum.filter(changes, &is_list/1)
    assert changed_sections != []

    for section <- changed_sections do
      assert [length, modifications] = section
      assert length > 0
      assert modifications != []

      for modification <- modifications do
        assert Map.get(modification, "add") == "Comment" or
                 Map.get(modification, "remove") == "Comment"
      end
    end

    assert {:ok, replayed} = Ankole.Kernel.page_apply(source, changes)
    assert {:ok, %{content: persisted}} = Pages.get(ctx.owner, ctx.page.id)
    assert replayed.xml == persisted.content
    assert persisted.plain_text == "Hello world"
    replayed.xml
  end

  test "a direct thread read includes replies and unread state without walking list cursors",
       ctx do
    {:ok, %{comment: root}} =
      Comments.create(ctx.contributor, ctx.page.id, %{body: "Older thread"})

    {:ok, _} = Comments.create(ctx.colleague, ctx.page.id, %{root_id: root.id, body: "Reply"})

    {:ok, %{comment: newer}} =
      Comments.create(ctx.contributor, ctx.page.id, %{body: "Newer thread"})

    assert {:ok, %{threads: [%{id: newer_id}], next_cursor: cursor}} =
             Comments.list(ctx.owner, ctx.page.id, %{limit: 1})

    assert newer_id == newer.id
    assert is_binary(cursor)

    assert {:ok, %{thread: %{id: id, unread: true, replies: [%{body: "Reply"}]}}} =
             Comments.read(ctx.owner, ctx.page.id, root.id)

    assert id == root.id

    assert {:error, :not_found} =
             Comments.read(ctx.owner, ctx.page.id, Ankole.Ecto.UUIDv7.autogenerate())

    {:ok, summary} = Activity.summary(ctx.owner, ctx.page.id)
    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> ctx.page.id)
    assert {:ok, _} = Activity.acknowledge(ctx.owner, ctx.page.id, summary.activity_at)
    owner_uid = Ankole.AuthZ.Actor.uid(ctx.owner)
    assert_receive {:comments_read, ^owner_uid}
    refute_receive {:comments_committed, _}
    assert {:ok, %{thread: %{unread: false}}} = Comments.read(ctx.owner, ctx.page.id, root.id)
  end

  test "comment capabilities enforce custom action subsets, block downgraded former authors, and return post-touch root activity_at",
       ctx do
    edit_only = human_fixture(%{display_name: "Custom Editor"}).principal |> actor_fixture()
    manage_only = human_fixture(%{display_name: "Custom Manager"}).principal |> actor_fixture()

    for action <- ["page_view", "page_edit"] do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: edit_only.principal.uid,
          resource_pattern: "pod:**:#{ctx.page.id}:page",
          action: action
        })
    end

    for action <- ["page_view", "page_manage"] do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: manage_only.principal.uid,
          resource_pattern: "pod:**:#{ctx.page.id}:page",
          action: action
        })
    end

    {:ok, %{comment: root}} =
      Comments.create(ctx.contributor, ctx.page.id, %{body: "Initial thread"})

    # Custom page_edit without page_comment can resolve and reanchor, yet cannot create or edit/delete another's comment.
    assert {:ok, %{thread: edit_thread}} = Comments.read(edit_only, ctx.page.id, root.id)
    assert edit_thread.can_resolve == true
    assert edit_thread.can_reanchor == true
    assert edit_thread.can_edit == false
    assert edit_thread.can_delete == false

    assert {:error, :forbidden} =
             Comments.create(edit_only, ctx.page.id, %{body: "Blocked comment"})

    assert {:error, :forbidden} =
             Comments.update(edit_only, ctx.page.id, root.id, %{
               version: root.version,
               body: "Blocked edit"
             })

    assert {:ok, %{comment: anchored, revision: rev_after_anchor}} =
             Comments.anchor(edit_only, ctx.page.id, root.id, %{
               version: root.version,
               base_revision: 1,
               from: 1,
               to: 6
             })

    assert anchored.anchor_present == true
    assert rev_after_anchor == 2

    assert {:ok, %{comment: resolved}} =
             Comments.resolve(edit_only, ctx.page.id, root.id, %{
               version: anchored.version,
               resolved: true
             })

    assert not is_nil(resolved.resolved_at)

    assert {:ok, %{thread: persisted_after_resolve}} =
             Comments.read(ctx.owner, ctx.page.id, root.id)

    assert resolved.activity_at == persisted_after_resolve.activity_at
    assert DateTime.compare(resolved.activity_at, root.activity_at) in [:gt, :eq]

    # Downgraded former author loses own-comment edit/delete/resolve/anchor permissions.
    {:ok, sharing} = Pages.sharing(ctx.owner, ctx.page.id)

    {:ok, _} =
      Pages.update_sharing(ctx.owner, ctx.page.id, %{
        upserts: [
          %{principal_uid: ctx.contributor.principal.uid, role: "view", target_scope: "container"}
        ]
      })

    assert is_binary(sharing.sharing_version)

    assert {:error, :forbidden} =
             Comments.update(ctx.contributor, ctx.page.id, root.id, %{
               version: resolved.version,
               body: "Former author edit"
             })

    assert {:error, :forbidden} =
             Comments.resolve(ctx.contributor, ctx.page.id, root.id, %{
               version: resolved.version,
               resolved: false
             })

    assert {:error, :forbidden} =
             Comments.delete(ctx.contributor, ctx.page.id, root.id, %{
               version: resolved.version
             })

    # Custom page_manage without page_comment can update and delete, and root update returns post-touch activity_at.
    assert {:ok, %{thread: manage_thread}} = Comments.read(manage_only, ctx.page.id, root.id)
    assert manage_thread.can_edit == true
    assert manage_thread.can_delete == true
    assert manage_thread.can_resolve == false
    assert manage_thread.can_reanchor == false

    assert {:error, :forbidden} =
             Comments.create(manage_only, ctx.page.id, %{body: "Manager without comment bit"})

    assert {:ok, %{comment: updated}} =
             Comments.update(manage_only, ctx.page.id, root.id, %{
               version: resolved.version,
               body: "Managed body"
             })

    assert {:ok, %{thread: persisted_after_update}} =
             Comments.read(ctx.owner, ctx.page.id, root.id)

    assert updated.activity_at == persisted_after_update.activity_at

    assert {:ok, %{comment: deleted}} =
             Comments.delete(manage_only, ctx.page.id, root.id, %{version: updated.version})

    assert not is_nil(deleted.deleted_at)
  end
end
