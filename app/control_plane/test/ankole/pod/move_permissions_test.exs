defmodule Ankole.Pod.MovePermissionsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ
  alias Ankole.Pod.{Access, Page, Pages}

  setup do
    owner = human_fixture().principal
    editor = human_fixture().principal
    viewer = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "**",
        action: "update"
      })

    {:ok, _} = Pages.set_space(owner.uid, "edit")
    {:ok, _} = Pages.space_agent(owner.uid, agent.uid, "edit")
    %{owner: owner, editor: editor, viewer: viewer, agent: agent}
  end

  test "Human and Agent editors move an unchanged policy without gaining delete or sharing access",
       ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, right} = Pages.create(ctx.owner.uid, %{})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})
    {:ok, child} = Pages.create(ctx.owner.uid, %{parent_id: page.id})

    share(ctx.owner, child, %{grants: [%{principal_uid: ctx.viewer.uid, role: "manage"}]})
    before = permissions(ctx, [page, child])

    assert {:ok, %{id: id, parent_id: parent}} =
             Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})

    assert id == page.id
    assert parent == right.id
    assert permissions(ctx, [page, child]) == before
    assert {:ok, _} = Pages.move(ctx.editor.uid, page.id, %{parent_id: left.id})
    assert permissions(ctx, [page, child]) == before
    assert {:error, :forbidden} = Pages.delete(ctx.agent.uid, page.id)
    assert {:error, :forbidden} = share(ctx.agent, page, %{inherit_permissions: false})
  end

  test "equal actor roles do not hide another subject's changed access", ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, right} = Pages.create(ctx.owner.uid, %{})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})
    share(ctx.owner, left, %{grants: [%{principal_uid: ctx.viewer.uid, role: "manage"}]})

    assert {:error, :move_requires_manage} =
             Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})

    assert Repo.get!(Page, page.id).parent_id == left.id
    assert {:ok, _} = Pages.move(ctx.owner.uid, page.id, %{parent_id: right.id})
    assert {:error, :forbidden} = Pages.authorize(ctx.viewer.uid, page.id, "page_manage")
  end

  test "equivalent restricted boundaries and inherited Private grants can be moved with edit",
       ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, right} = Pages.create(ctx.owner.uid, %{})
    grants = [%{principal_uid: ctx.agent.uid, role: "edit"}]
    share(ctx.owner, left, %{inherit_permissions: false, grants: grants})
    share(ctx.owner, right, %{inherit_permissions: false, grants: grants})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})
    {:ok, restricted} = Pages.create(ctx.owner.uid, %{parent_id: page.id})
    share(ctx.owner, restricted, %{inherit_permissions: false})
    before = permissions(ctx, [page, restricted])
    assert {:ok, _} = Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})
    assert permissions(ctx, [page, restricted]) == before

    {:ok, private} = Pages.create(ctx.owner.uid, %{private_owner_uid: ctx.owner.uid})
    share(ctx.owner, private, %{grants: grants})
    {:ok, a} = Pages.create(ctx.owner.uid, %{parent_id: private.id})
    {:ok, b} = Pages.create(ctx.owner.uid, %{parent_id: private.id})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: a.id})
    assert {:ok, _} = Pages.move(ctx.agent.uid, page.id, %{parent_id: b.id})
    assert {:error, :move_requires_manage} = Pages.move(ctx.agent.uid, page.id, %{parent_id: nil})
  end

  test "group policy is compared by owner rather than its current members", ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, right} = Pages.create(ctx.owner.uid, %{})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})

    {:ok, group} =
      AuthZ.create_principal_group(%{name: "future-editors", display_name: "Future editors"})

    grants = [%{group_id: group.id, role: "manage"}]
    share(ctx.owner, left, %{grants: grants})

    assert {:error, :move_requires_manage} =
             Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})

    share(ctx.owner, right, %{grants: grants})
    assert {:ok, _} = Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})
  end

  test "an unrelated opaque condition does not block a move but descendant glob changes do",
       ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, right} = Pages.create(ctx.owner.uid, %{})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})
    {:ok, child} = Pages.create(ctx.owner.uid, %{parent_id: page.id})
    grant(ctx.viewer, "pod:private:unused:**", "page_manage", ~s(resource == "never"))
    grant(ctx.viewer, "pod:space:**:#{page.id}:page", "page_manage")
    assert {:ok, _} = Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})
    {:ok, path} = Access.path(Repo.get!(Page, child.id))
    grant(ctx.viewer, Access.resource(path), "page_manage")

    assert {:error, :move_requires_manage} =
             Pages.move(ctx.agent.uid, page.id, %{parent_id: left.id})

    assert Repo.get!(Page, page.id).parent_id == right.id
  end

  test "a custom source manage action does not require an additional source edit action", ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{})
    {:ok, destination} = Pages.create(ctx.owner.uid, %{})
    share(ctx.owner, page, %{inherit_permissions: false})
    grant(ctx.agent, "pod:**:#{page.id}:**", "page_manage")
    assert {:error, :forbidden} = Pages.authorize(ctx.agent.uid, page.id, "page_edit")
    assert {:ok, _} = Pages.move(ctx.agent.uid, page.id, %{parent_id: destination.id})
  end

  test "resource-sensitive CEL needs manage unless the entire resource stays unchanged", ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, right} = Pages.create(ctx.owner.uid, %{})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})
    grant(ctx.viewer, "pod:**", "page_manage", ~s|resource.contains("#{left.id}")|)

    assert {:error, :move_requires_manage} =
             Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})

    assert {:ok, _} = Pages.move(ctx.agent.uid, page.id, %{parent_id: left.id, position: "a"})

    share(ctx.owner, page, %{
      inherit_permissions: false,
      grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
    })

    assert {:ok, _} = Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})
  end

  test "a private owner glob is checked by the Kernel rather than as a literal owner", ctx do
    {:ok, private} = Pages.create(ctx.owner.uid, %{private_owner_uid: ctx.owner.uid})
    {:ok, restricted} = Pages.create(ctx.owner.uid, %{})
    grants = [%{principal_uid: ctx.agent.uid, role: "edit"}]
    share(ctx.owner, private, %{grants: grants})
    share(ctx.owner, restricted, %{inherit_permissions: false, grants: grants})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: private.id})
    grant(ctx.viewer, "pod:private:*:**", "page_manage")

    assert {:error, :move_requires_manage} =
             Pages.move(ctx.agent.uid, page.id, %{parent_id: restricted.id})

    assert Repo.get!(Page, page.id).parent_id == private.id
  end

  test "equal canonical policies do not discard the space administrator fallback", ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, right} = Pages.create(ctx.owner.uid, %{})
    {:ok, all_humans} = Access.space_group()

    grants = [
      %{principal_uid: ctx.owner.uid, role: "manage"},
      %{principal_uid: ctx.agent.uid, role: "edit"},
      %{group_id: all_humans.id, role: "edit"}
    ]

    share(ctx.owner, left, %{grants: grants})
    share(ctx.owner, right, %{inherit_permissions: false, grants: grants})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})

    assert {:error, :move_requires_manage} =
             Pages.move(ctx.agent.uid, page.id, %{parent_id: right.id})
  end

  test "edit preserves the space administrator fallback and destination and tree constraints",
       ctx do
    {:ok, left} = Pages.create(ctx.owner.uid, %{})
    {:ok, private} = Pages.create(ctx.owner.uid, %{private_owner_uid: ctx.owner.uid})
    {:ok, page} = Pages.create(ctx.owner.uid, %{parent_id: left.id})
    {:ok, child} = Pages.create(ctx.owner.uid, %{parent_id: page.id})
    {:ok, leaf} = Pages.create(ctx.owner.uid, %{type: "file"})

    share(ctx.owner, page, %{
      inherit_permissions: false,
      grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
    })

    assert {:error, :forbidden} = Pages.move(ctx.agent.uid, page.id, %{parent_id: private.id})
    assert {:error, :cycle} = Pages.move(ctx.agent.uid, page.id, %{parent_id: child.id})
    assert {:error, :invalid_parent} = Pages.move(ctx.agent.uid, page.id, %{parent_id: leaf.id})
    assert {:error, :not_found} = Pages.move(ctx.agent.uid, page.id, %{parent_id: "invalid"})
    {:ok, _} = Pages.delete(ctx.owner.uid, left.id)
    assert {:error, :not_found} = Pages.move(ctx.agent.uid, page.id, %{parent_id: nil})
  end

  defp permissions(ctx, pages) do
    for actor <- [ctx.owner, ctx.editor, ctx.viewer, ctx.agent],
        page <- pages,
        action <- Access.page_actions(),
        do: {actor.uid, page.id, action, Pages.authorize(actor.uid, page.id, action) |> elem(0)}
  end

  defp share(actor, page, attrs),
    do: Ankole.Pod.PagesFixtures.set_sharing(actor.uid, page.id, attrs)

  defp grant(actor, pattern, action, condition \\ "true") do
    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: actor.uid,
        resource_pattern: pattern,
        action: action,
        condition: condition
      })
  end
end
