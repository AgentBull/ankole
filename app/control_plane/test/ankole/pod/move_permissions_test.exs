defmodule Ankole.Pod.MovePermissionsTest do
  use Ankole.DataCase, async: true
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
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    {:ok, _} = Pages.set_space(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), "edit")

    {:ok, _} =
      Pages.space_agent(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), agent.uid, "edit")

    %{owner: owner, editor: editor, viewer: viewer, agent: agent}
  end

  test "Human and Agent editors move an unchanged policy without gaining delete or sharing access",
       ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: page.id})

    share(ctx.owner, child, %{grants: [%{principal_uid: ctx.viewer.uid, role: "manage"}]})
    before = permissions(ctx, [page, child])

    assert {:ok, %{page: %{id: id, parent_id: parent}}} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })

    assert id == page.id
    assert parent == right.id
    assert permissions(ctx, [page, child]) == before

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.editor.uid), page.id, %{
               parent_id: left.id
             })

    assert permissions(ctx, [page, child]) == before

    assert {:error, :forbidden} =
             Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id)

    assert {:error, :forbidden} = share(ctx.agent, page, %{inherit_permissions: false})
  end

  test "equal actor roles do not hide another subject's changed access", ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    share(ctx.owner, left, %{grants: [%{principal_uid: ctx.viewer.uid, role: "manage"}]})

    assert {:error, :move_requires_manage} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })

    assert Repo.get!(Page, page.id).parent_id == left.id

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               parent_id: right.id
             })

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.viewer.uid),
               page.id,
               "page_manage"
             )
  end

  test "equivalent restricted boundaries and inherited Private grants can be moved with edit",
       ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    grants = [%{principal_uid: ctx.agent.uid, role: "edit"}]
    share(ctx.owner, left, %{inherit_permissions: false, grants: grants})
    share(ctx.owner, right, %{inherit_permissions: false, grants: grants})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    {:ok, restricted} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: page.id})

    share(ctx.owner, restricted, %{inherit_permissions: false})
    before = permissions(ctx, [page, restricted])

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })

    assert permissions(ctx, [page, restricted]) == before

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    share(ctx.owner, private, %{grants: grants})

    {:ok, a} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        parent_id: private.id
      })

    {:ok, b} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        parent_id: private.id
      })

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: a.id})

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: b.id
             })

    assert {:error, :move_requires_manage} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: nil
             })
  end

  test "group policy is compared by owner rather than its current members", ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    {:ok, group} =
      AuthZ.create_principal_group(%{name: "future-editors", display_name: "Future editors"})

    grants = [%{group_id: group.id, role: "manage"}]
    share(ctx.owner, left, %{grants: grants})

    assert {:error, :move_requires_manage} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })

    share(ctx.owner, right, %{grants: grants})

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })
  end

  for source <- [:private, :space] do
    @source source
    test "an editor cannot change Guest access when moving from #{source} across the Private boundary",
         ctx do
      guest = human_fixture(%{membership: :guest}).principal

      {:ok, private} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
          private_owner_uid: ctx.owner.uid
        })

      {:ok, space} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

      grants = [
        %{principal_uid: ctx.owner.uid, role: "manage"},
        %{principal_uid: ctx.editor.uid, role: "edit"}
      ]

      assert {:ok, _} = share(ctx.owner, private, %{grants: grants})
      assert {:ok, _} = share(ctx.owner, space, %{inherit_permissions: false, grants: grants})
      {source, destination} = if @source == :private, do: {private, space}, else: {space, private}

      {:ok, page} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
          parent_id: space.id
        })

      {:ok, child} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: page.id})

      assert {:ok, _} =
               share(ctx.owner, child, %{grants: [%{principal_uid: guest.uid, role: "view"}]})

      if @source == :private do
        assert {:ok, _} =
                 Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
                   parent_id: private.id
                 })
      end

      assert {:ok, _} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.editor.uid),
                 page.id,
                 "page_edit"
               )

      assert {:ok, _} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.editor.uid),
                 destination.id,
                 "page_edit"
               )

      assert {:error, :forbidden} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.editor.uid),
                 page.id,
                 "page_manage"
               )

      assert {:error, :forbidden} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.editor.uid),
                 destination.id,
                 "page_manage"
               )

      assert {:error, :forbidden} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                 page.id,
                 "page_view"
               )

      if @source == :private do
        assert {:error, :forbidden} =
                 Pages.authorize(
                   Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                   child.id,
                   "page_view"
                 )
      else
        assert {:ok, _} =
                 Pages.authorize(
                   Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                   child.id,
                   "page_view"
                 )
      end

      assert {:error, :move_requires_manage} =
               Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.editor.uid), page.id, %{
                 parent_id: destination.id
               })

      assert Repo.get!(Page, page.id).parent_id == source.id

      if @source == :private do
        assert {:error, :forbidden} =
                 Pages.authorize(
                   Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                   child.id,
                   "page_view"
                 )
      else
        assert {:ok, _} =
                 Pages.authorize(
                   Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                   child.id,
                   "page_view"
                 )
      end

      assert {:ok, _} =
               Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
                 parent_id: destination.id
               })

      assert Repo.get!(Page, page.id).parent_id == destination.id

      assert {:error, :forbidden} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                 page.id,
                 "page_view"
               )

      if @source == :private do
        assert {:ok, _} =
                 Pages.authorize(
                   Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                   child.id,
                   "page_view"
                 )
      else
        assert {:error, :forbidden} =
                 Pages.authorize(
                   Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
                   child.id,
                   "page_view"
                 )
      end
    end
  end

  test "unrelated conditions do not block moves and path globs are rejected", ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    grant(ctx.viewer, "pod:private:unused:**", "page_manage", ~s(context.request.ip == "never"))

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })

    assert {:error, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: ctx.viewer.uid,
               resource_pattern: "pod:space:**:#{page.id}:page",
               action: "page_manage"
             })

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: left.id
             })
  end

  test "a custom source manage action does not require an additional source edit action", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, destination} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    share(ctx.owner, page, %{inherit_permissions: false})
    grant(ctx.agent, "pod:**:#{page.id}:**", "page_manage")

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               page.id,
               "page_edit"
             )

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: destination.id
             })
  end

  test "conditional inherited grants need manage across anchors", ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    grant(ctx.viewer, "pod:**:#{left.id}:**", "page_manage", ~s|context.request.ip == "10.0.0.1"|)

    assert {:error, :move_requires_manage} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: left.id,
               position: "a"
             })

    share(ctx.owner, page, %{
      inherit_permissions: false,
      grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
    })

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })
  end

  test "equivalent upstream Userset cycles converge without involving the moving page", ctx do
    {:ok, source} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, other} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    share(ctx.owner, source, %{
      inherit_permissions: false,
      grants: [
        %{principal_uid: ctx.viewer.uid, role: "view"},
        %{source_page_id: other.id, source_action: "page_view", role: "view"}
      ]
    })

    share(ctx.owner, other, %{
      inherit_permissions: false,
      grants: [%{source_page_id: source.id, source_action: "page_view", role: "view"}]
    })

    for target <- [left, right] do
      share(ctx.owner, target, %{
        grants: [%{source_page_id: source.id, source_action: "page_view", role: "view"}]
      })
    end

    before = permissions(ctx, [page])

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })

    assert permissions(ctx, [page]) == before
  end

  test "private owner wildcards are rejected and exact grants preserve move checks", ctx do
    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, restricted} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    grants = [%{principal_uid: ctx.agent.uid, role: "edit"}]
    share(ctx.owner, private, %{grants: grants})
    share(ctx.owner, restricted, %{inherit_permissions: false, grants: grants})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        parent_id: private.id
      })

    assert {:error, _} =
             AuthZ.create_permission_grant(%{
               principal_uid: ctx.viewer.uid,
               resource_pattern: "pod:private:*:**",
               action: "page_manage"
             })

    grant(ctx.viewer, "pod:private:#{ctx.owner.uid}:**", "page_manage")

    assert {:error, :move_requires_manage} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: restricted.id
             })

    assert Repo.get!(Page, page.id).parent_id == private.id
  end

  test "equal canonical policies do not discard the space administrator fallback", ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, right} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, all_humans} = Access.space_group()

    grants = [
      %{principal_uid: ctx.owner.uid, role: "manage"},
      %{principal_uid: ctx.agent.uid, role: "edit"},
      %{group_id: all_humans.id, role: "edit"}
    ]

    share(ctx.owner, left, %{grants: grants})
    share(ctx.owner, right, %{inherit_permissions: false, grants: grants})

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    assert {:error, :move_requires_manage} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: right.id
             })
  end

  test "edit preserves the space administrator fallback and destination and tree constraints",
       ctx do
    {:ok, left} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: left.id})

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: page.id})

    {:ok, leaf} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        type: "file",
        parent_id: left.id
      })

    share(ctx.owner, page, %{
      inherit_permissions: false,
      grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
    })

    assert {:error, :forbidden} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: private.id
             })

    assert {:error, :cycle} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: child.id
             })

    assert {:ok, %{page: moved}} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: leaf.id
             })

    assert moved.parent_id == leaf.id

    assert {:error, :not_found} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: "invalid"
             })

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), left.id)

    assert {:error, :not_found} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               parent_id: nil
             })
  end

  defp permissions(ctx, pages) do
    for actor <- [ctx.owner, ctx.editor, ctx.viewer, ctx.agent],
        page <- pages,
        action <- Access.page_actions(),
        do:
          {actor.uid, page.id, action,
           Pages.authorize(Ankole.PrincipalsFixtures.actor_fixture(actor.uid), page.id, action)
           |> elem(0)}
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
