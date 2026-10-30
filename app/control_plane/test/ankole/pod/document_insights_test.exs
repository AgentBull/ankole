defmodule Ankole.Pod.DocumentInsightsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Documents, PageChange, PageContent, Pages}

  setup do
    owner = human_fixture(%{display_name: "Creator"}).principal
    editor = human_fixture(%{display_name: "Body editor"}).principal
    renamer = human_fixture(%{display_name: "Title editor"}).principal
    owner_actor = actor_fixture(owner)
    {:ok, page} = Pages.create(owner_actor, %{private_owner_uid: owner.uid, title: "Draft"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{principal_uid: editor.uid, role: "edit"},
          %{principal_uid: renamer.uid, role: "edit"}
        ]
      })

    %{
      owner: owner_actor,
      editor: actor_fixture(editor),
      renamer: actor_fixture(renamer),
      page: page
    }
  end

  test "source and contributors include real body and title edits without duplicates", ctx do
    assert {:ok, initial} = Ankole.Pod.Documents.Insights.read(ctx.editor, ctx.page.id)
    assert initial.created_at == ctx.page.created_at
    assert [%{name: "Creator", role: :creator}] = initial.contributors

    assert {:ok, %{page: %{revision: 1}}} =
             Documents.write(ctx.editor, ctx.page.id, 0, "<page><p>Edited body</p></page>")

    assert {:ok, renamed} =
             Pages.update(ctx.renamer, ctx.page.id, %{
               title: "Published",
               expected_title: ctx.page.title
             })

    assert {:ok, insights} = Ankole.Pod.Documents.Insights.read(ctx.editor, ctx.page.id)
    assert insights.updated_at == renamed.updated_at

    assert [
             %{name: "Creator", role: :creator},
             %{name: "Title editor", role: :last_edited},
             %{name: "Body editor", role: :previously_edited}
           ] = insights.contributors

    assert {:ok, _} = Pages.update(ctx.renamer, ctx.page.id, %{icon: "emoji:📝"})
    assert length(Repo.get!(PageContent, ctx.page.id).contributors) == 3

    assert Repo.get!(PageContent, ctx.page.id).updated_by ==
             Ankole.ActorRef.from_actor(ctx.renamer)
  end

  test "no-op writes and unchanged metadata do not claim authorship", ctx do
    assert {:ok, %{content: content}} = Pages.get(ctx.owner, ctx.page.id)
    assert {:ok, _} = Documents.write(ctx.editor, ctx.page.id, 0, content.content)

    assert {:ok, _} =
             Pages.update(ctx.renamer, ctx.page.id, %{
               title: ctx.page.title,
               expected_title: ctx.page.title
             })

    assert {:ok, insights} = Ankole.Pod.Documents.Insights.read(ctx.owner, ctx.page.id)
    assert [%{name: "Creator", role: :creator}] = insights.contributors
  end

  test "contributors survive pruning the collaboration replay window", ctx do
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.ot_replay_window", 1)
    assert {:ok, _} = Documents.write(ctx.editor, ctx.page.id, 0, "<page><p>First</p></page>")
    assert {:ok, _} = Documents.write(ctx.renamer, ctx.page.id, 1, "<page><p>Second</p></page>")
    assert [%{revision: 2}] = Repo.all(PageChange)

    assert {:ok, insights} = Ankole.Pod.Documents.Insights.read(ctx.owner, ctx.page.id)

    assert Enum.any?(
             insights.contributors,
             &(&1.name == "Body editor" and &1.role == :previously_edited)
           )
  end

  test "page access and document type constrain insights", ctx do
    stranger = human_fixture().principal |> actor_fixture()
    assert {:error, :forbidden} = Ankole.Pod.Documents.Insights.read(stranger, ctx.page.id)

    {:ok, file} =
      Pages.create(ctx.owner, %{
        type: "file",
        private_owner_uid: Ankole.AuthZ.Actor.uid(ctx.owner)
      })

    assert {:error, :invalid_page_type} = Ankole.Pod.Documents.Insights.read(ctx.owner, file.id)

    assert {:error, :not_found} =
             Ankole.Pod.Documents.Insights.read(ctx.owner, Ecto.UUID.generate())
  end

  test "visits retain readers, hide names on request, and count sessions", ctx do
    alias Ankole.Pod.Documents.Insights

    for actor <- [ctx.owner, ctx.editor, ctx.editor] do
      assert {:ok, _} = Pages.state(actor, ctx.page.id, %{visited: true})
    end

    assert {:ok, %{daily: [%{views: 2}]}} = Insights.read(ctx.owner, ctx.page.id)
    assert {:ok, %{total: 2, viewers: [latest | _]}} = Insights.viewers(ctx.owner, ctx.page.id)
    assert latest.person.principal_uid == Ankole.AuthZ.Actor.uid(ctx.editor)

    assert {:ok, %{hide_visits: true}} =
             Pages.state(ctx.editor, ctx.page.id, %{hide_visits: true})

    assert {:ok, %{total: 1}} = Insights.viewers(ctx.owner, ctx.page.id)

    assert {:ok, %{daily: [%{views: 2}], hide_visits: true}} =
             Insights.read(ctx.editor, ctx.page.id)

    assert {:ok, _} = Pages.state(ctx.editor, ctx.page.id, %{hide_visits: false})

    assert {:ok, %{total: 2, viewers: [_], next_cursor: cursor}} =
             Insights.viewers(ctx.owner, ctx.page.id, %{limit: 1})

    assert is_binary(cursor)

    assert {:ok, %{viewers: [_], next_cursor: nil}} =
             Insights.viewers(ctx.owner, ctx.page.id, %{limit: 1, cursor: cursor})
  end

  test "readers control their own visibility but cannot list other readers", ctx do
    alias Ankole.Pod.Documents.Insights
    reader = human_fixture().principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(Ankole.AuthZ.Actor.uid(ctx.owner), ctx.page.id, %{
        grants: [%{principal_uid: reader.uid, role: "view"}]
      })

    actor = actor_fixture(reader)
    assert {:ok, _} = Pages.state(actor, ctx.page.id, %{visited: true, hide_visits: true})

    assert {:ok, %{can_view_readers: false, hide_visits: true}} =
             Insights.read(actor, ctx.page.id)

    assert {:error, :forbidden} = Insights.viewers(actor, ctx.page.id)
    assert {:ok, %{total: 0}} = Insights.viewers(ctx.owner, ctx.page.id)
  end

  test "body and title edits share a session while new comments and replies count separately",
       ctx do
    alias Ankole.Pod.{Comments, Documents.Insights}
    assert {:ok, _} = Documents.write(ctx.owner, ctx.page.id, 0, "<page><p>One</p></page>")
    assert {:ok, _} = Documents.write(ctx.owner, ctx.page.id, 1, "<page><p>Two</p></page>")

    assert {:ok, _} =
             Pages.update(ctx.owner, ctx.page.id, %{
               title: "Renamed",
               expected_title: ctx.page.title
             })

    assert {:ok, %{comment: root}} =
             Comments.create(ctx.owner, ctx.page.id, %{body: "A **question**"})

    assert {:ok, _} =
             Comments.create(ctx.editor, ctx.page.id, %{root_id: root.id, body: "A reply"})

    assert {:ok, _} =
             Comments.update(ctx.owner, ctx.page.id, root.id, %{
               version: 1,
               body: "Updated question"
             })

    assert {:ok, %{daily: [%{views: 0, edits: 1, comments: 2}]}} =
             Insights.read(ctx.owner, ctx.page.id)

    uid = Ankole.AuthZ.Actor.uid(ctx.owner)
    state = Repo.get_by!(Ankole.Pod.PageUserState, principal_uid: uid, page_id: ctx.page.id)

    Repo.update!(
      Ecto.Changeset.change(state, edited_at: DateTime.add(state.edited_at, -301, :second))
    )

    assert {:ok, _} =
             Documents.write(ctx.owner, ctx.page.id, 2, "<page><p>New session</p></page>")

    assert {:ok, %{daily: [%{edits: 2, comments: 2}]}} = Insights.read(ctx.owner, ctx.page.id)
  end
end
