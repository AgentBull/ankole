defmodule Ankole.Pod.TargetedGraphTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Snapshot
  alias Ankole.Pod.{Access, Page, Pages}

  test "targeted rights match the full graph through conditional Userset cycles" do
    owner = human_fixture().principal
    viewer = human_fixture().principal
    a = private_page(owner)
    b = private_page(owner)
    c = private_page(owner)
    d = private_page(owner)
    e = private_page(owner)

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: a.id})

    grant(%{principal_uid: viewer.uid}, a.id, "self", "page_view")

    conditional =
      grant(
        %{source_page_id: a.id, source_action: "page_view"},
        b.id,
        "container",
        "page_edit",
        ~s(context.request.ip == "10.0.0.1")
      )

    unconditional =
      grant(%{source_page_id: b.id, source_action: "page_edit"}, a.id, "container", "page_manage")

    grant(%{source_page_id: child.id, source_action: "page_manage"}, e.id, "self", "page_view")
    grant(%{source_page_id: c.id, source_action: "page_view"}, d.id, "container", "page_view")
    grant(%{source_page_id: d.id, source_action: "page_view"}, c.id, "container", "page_view")
    assert {:ok, snapshot} = Snapshot.build_pod_context_snapshot(viewer.uid)
    ids = Enum.map(snapshot["grants"], & &1["id"])
    assert conditional.id in ids
    refute unconditional.id in ids
    assert ids == Enum.uniq(ids)

    for {ip, a_bits, b_bits, child_bits} <- [
          {"10.0.0.1", 9, 4, 8},
          {"10.0.0.2", 1, 0, 0}
        ] do
      assert {:ok, full} =
               Access.reachable_anchors(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(viewer.uid, ip))
               )

      assert {:ok, context} =
               Access.context_snapshot(
                 Ankole.PrincipalsFixtures.actor_fixture(actor_context(viewer.uid, ip))
               )

      for {page, expected} <- [
            {a, a_bits},
            {b, b_bits},
            {child, child_bits},
            {c, 0},
            {d, 0},
            {e, if(ip == "10.0.0.1", do: 1, else: 0)}
          ] do
        page = Repo.get!(Page, page.id)

        assert {:ok, targeted} =
                 Access.reachable_anchors(
                   Ankole.PrincipalsFixtures.actor_fixture(actor_context(viewer.uid, ip)),
                   target_ids: [page.acl_anchor_id],
                   context: context
                 )

        assert Access.page_bits(page, full) == expected
        assert Access.page_bits(page, targeted) == expected

        for {action, bit} <- [
              {"page_view", 1},
              {"page_write_records", 2},
              {"page_edit", 4},
              {"page_manage", 8}
            ] do
          if Bitwise.band(expected, bit) == 0 do
            assert {:error, :forbidden} =
                     Pages.authorize(
                       Ankole.PrincipalsFixtures.actor_fixture(actor_context(viewer.uid, ip)),
                       page.id,
                       action
                     )
          else
            assert {:ok, _} =
                     Pages.authorize(
                       Ankole.PrincipalsFixtures.actor_fixture(actor_context(viewer.uid, ip)),
                       page.id,
                       action
                     )
          end
        end
      end
    end
  end

  test "target closure keeps deleted and Private ancestors above inheritance cuts" do
    owner = human_fixture().principal
    guest = human_fixture(%{membership: :guest}).principal
    viewer = human_fixture().principal
    private = private_page(owner)

    {:ok, private_child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: private.id})

    {:ok, shared} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{})

    {:ok, shared_child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: shared.id})

    for child <- [private_child, shared_child] do
      assert {:ok, _} =
               Ankole.Pod.PagesFixtures.set_sharing(owner.uid, child.id, %{
                 inherit_permissions: false,
                 grants: [
                   %{principal_uid: guest.uid, role: "view", target_scope: "self"},
                   %{principal_uid: viewer.uid, role: "view", target_scope: "self"}
                 ]
               })
    end

    assert_equivalent(guest.uid, private_child.id, 0)
    assert_equivalent(guest.uid, shared_child.id, 1)
    assert_equivalent(viewer.uid, private_child.id, 1)
    assert {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), shared.id)
    assert_equivalent(viewer.uid, shared_child.id, 0)

    assert {:error, :not_found} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               shared_child.id,
               "page_view"
             )
  end

  test "batched Trash evaluation opens only its own tombstone and preserves live descendants" do
    owner = human_fixture().principal
    viewer = human_fixture().principal
    a = private_page(owner)
    b = private_page(owner)

    {:ok, source} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: a.id})

    {:ok, nested} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: a.id})

    {:ok, nested_source} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{parent_id: nested.id})

    grant(%{principal_uid: viewer.uid}, source.id, "self", "page_view")
    grant(%{principal_uid: viewer.uid}, nested_source.id, "self", "page_view")
    grant(%{source_page_id: source.id, source_action: "page_view"}, a.id, "self", "page_manage")
    grant(%{source_page_id: source.id, source_action: "page_view"}, b.id, "self", "page_manage")

    grant(
      %{source_page_id: nested_source.id, source_action: "page_view"},
      a.id,
      "self",
      "page_edit"
    )

    assert {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), nested.id)
    assert {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), a.id)
    assert {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), b.id)

    assert {:ok, context} =
             Access.context_snapshot(Ankole.PrincipalsFixtures.actor_fixture(viewer.uid))

    assert {:ok, batched} =
             Access.reachable_trashed(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               [a.id, b.id],
               context: context
             )

    for {id, expected} <- [{a.id, 8}, {b.id, 0}] do
      page = Repo.get!(Page, id)

      assert {:ok, full} =
               Access.reachable_anchors(Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
                 trash_page_id: id,
                 context: context
               )

      assert {:ok, targeted} =
               Access.reachable_anchors(Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
                 trash_page_id: id,
                 target_ids: [id],
                 context: context
               )

      assert Access.page_bits(page, full) == expected
      assert Access.page_bits(page, targeted) == expected
      assert Access.page_bits(page, batched) == expected
    end

    assert {:ok, _} =
             Access.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               Repo.get!(Page, a.id),
               "page_manage",
               trash: true
             )

    assert {:error, :forbidden} =
             Access.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(viewer.uid),
               Repo.get!(Page, b.id),
               "page_manage",
               trash: true
             )
  end

  test "targeted and batched rights retain the interactive Human intersection" do
    owner = human_fixture().principal
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal
    page = private_page(owner)
    grant(%{principal_uid: agent.uid}, page.id, "container", "page_manage")
    grant(%{principal_uid: human.uid}, page.id, "self", "page_view")

    assert_equivalent(Ankole.AuthZ.Actor.new(agent, interactive_principal: human), page.id, 0)

    grant(%{principal_uid: agent.uid}, page.id, "self", "page_view")

    assert_equivalent(Ankole.AuthZ.Actor.new(agent, interactive_principal: human), page.id, 1)

    assert {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id)

    assert {:ok, context} =
             Access.context_snapshot(
               Ankole.PrincipalsFixtures.actor_fixture(
                 Ankole.AuthZ.Actor.new(agent, interactive_principal: human)
               )
             )

    assert {:ok, rights} =
             Access.reachable_trashed(
               Ankole.PrincipalsFixtures.actor_fixture(
                 Ankole.AuthZ.Actor.new(agent, interactive_principal: human)
               ),
               [page.id],
               context: context
             )

    assert Access.page_bits(Repo.get!(Page, page.id), rights) == 1
  end

  defp assert_equivalent(uid, id, expected) do
    page = Repo.get!(Page, id)
    assert {:ok, full} = Access.reachable_anchors(Ankole.PrincipalsFixtures.actor_fixture(uid))

    assert {:ok, targeted} =
             Access.reachable_anchors(Ankole.PrincipalsFixtures.actor_fixture(uid),
               target_ids: [page.acl_anchor_id]
             )

    assert Access.page_bits(page, full) == expected
    assert Access.page_bits(page, targeted) == expected
  end

  defp private_page(owner) do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    page
  end

  defp grant(subject, target, scope, action, condition \\ "true") do
    suffix = if scope == "container", do: "**", else: "page"

    assert {:ok, grant} =
             AuthZ.create_permission_grant(
               Map.merge(subject, %{
                 resource_pattern: "pod:**:#{target}:#{suffix}",
                 action: action,
                 condition: condition
               })
             )

    grant
  end

  defp actor_context(uid, ip) do
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    %{actor | authn: %{"ip" => ip}}
  end
end
