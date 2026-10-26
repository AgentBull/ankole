defmodule Ankole.Pod.HomePlanTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ
  alias Ankole.Pod.{Access, Bases, Documents, PageChange, PageContent, Pages}

  test "contributors write records while editors own structure and managers delete tables" do
    owner = human_fixture().principal
    human = human_fixture().principal
    agent = agent_fixture().principal
    owner_actor = actor_fixture(owner)

    {:ok, page} = Pages.create(owner_actor, %{type: "base", private_owner_uid: owner.uid})
    assert {:ok, %{tables: [table]}} = Bases.list_tables(owner_actor, page.id)
    assert table.name == "Table 1"
    assert [%{name: "Name", is_primary: true}] = Bases.fields(table.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{principal_uid: human.uid, role: "contribute"},
          %{principal_uid: agent.uid, role: "edit"}
        ]
      })

    human_actor = actor_fixture(human)
    mixed_actor = AuthZ.Actor.new(agent, interactive_principal: human)
    assert {:ok, reachable} = Access.reachable_anchors(mixed_actor)
    assert Access.page_bits(Repo.get!(Ankole.Pod.Page, page.id), reachable) == 3

    for actor <- [human_actor, mixed_actor] do
      assert {:ok, %{records: [record]}} =
               Bases.write_records(actor, table.id, %{creates: [%{data: %{}}]})

      assert {:ok, %{records: []}} =
               Bases.write_records(actor, table.id, %{
                 deletes: [%{id: record.id, expected_versions: record.versions}]
               })

      assert {:error, :forbidden} =
               Bases.create_field(actor, table.id, %{name: "Hidden", type: "text"})

      assert {:error, :forbidden} = Bases.create_table(actor, page.id, %{name: "Hidden"})
      assert {:error, :forbidden} = Bases.delete_table(actor, table.id)
      assert {:error, :forbidden} = Pages.update(actor, page.id, %{title: "Hidden"})
      assert {:error, :forbidden} = Pages.create(actor, %{parent_id: page.id})
    end

    assert {:ok, _} =
             Bases.create_field(actor_fixture(agent), table.id, %{name: "Notes", type: "text"})

    assert {:error, :forbidden} = Bases.delete_table(actor_fixture(agent), table.id)
    assert {:ok, _} = Bases.delete_table(owner_actor, table.id)
    assert {:ok, %{tables: []}} = Bases.list_tables(owner_actor, page.id)
  end

  test "table deletion requires removal of incoming link fields" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "base"})
    {:ok, %{tables: [target]}} = Bases.list_tables(actor, page.id)
    {:ok, source} = Bases.create_table(actor, page.id, %{name: "References"})

    {:ok, link} =
      Bases.create_field(actor, source.id, %{
        name: "Target",
        type: "link",
        config: %{"table_id" => target.id}
      })

    assert {:error, :table_referenced} = Bases.delete_table(actor, target.id)
    assert {:ok, _} = Bases.get_table(actor, target.id)
    assert {:ok, _} = Bases.delete_field(actor, link.id, link.version)
    assert {:ok, _} = Bases.delete_table(actor, target.id)
    assert {:error, :not_found} = Bases.get_table(actor, target.id)
    assert {:ok, %{tables: [remaining]}} = Bases.list_tables(actor, page.id)
    assert remaining.id == source.id
  end

  test "conditional contribution is evaluated by CEL and cannot create a Space root" do
    owner = human_fixture().principal
    human = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "base", private_owner_uid: owner.uid})
    {:ok, %{tables: [table]}} = Bases.list_tables(actor, page.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{
            principal_uid: human.uid,
            role: "contribute",
            condition: ~s(context.request.ip == "10.0.0.1")
          }
        ]
      })

    admitted = AuthZ.Actor.new(human, authn: %{"ip" => "10.0.0.1"})
    rejected = AuthZ.Actor.new(human, authn: %{"ip" => "10.0.0.2"})

    assert {:ok, %{records: [_]}} =
             Bases.write_records(admitted, table.id, %{creates: [%{data: %{}}]})

    assert {:error, :forbidden} =
             Bases.write_records(rejected, table.id, %{creates: [%{data: %{}}]})

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:pod_space",
        action: "update"
      })

    {:ok, _} = Pages.set_space(actor, "contribute")
    assert {:error, :forbidden} = Pages.create(actor_fixture(human), %{title: "Disallowed"})
  end

  test "all page types accept children and document text search respects visibility" do
    owner = human_fixture().principal
    outsider = human_fixture().principal
    actor = actor_fixture(owner)

    for type <- ~w(doc base applet file) do
      assert {:ok, parent} = Pages.create(actor, %{type: type, private_owner_uid: owner.uid})
      assert {:ok, child} = Pages.create(actor, %{parent_id: parent.id, title: "Manual"})
      assert child.parent_id == parent.id
    end

    {:ok, page} = Pages.create(actor, %{private_owner_uid: owner.uid, title: "Specification"})
    {:ok, _} = Documents.write(actor, page.id, 0, "<page><p>正文中的检索词😀</p></page>")
    assert {:ok, %{pages: [found]}} = Pages.search(actor, "检索词")
    assert found.id == page.id
    assert {:ok, [found]} = Pages.list(actor, %{query: "检索词"})
    assert found.id == page.id
    assert {:ok, %{pages: []}} = Pages.search(actor_fixture(outsider), "检索词")
  end

  test "Space creation hints use the same effective permission as page creation" do
    owner = human_fixture().principal
    human = human_fixture().principal
    agent = agent_fixture().principal
    owner_actor = actor_fixture(owner)

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:pod_space",
        action: "update"
      })

    {:ok, _} = Pages.space_agent(owner_actor, agent.uid, "edit")
    actor = actor_fixture(human)
    mixed = AuthZ.Actor.new(agent, interactive_principal: human)

    for role <- ~w(view contribute edit manage) do
      {:ok, _} = Pages.set_space(owner_actor, role)
      allowed = role in ~w(edit manage)
      assert Pages.can_create_space?(actor) == allowed
      assert Pages.can_create_space?(mixed) == allowed
      assert {:ok, %{can_create_space: ^allowed}} = Pages.list_children(actor, nil)
      assert {:ok, %{can_create_space: ^allowed}} = Pages.search(actor, "")

      if allowed,
        do: assert({:ok, _} = Pages.create(actor, %{title: "Allowed"})),
        else: assert({:error, :forbidden} = Pages.create(actor, %{title: "Denied"}))
    end
  end

  test "Space defaults preserve conditional access without promoting it to every member" do
    owner = human_fixture().principal
    human = human_fixture().principal
    actor = actor_fixture(owner)

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:pod_space",
        action: "update"
      })

    {:ok, _} = Pages.set_space(actor, "view")
    {:ok, group} = Access.space_group()

    for action <- ~w(page_view page_write_records page_edit) do
      {:ok, _} =
        AuthZ.create_permission_grant(%{
          group_id: group.id,
          resource_pattern: "pod:space:**",
          action: action,
          condition: ~s(context.request.ip == "10.0.0.1")
        })
    end

    assert {:ok, %{role: "view"}} = Pages.space(actor)
    assert {:ok, _} = Pages.set_space(actor, "contribute")
    assert {:ok, %{role: "contribute"}} = Pages.space(actor)
    admitted = AuthZ.Actor.new(human, authn: %{"ip" => "10.0.0.1"})
    rejected = AuthZ.Actor.new(human, authn: %{"ip" => "10.0.0.2"})
    assert {:ok, _} = Pages.create(admitted, %{title: "Conditional editor"})
    assert {:error, :forbidden} = Pages.create(rejected, %{title: "Contributor"})
  end

  test "page metadata preserves independent actions across navigation, edits, moves and Trash" do
    owner = human_fixture().principal
    human = human_fixture().principal
    actor = actor_fixture(owner)
    caller = actor_fixture(human)
    {:ok, destination} = Pages.create(actor, %{private_owner_uid: owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, destination.id, %{
        grants: [%{principal_uid: human.uid, role: "edit"}]
      })

    for {role, actions} <- [
          {"edit", ~w(page_view page_edit)},
          {"manage", ~w(page_view page_manage)}
        ] do
      {:ok, page} = Pages.create(actor, %{type: "base", private_owner_uid: owner.uid})

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
          inherit_permissions: false,
          grants: [%{principal_uid: human.uid, actions: actions}]
        })

      assert {:ok, %{actions: ^actions, page: %{actions: ^actions}}} = Pages.get(caller, page.id)
      assert {:ok, listed} = Pages.list(caller, %{scope: "shared"})
      assert Enum.find(listed, &(&1.id == page.id)).actions == actions
      assert {:ok, %{pages: searched}} = Pages.search(caller, "")
      assert Enum.find(searched, &(&1.id == page.id)).actions == actions
      assert {:ok, %{tables: [table]}} = Bases.list_tables(caller, page.id)

      assert {:error, :forbidden} =
               Bases.write_records(caller, table.id, %{creates: [%{data: %{}}]})

      if role == "edit" do
        assert {:ok, _} = Pages.update(caller, page.id, %{title: "Editable structure"})
        assert {:ok, _} = Bases.create_field(caller, table.id, %{name: "Notes", type: "text"})
        assert {:error, :forbidden} = Pages.delete(caller, page.id)
      else
        assert {:error, :forbidden} = Pages.update(caller, page.id, %{title: "Not editable"})

        assert {:error, :forbidden} =
                 Bases.create_field(caller, table.id, %{name: "Notes", type: "text"})
      end

      assert {:ok, _} = Pages.move(caller, page.id, %{parent_id: destination.id})
      assert {:ok, %{pages: children}} = Pages.list_children(caller, destination.id)
      assert Enum.find(children, &(&1.id == page.id)).actions == actions

      if role == "manage" do
        assert {:ok, _} = Pages.delete(caller, page.id)
        assert {:ok, trash} = Pages.list(caller, %{scope: "trash"})
        assert Enum.find(trash, &(&1.id == page.id)).actions == actions
        assert {:ok, _} = Pages.restore(caller, page.id)
      end
    end
  end

  test "saving separate conditional roles preserves each collaborator rule" do
    owner = human_fixture().principal
    human = human_fixture().principal
    colleague = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "base", private_owner_uid: owner.uid})
    {:ok, %{tables: [table]}} = Bases.list_tables(actor, page.id)

    grants = [
      %{
        principal_uid: human.uid,
        role: "view",
        condition: ~s(context.request.ip == "10.0.0.2")
      },
      %{
        principal_uid: human.uid,
        role: "contribute",
        condition: ~s(context.request.ip == "10.0.0.1")
      }
    ]

    writer = AuthZ.Actor.new(human, authn: %{"ip" => "10.0.0.1"})
    reader = AuthZ.Actor.new(human, authn: %{"ip" => "10.0.0.2"})

    for rules <- [grants, Enum.reverse(grants)] do
      assert {:ok, _} =
               Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
                 grants: rules ++ [%{principal_uid: colleague.uid, role: "edit"}]
               })

      assert {:ok, %{records: [_]}} =
               Bases.write_records(writer, table.id, %{creates: [%{data: %{}}]})

      assert {:ok, _} = Pages.authorize(reader, page.id, "page_view")

      assert {:error, :forbidden} =
               Bases.write_records(reader, table.id, %{creates: [%{data: %{}}]})
    end
  end

  test "saving sharing preserves the exact actions of an existing userset rule" do
    owner = human_fixture().principal
    human = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, source} = Pages.create(actor, %{private_owner_uid: owner.uid})
    {:ok, target} = Pages.create(actor, %{type: "base", private_owner_uid: owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, source.id, %{
        grants: [%{principal_uid: human.uid, role: "view"}]
      })

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        source_page_id: source.id,
        source_action: "page_view",
        resource_pattern: "pod:**:#{target.id}:**",
        action: "page_write_records"
      })

    reader = actor_fixture(human)
    assert {:error, :forbidden} = Pages.authorize(reader, target.id, "page_view")
    assert {:ok, _} = Pages.authorize(reader, target.id, "page_write_records")
    {:ok, sharing} = Pages.sharing(actor, target.id)

    sharing =
      Map.update!(sharing, :grants, &Enum.map(&1, fn grant -> Map.delete(grant, :role) end))

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(owner.uid, target.id, sharing)

    assert {:error, :forbidden} = Pages.authorize(reader, target.id, "page_view")
    assert {:ok, _} = Pages.authorize(reader, target.id, "page_write_records")
  end

  test "server edits emit incremental batches, preserve no-op revisions and append with CAS" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{})
    old = "<page><p>首段</p><p>中文😀术语</p></page>"
    target = "<page><p>首段</p><p>中文😁术语</p></page>"

    assert {:ok, %{page: %{revision: 1}}} = Documents.write(actor, page.id, 0, old)
    assert {:ok, %{page: %{revision: 1}}} = Documents.write(actor, page.id, 1, old)
    assert Repo.aggregate(PageChange, :count) == 1
    assert {:ok, %{page: %{revision: 2}}} = Documents.write(actor, page.id, 1, target)
    assert {:ok, %{changes: [change], reset_required: false}} = Documents.since(actor, page.id, 1)
    assert change.kind == :change
    assert change.client_id == "server:" <> owner.uid
    assert change.client_seq == 2
    assert hd(change.changes) == 7
    assert {:ok, %{xml: ^target}} = Ankole.Kernel.page_apply(old, change.changes)

    assert {:ok, %{page: %{revision: 3}}} =
             Documents.append(actor, page.id, 2, "<page><h2>接口规范</h2></page>")

    assert Repo.get!(PageContent, page.id).content ==
             "<page><p>首段</p><p>中文😁术语</p><h2>接口规范</h2></page>"

    assert {:error, {:revision_conflict, 3}} = Documents.append(actor, page.id, 2, "<page />")
    assert {:ok, %{page: %{revision: 3}}} = Documents.append(actor, page.id, 3, "<page />")

    assert {:error, :invalid_request} =
             Documents.apply(actor, page.id, %{
               base_revision: 3,
               client_id: "server:forged",
               client_seq: 1,
               changes: []
             })
  end
end
