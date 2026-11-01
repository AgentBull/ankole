defmodule Ankole.Pod.AnchorPropertyTest do
  use Ankole.DataCase, async: false
  use ExUnitProperties
  import Ankole.PrincipalsFixtures
  import Bitwise
  alias Ankole.AuthZ
  alias Ankole.Files.Access
  alias Ankole.Pod.{Page, Pages}

  property "anchor permissions match a page-by-page fixed point through tree and Userset mutations" do
    check all(
            operations <-
              list_of(tuple({integer(0..5), integer(0..20), integer(0..20), boolean()}),
                min_length: 10,
                max_length: 25
              ),
            max_runs: 8
          ) do
      owner = human_fixture().principal
      viewer = human_fixture().principal

      {:ok, _} =
        AuthZ.create_permission_grant(%{
          principal_uid: owner.uid,
          resource_pattern: "tenant_console:**",
          action: "update"
        })

      {:ok, root} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          private_owner_uid: owner.uid
        })

      {:ok, other} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          private_owner_uid: owner.uid
        })

      {:ok, child} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: root.id})

      ids = [root.id, other.id, child.id]

      Enum.reduce(operations, ids, fn operation, ids ->
        ids = mutate(operation, owner, viewer, ids)

        for ip <- ["10.0.0.1", "10.0.0.2"] do
          verify(viewer, ids, ip)
        end

        ids
      end)
    end
  end

  test "a self grant cannot feed descendants and a seeded Userset cycle reaches its least fixed point" do
    owner = human_fixture().principal
    viewer = human_fixture().principal

    {:ok, a} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    {:ok, b} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: a.id})

    grant(%{principal_uid: viewer.uid}, a.id, "self", "node_view")
    grant(%{source_node_id: a.id, source_action: "node_view"}, b.id, "container", "node_view")
    grant(%{source_node_id: b.id, source_action: "node_view"}, a.id, "self", "node_view")

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               a.id,
               "node_view"
             )

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               b.id,
               "node_view"
             )

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               child.id,
               "node_view"
             )

    [seed] = Access.grants(principal_uid: viewer.uid, target_node_id: a.id)
    assert {:ok, _} = AuthZ.delete_permission_grant(seed.id)

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               a.id,
               "node_view"
             )

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               b.id,
               "node_view"
             )
  end

  test "guest sharing cannot expose Private pages or unrelated collaborators" do
    owner = human_fixture().principal
    guest = human_fixture(%{membership: :guest}).principal
    outsider = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    {:ok, shared} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    {:ok, hidden} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(outsider.uid), %{
        private_owner_uid: outsider.uid
      })

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(owner.uid, shared.id, %{
               inherit_permissions: false,
               grants: [%{principal_uid: guest.uid, role: "view", target_scope: "self"}]
             })

    grant(%{principal_uid: guest.uid}, private.id, "container", "node_manage")
    grant(%{principal_uid: outsider.uid}, hidden.id, "container", "node_view")

    assert {:error, :forbidden} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(guest.uid), %{
               private_owner_uid: guest.uid
             })

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
               private.id,
               "node_view"
             )

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
               shared.id,
               "node_view"
             )

    assert {:ok, subjects} = Pages.subjects(Ankole.PrincipalsFixtures.actor_fixture(guest.uid))
    assert Enum.any?(subjects, &(&1.principal_uid == guest.uid))
    refute Enum.any?(subjects, &(Map.get(&1, :principal_uid) == outsider.uid))
    refute Enum.any?(subjects, &(Map.get(&1, :kind) == :group))

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: agent.uid,
        resource_pattern: "drive:space:**",
        action: "node_view"
      })

    assert {:ok, %{agents: []}} = Pages.space(Ankole.PrincipalsFixtures.actor_fixture(guest.uid))

    assert {:ok, subjects} =
             Pages.subjects(
               Ankole.PrincipalsFixtures.actor_fixture(Ankole.AuthZ.Actor.new(agent))
             )

    assert Enum.any?(subjects, &(Map.get(&1, :principal_uid) == outsider.uid))
    assert Enum.any?(subjects, &(Map.get(&1, :kind) == :group))

    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
               shared.id,
               "node_view"
             )

    assert {:error, :invalid_grants} =
             Ankole.Pod.PagesFixtures.set_sharing(owner.uid, shared.id, %{
               grants: [%{principal_uid: guest.uid, role: "view"}]
             })
  end

  test "Userset provenance redacts an unreadable source and exposes an accessible source" do
    owner = human_fixture().principal
    manager = human_fixture().principal

    {:ok, source} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid,
        title: "Confidential source",
        icon: "lock"
      })

    {:ok, target} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    grant(%{principal_uid: manager.uid}, target.id, "container", "node_manage")

    grant(
      %{source_node_id: source.id, source_action: "node_view"},
      target.id,
      "self",
      "node_view"
    )

    assert {:ok, sharing} =
             Pages.sharing(Ankole.PrincipalsFixtures.actor_fixture(manager.uid), target.id)

    userset = Enum.find(sharing.grants, &(&1.kind == :userset))
    assert userset.source_page == %{id: source.id, accessible: false, title: nil, icon: nil}
    grant(%{principal_uid: manager.uid}, source.id, "self", "node_view")

    assert {:ok, sharing} =
             Pages.sharing(Ankole.PrincipalsFixtures.actor_fixture(manager.uid), target.id)

    assert Enum.find(sharing.grants, &(&1.kind == :userset)).source_page ==
             %{id: source.id, accessible: true, title: "Confidential source", icon: "lock"}
  end

  test "lazy children cursor orders equal positions without omissions or duplicates" do
    owner = human_fixture().principal
    {:ok, root} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    children =
      for index <- 1..5 do
        {:ok, page} =
          Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
            parent_id: root.id,
            title: "Child #{index}",
            position: "A"
          })

        page
      end

    assert {:ok, %{pages: first, next_cursor: cursor}} =
             Pages.list_children(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), root.id, %{
               limit: 2
             })

    assert {:ok, %{pages: second, next_cursor: cursor2}} =
             Pages.list_children(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), root.id, %{
               limit: 2,
               cursor: cursor
             })

    assert {:ok, %{pages: last, next_cursor: nil}} =
             Pages.list_children(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), root.id, %{
               limit: 2,
               cursor: cursor2
             })

    assert Enum.map(first ++ second ++ last, & &1.id) == Enum.sort(Enum.map(children, & &1.id))
    assert Enum.map([first, second, last], &length/1) == [2, 2, 1]
    assert is_binary(cursor)
    assert is_binary(cursor2)
  end

  defp mutate({kind, a, b, flag}, owner, viewer, ids) do
    page = Repo.get!(Page, Enum.at(ids, rem(a, length(ids))))
    parent = Repo.get!(Page, Enum.at(ids, rem(b, length(ids))))

    case kind do
      0 ->
        attrs =
          if is_nil(parent.deleted_at),
            do: %{parent_id: parent.id},
            else: %{private_owner_uid: owner.uid}

        case Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), attrs) do
          {:ok, created} -> ids ++ [created.id]
          {:error, :not_found} -> ids
        end

      1 ->
        scope = if flag, do: "self", else: "container"
        condition = if rem(b, 2) == 0, do: "true", else: ~s(context.request.ip == "10.0.0.1")

        if match?(
             {:ok, _},
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
               page.id,
               "node_manage"
             )
           ) do
          assert {:ok, _} =
                   Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
                     inherit_permissions: flag,
                     grants: [
                       %{
                         principal_uid: viewer.uid,
                         role: "view",
                         target_scope: scope,
                         condition: condition
                       }
                     ]
                   })
        end

        ids

      2 ->
        if page.id != parent.id and is_nil(page.deleted_at) and is_nil(parent.deleted_at) do
          case Pages.move(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id, %{
                 parent_id: parent.id
               }) do
            {:ok, _} -> :ok
            {:error, reason} when reason in [:cycle, :not_found] -> :ok
          end
        end

        ids

      3 ->
        if is_nil(page.deleted_at) do
          case Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id) do
            {:ok, _} -> :ok
            {:error, :not_found} -> :ok
          end
        else
          case Pages.restore(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id) do
            {:ok, _} -> :ok
            {:error, :cannot_restore} -> :ok
            {:error, :forbidden} -> :ok
          end
        end

        ids

      4 ->
        if page.id != parent.id do
          grant(
            %{source_node_id: parent.id, source_action: "node_view"},
            page.id,
            if(flag, do: "self", else: "container"),
            "node_view",
            if(rem(a, 2) == 0, do: "true", else: ~s(context.request.ip == "10.0.0.1"))
          )
        end

        ids

      5 ->
        if is_nil(page.deleted_at) do
          case Pages.move(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id, %{
                 parent_id: nil,
                 private_owner_uid: if(flag, do: owner.uid)
               }) do
            {:ok, _} -> :ok
            {:error, :not_found} -> :ok
          end
        end

        ids
    end
  end

  defp grant(owner, target, scope, action, condition \\ "true") do
    suffix = if scope == "container", do: "**", else: "node"

    assert {:ok, _} =
             AuthZ.upsert_permission_grant(
               Map.merge(owner, %{
                 resource_pattern: "drive:**:#{target}:#{suffix}",
                 action: action,
                 condition: condition
               })
             )
  end

  defp verify(viewer, ids, ip) do
    pages =
      Repo.all(
        from p in Page,
          where:
            p.id in ^ids or
              p.is_root
      )
      |> Map.new(&{&1.id, &1})

    grants = Access.grants(action: [in: Access.page_actions()])
    {:ok, group} = Access.space_group()
    expected = fixed_point(pages, grants, viewer.uid, group.id, ip, %{})

    assert {:ok, actual} =
             Access.reachable_anchors(
               Ankole.PrincipalsFixtures.actor_fixture(
                 Ankole.AuthZ.Actor.new(viewer, authn: %{"ip" => ip})
               )
             )

    for {id, page} <- pages do
      assert Access.page_bits(page, actual) == expected[id].self_bits
      local = Enum.any?(grants, &(&1.target_node_id == id))
      assert page.has_local_acl == local

      anchor =
        is_nil(page.parent_id) or not page.inherit_permissions or local or
          not is_nil(page.deleted_at)

      assert page.is_acl_anchor == anchor

      if anchor do
        assert page.acl_anchor_id == id

        assert page.parent_anchor_id ==
                 if(page.parent_id, do: pages[page.parent_id].acl_anchor_id)
      else
        assert page.acl_anchor_id == pages[page.parent_id].acl_anchor_id
        assert is_nil(page.parent_anchor_id)
      end
    end
  end

  defp fixed_point(pages, grants, uid, group, ip, previous) do
    next =
      Map.new(pages, fn {id, page} ->
        if live?(page, pages) do
          inherited =
            cond do
              not page.inherit_permissions ->
                0

              page.parent_id ->
                get_in(previous, [page.parent_id, :container_bits]) || 0

              page.private_owner_uid ->
                bits(grants, fn g ->
                  g.resource_pattern == "drive:private:#{page.private_owner_uid}:**" and
                    subject?(g, uid, group) and condition?(g, ip)
                end)

              true ->
                bits(grants, fn g ->
                  g.resource_pattern == "drive:space:**" and subject?(g, uid, group) and
                    condition?(g, ip)
                end)
            end

          local =
            Enum.filter(grants, fn grant ->
              grant.target_node_id == id and condition?(grant, ip) and
                (subject?(grant, uid, group) or userset?(grant, previous))
            end)

          container = bor(inherited, bits(local, &(&1.target_scope == "container")))

          {id,
           %{container_bits: container, self_bits: bor(container, bits(local, fn _ -> true end))}}
        else
          {id, %{container_bits: 0, self_bits: 0}}
        end
      end)

    if next == previous, do: next, else: fixed_point(pages, grants, uid, group, ip, next)
  end

  defp live?(%{deleted_at: deleted}, _) when not is_nil(deleted), do: false
  defp live?(%{parent_id: nil}, _), do: true
  defp live?(page, pages), do: live?(pages[page.parent_id], pages)

  defp bits(grants, filter),
    do: Enum.reduce(Enum.filter(grants, filter), 0, &bor(Access.action_bit(&1.action), &2))

  defp subject?(grant, uid, group), do: grant.principal_uid == uid or grant.group_id == group
  defp condition?(grant, ip), do: grant.condition == "true" or ip == "10.0.0.1"
  defp userset?(%{source_node_id: nil}, _), do: false

  defp userset?(grant, previous),
    do:
      band(
        get_in(previous, [grant.source_node_id, :self_bits]) || 0,
        Access.action_bit(grant.source_action)
      ) != 0
end
