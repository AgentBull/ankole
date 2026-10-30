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
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{name: "editors", display_name: "Editors"})

    {:ok, _} = Ankole.AuthZ.add_principal_to_group(member.uid, group.id)
    {:ok, _} = Ankole.AuthZ.add_principal_to_group(agent.uid, group.id)
    %{owner: owner, member: member, outsider: outsider, agent: agent, group: group}
  end

  test "reads and repeated tenant scaffolding never restore removed space permissions", ctx do
    {:ok, group} = Access.space_group()
    {:ok, _} = Pages.set_space(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), "view")

    grant =
      Repo.get_by!(Ankole.AuthZ.Grant,
        group_id: group.id,
        resource_pattern: "pod:space:**",
        action: "page_view"
      )

    {:ok, _} = Ankole.AuthZ.delete_permission_grant(grant.id)
    assert :ok = Ankole.Tenants.ensure_scaffold(ctx.tenant)

    handler = "pod-read-only-#{group.id}"
    owner = self()

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, metadata, pid ->
        if self() == pid and String.starts_with?(metadata.query, ["INSERT", "UPDATE", "DELETE"]),
          do: send(pid, {:read_wrote, metadata.query})
      end,
      owner
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, []} = Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid))
    assert {:ok, _} = Pages.space(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid))
    refute_receive {:read_wrote, _}
    :telemetry.detach(handler)

    assert {:ok, []} = Ankole.AuthZ.list_group_grants(group.id)

    assert {:error, :forbidden} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{})
  end

  test "Guest collaborator search requires effective view access to a common page", ctx do
    guest = human_fixture(%{membership: :guest}).principal
    editor = human_fixture().principal
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: guest.uid, role: "view"}]
      })

    for {principal, action, condition} <- [
          {ctx.outsider, "page_view", "false"},
          {editor, "page_edit", "true"},
          {ctx.member, "page_view", ~s(context.request.ip == "10.0.0.1")}
        ] do
      assert {:ok, _} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: principal.uid,
                 resource_pattern: "pod:**:#{page.id}:page",
                 action: action,
                 condition: condition
               })
    end

    for ip <- ["10.0.0.1", "10.0.0.2"] do
      assert {:ok, _} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(guest.uid, ip)),
                 page.id,
                 "page_view"
               )

      assert {:error, :forbidden} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(ctx.outsider.uid, ip)),
                 page.id,
                 "page_view"
               )

      assert {:error, :forbidden} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(editor.uid, ip)),
                 page.id,
                 "page_view"
               )

      assert {:ok, _} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(editor.uid, ip)),
                 page.id,
                 "page_edit"
               )

      assert {:ok, subjects} =
               Pages.subjects(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(guest.uid, ip))
               )

      expected =
        [guest.uid, ctx.owner.uid] ++ if(ip == "10.0.0.1", do: [ctx.member.uid], else: [])

      assert MapSet.new(subjects, & &1.principal_uid) == MapSet.new(expected)
    end
  end

  test "collaborator preview does not assign the caller's authentication to another Principal",
       ctx do
    guest = human_fixture(%{membership: :guest}).principal
    candidate = human_fixture().principal
    {:ok, page} = Pages.create(Ankole.AuthZ.Actor.new(ctx.owner), %{})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: guest.uid, role: "view"}]
      })

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: candidate.uid,
        resource_pattern: "pod:**:#{page.id}:page",
        action: "page_view",
        condition: ~s|context.request.authn.amr.contains("mfa")|
      })

    actor = Ankole.AuthZ.Actor.new(guest, authn: %{"ip" => "10.0.0.1", "amr" => ["mfa"]})

    assert {:ok, subjects} = Pages.subjects(actor)
    refute Enum.any?(subjects, &(&1.principal_uid == candidate.uid))
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
      {:ok, _} =
        Pages.set_space(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), elem(hd(plan), 3))

      {:ok, _} =
        Pages.space_agent(
          Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
          ctx.agent.uid,
          "view"
        )

      pages =
        Enum.reduce(plan, [], fn {parent_index, private, restricted, role, _deleted}, pages ->
          parent =
            if pages != [] and rem(parent_index, 3) != 0,
              do: Enum.at(pages, rem(parent_index, length(pages))).id

          owner = if is_nil(parent) and private, do: ctx.owner.uid

          {:ok, page} =
            Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
              parent_id: parent,
              private_owner_uid: owner
            })

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
        if deleted,
          do: Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id)
      end)

      ids = MapSet.new(pages, & &1.id)

      for actor <- [ctx.owner, ctx.member, ctx.outsider, ctx.agent] do
        {:ok, listed} = Pages.list(Ankole.PrincipalsFixtures.actor_fixture(actor.uid))
        listed_ids = listed |> Enum.map(& &1.id) |> MapSet.new() |> MapSet.intersection(ids)

        expected =
          MapSet.new(
            for page <- pages,
                {:ok, current} <- [Pages.fetch(page.id)],
                {:ok, _} <- [
                  Access.authorize(
                    Ankole.PrincipalsFixtures.actor_fixture(actor.uid),
                    current,
                    "page_view",
                    trash: false
                  )
                ],
                do: page.id
          )

        assert listed_ids == expected

        for page <- listed, MapSet.member?(ids, page.id) do
          {:ok, detail} = Pages.get(Ankole.PrincipalsFixtures.actor_fixture(actor.uid), page.id)
          assert page.role == detail.role
        end
      end
    end
  end

  test "an Agent cannot create or move a page into its own Private root", ctx do
    {:ok, _} =
      Pages.space_agent(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
        ctx.agent.uid,
        "manage"
      )

    assert {:error, :forbidden} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), %{
               private_owner_uid: ctx.agent.uid
             })

    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    assert {:error, :forbidden} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, %{
               private_owner_uid: ctx.agent.uid
             })

    assert {:ok, _} = Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), page.id)
  end

  test "context conditions give matching lazy navigation and page decisions", ctx do
    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        parent_id: private.id
      })

    {:ok, hidden} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    for {target, action, scope} <- [{private, "page_view", "**"}, {child, "page_edit", "page"}] do
      assert {:ok, _} =
               Ankole.AuthZ.create_permission_grant(%{
                 group_id: ctx.group.id,
                 resource_pattern: "pod:**:#{target.id}:#{scope}",
                 action: action,
                 condition: ~s(context.request.ip == "10.0.0.1")
               })
    end

    for actor <- [ctx.member, ctx.agent] do
      assert {:ok, %{pages: listed}} =
               Pages.search(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(actor.uid, "10.0.0.1")),
                 ""
               )

      assert Enum.any?(listed, &(&1.id == private.id))
      refute Enum.any?(listed, &(&1.id == hidden.id))

      for page <- [private, child] do
        assert {:ok, detail} =
                 Pages.get(
                   Ankole.PrincipalsFixtures.actor_fixture(actor_context(actor.uid, "10.0.0.1")),
                   page.id
                 )

        assert Enum.find(listed, &(&1.id == page.id)).role == detail.role
      end

      assert {:ok, %{role: "view"}} =
               Pages.get(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(actor.uid, "10.0.0.1")),
                 private.id
               )

      assert {:ok, %{role: "edit"}} =
               Pages.get(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(actor.uid, "10.0.0.1")),
                 child.id
               )

      assert {:error, :forbidden} =
               Pages.get(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(actor.uid, "10.0.0.2")),
                 private.id
               )
    end

    assert {:error, _} =
             Ankole.AuthZ.create_permission_grant(%{
               group_id: ctx.group.id,
               resource_pattern: "pod:private:#{ctx.owner.uid}:#{private.id}:**",
               action: "page_view",
               condition: "true"
             })
  end

  test "conditional direct shares retain Shared and trash semantics", ctx do
    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        parent_id: private.id
      })

    for action <- Access.page_actions() do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: ctx.member.uid,
          resource_pattern: "pod:**:#{child.id}:**",
          action: action,
          condition: "true && true"
        })
    end

    assert {:ok, [shared]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{
               scope: "shared"
             })

    assert shared.id == child.id
    assert shared.role == "manage"

    assert {:ok, _} =
             Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), child.id)

    assert {:ok, []} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{
               scope: "shared"
             })

    assert {:ok, [trashed]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{scope: "trash"})

    assert trashed.id == child.id

    assert {:ok, _} =
             Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), private.id)

    assert {:ok, []} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{scope: "trash"})
  end

  test "conditional anchor evaluation uses one native context snapshot", ctx do
    now = DateTime.utc_now(:microsecond)

    pages =
      for index <- 1..1000 do
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: ctx.tenant.id,
          type: :doc,
          title: "Page #{index}",
          position: Integer.to_string(index),
          created_by: Ankole.ActorRef.from_principal(ctx.member),
          created_at: now,
          updated_at: now
        }
      end
      |> Enum.map(&Map.merge(&1, %{acl_anchor_id: &1.id, has_local_acl: true}))

    Repo.insert_all(Ankole.Pod.Page, pages)

    grants =
      for page <- pages do
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: ctx.tenant.id,
          principal_uid: ctx.member.uid,
          resource_pattern: "pod:**:#{page.id}:**",
          target_page_id: page.id,
          target_scope: "container",
          action: "page_view",
          condition: "true",
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Ankole.AuthZ.Grant, grants)

    assert {:ok, canonical} =
             Access.reachable_anchors(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid))

    assert map_size(canonical) == 1000

    assert {:ok, _} =
             Ankole.AuthZ.update_permission_grant(hd(grants).id, %{condition: "true && true"})

    function = {Ankole.Kernel, :authz_evaluate_pod_context, 1}
    :erlang.trace_pattern(function, true, [:call_count])

    try do
      assert {:ok, ^canonical} =
               Access.reachable_anchors(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid))

      assert :erlang.trace_info(function, :call_count) == {:call_count, 1}
    after
      :erlang.trace_pattern(function, false, [:call_count])
    end
  end

  test "Shared includes the current subject's direct grants only when its parent is invisible",
       ctx do
    {:ok, space} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        parent_id: private.id
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, space.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    assert {:ok, []} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{
               scope: "shared"
             })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        grants: [%{group_id: ctx.group.id, role: "view"}]
      })

    assert {:ok, [shared]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{
               scope: "shared"
             })

    assert shared.id == child.id

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, private.id, %{
        grants: [%{principal_uid: ctx.member.uid, role: "view"}]
      })

    assert {:ok, [shared]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.member.uid), %{
               scope: "shared"
             })

    assert shared.id == private.id
  end

  test "only permission changes trigger tenant-wide access checks", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-access:" <> Repo.tenant_id!())
    :ok = Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> page.id)

    assert {:ok, _} =
             Pages.update(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               title: "Renamed",
               expected_title: page.title
             })

    assert_receive {:page_committed, _}
    refute_receive :recheck_access

    assert {:error, :invalid_principal} =
             Pages.space_agent(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               ctx.member.uid,
               "view"
             )

    refute_receive :recheck_access

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
               inherit_permissions: false
             })

    assert_receive :recheck_access
  end

  defp actor_context(uid, ip) do
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    %{actor | authn: %{"ip" => ip}}
  end
end
