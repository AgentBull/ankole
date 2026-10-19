defmodule Ankole.Pod.AccessReviewTest do
  use Ankole.DataCase, async: false
  use ExUnitProperties
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Access, Pages}

  setup do
    owner = human_fixture().principal
    member = human_fixture().principal
    outsider = human_fixture().principal
    agent = agent_fixture().principal

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "**",
        action: "update"
      })

    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{name: "editors", display_name: "Editors"})

    {:ok, _} = Ankole.AuthZ.add_principal_to_group(member.uid, group.id)
    {:ok, _} = Ankole.AuthZ.add_principal_to_group(agent.uid, group.id)
    %{owner: owner, member: member, outsider: outsider, agent: agent, group: group}
  end

  test "reads and repeated tenant scaffolding never restore removed space permissions", ctx do
    {:ok, group} = Access.ensure_space()
    {:ok, _} = Pages.set_space(ctx.owner.uid, "view")

    grant =
      Repo.get_by!(Ankole.AuthZ.Grant,
        group_id: group.id,
        resource_pattern: "pod:space:**",
        action: "page_view"
      )

    {:ok, _} = Ankole.AuthZ.delete_permission_grant(grant.id)
    assert :ok = Ankole.Tenants.ensure_scaffold(ctx.tenant)
    assert {:ok, []} = Pages.list(ctx.member.uid)
    assert {:ok, _} = Access.ensure_space()
    assert {:ok, []} = Ankole.AuthZ.list_group_grants(group.id)
    assert {:error, {:forbidden, "update"}} = Pages.create(ctx.member.uid, %{})
  end

  property "navigation agrees with single-page AuthZ for groups, Agents, defaults, restrictions and trash",
           ctx do
    check all(
            plan <-
              list_of(
                tuple(
                  {integer(0..20), boolean(), boolean(), member_of(~w(view edit manage)),
                   boolean()}
                ),
                min_length: 4,
                max_length: 12
              ),
            max_runs: 8
          ) do
      {:ok, _} = Pages.set_space(ctx.owner.uid, elem(hd(plan), 3))
      {:ok, _} = Pages.space_agent(ctx.owner.uid, ctx.agent.uid, "view")

      pages =
        Enum.reduce(plan, [], fn {parent_index, private, restricted, role, _deleted}, pages ->
          parent =
            if pages != [] and rem(parent_index, 3) != 0,
              do: Enum.at(pages, rem(parent_index, length(pages))).id

          owner = if is_nil(parent) and private, do: ctx.owner.uid

          {:ok, page} =
            Pages.create(ctx.owner.uid, %{parent_id: parent, private_owner_uid: owner})

          {:ok, page} =
            Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
              inherit_permissions: not restricted,
              grants: [%{group_id: ctx.group.id, role: role}]
            })

          pages ++ [page]
        end)

      Enum.zip(pages, plan)
      |> Enum.reverse()
      |> Enum.each(fn {page, {_, _, _, _, deleted}} ->
        if deleted, do: Pages.delete(ctx.owner.uid, page.id)
      end)

      ids = MapSet.new(pages, & &1.id)

      for actor <- [ctx.owner, ctx.member, ctx.outsider, ctx.agent] do
        {:ok, listed} = Pages.list(actor.uid)
        listed_ids = listed |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.intersection(ids)

        for action <- Access.page_actions() do
          {:ok, visible} = Access.visible_ids(actor.uid, action)
          actual = MapSet.intersection(MapSet.new(visible), ids)

          expected =
            MapSet.new(
              for page <- pages,
                  {:ok, _} <- [Pages.authorize(actor.uid, page.id, action)],
                  do: page.id
            )

          assert actual == expected
          if action == "page_view", do: assert(listed_ids == expected)
        end

        for page <- listed, MapSet.member?(ids, page.id) do
          {:ok, detail} = Pages.get(actor.uid, page.id)
          assert page.role == detail.role
        end
      end
    end
  end

  test "an Agent cannot create or move a page into its own Private root", ctx do
    {:ok, _} = Pages.space_agent(ctx.owner.uid, ctx.agent.uid, "manage")
    assert {:error, :forbidden} = Pages.create(ctx.agent.uid, %{private_owner_uid: ctx.agent.uid})
    {:ok, page} = Pages.create(ctx.owner.uid, %{})

    assert {:error, :forbidden} =
             Pages.move(ctx.agent.uid, page.id, %{private_owner_uid: ctx.agent.uid})

    assert {:ok, _} = Pages.get(ctx.member.uid, page.id)
  end

  test "Shared includes the current subject's direct grants only when its parent is invisible",
       ctx do
    {:ok, space} = Pages.create(ctx.owner.uid, %{})
    {:ok, private} = Pages.create(ctx.owner.uid, %{private_owner_uid: ctx.owner.uid})
    {:ok, child} = Pages.create(ctx.owner.uid, %{parent_id: private.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, space.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    assert {:ok, []} = Pages.list(ctx.member.uid, %{scope: "shared"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        grants: [%{group_id: ctx.group.id, role: "view"}]
      })

    assert {:ok, [shared]} = Pages.list(ctx.member.uid, %{scope: "shared"})
    assert shared.id == child.id

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, private.id, %{
        grants: [%{principal_uid: ctx.member.uid, role: "view"}]
      })

    assert {:ok, [shared]} = Pages.list(ctx.member.uid, %{scope: "shared"})
    assert shared.id == private.id
  end

  test "only permission changes trigger tenant-wide access checks", ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{})
    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-access:" <> Repo.tenant_id!())
    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> page.id)
    assert {:ok, _} = Pages.update(ctx.owner.uid, page.id, %{title: "Renamed"})
    assert_receive {:page_committed, _}
    refute_receive :recheck_access

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
               inherit_permissions: false
             })

    assert_receive :recheck_access
  end
end
