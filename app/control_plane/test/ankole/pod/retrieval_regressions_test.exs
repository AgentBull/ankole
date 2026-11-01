defmodule Ankole.Pod.RetrievalRegressionsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Bases, Pages, PageUserState, Properties}
  alias Ankole.Files.Schemas.Node

  for scope <- ~w(all space private shared recent favorites) do
    @scope scope
    test "#{scope} title queries stay inside the requested list scope" do
      owner = human_fixture().principal
      other = human_fixture().principal

      {:ok, space} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          title: "Needle%_ space"
        })

      {:ok, child} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          title: "Needle%_ child",
          parent_id: space.id
        })

      {:ok, private} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          title: "Needle%_ private",
          private_owner_uid: owner.uid
        })

      {:ok, shared} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
          title: "Needle%_ shared",
          private_owner_uid: other.uid
        })

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(other.uid, shared.id, %{
          grants: [
            %{principal_uid: other.uid, role: "manage"},
            %{principal_uid: owner.uid, role: "view"}
          ]
        })

      {:ok, _} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          title: "NeedleXY distractor"
        })

      {:ok, _} =
        Pages.state(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), child.id, %{
          favorite: true
        })

      {:ok, _} =
        Pages.state(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), private.id, %{
          visited: true
        })

      expected = %{
        "all" => [space.id, child.id, private.id, shared.id],
        "space" => [space.id],
        "private" => [private.id],
        "shared" => [shared.id],
        "recent" => [private.id],
        "favorites" => [child.id]
      }

      assert {:ok, pages} =
               Pages.list(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
                 scope: @scope,
                 query: "  nEeDlE%_  "
               })

      assert MapSet.new(pages, & &1.id) == MapSet.new(expected[@scope])
    end
  end

  test "search uses each kind's displayed title and includes body and empty-title matches" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, root} = Ankole.Files.Nodes.private_root(owner.uid)

    pod_pages =
      for kind <- ~w(doc base applet) do
        {:ok, page} =
          Pages.create(actor, %{
            parent_id: root.id,
            type: kind,
            title: "Needle%_ #{kind}",
            skip_default_table: true
          })

        page
      end

    nodes =
      for kind <- [:file, :folder] do
        {:ok, node} =
          Ankole.Files.Nodes.create(actor, %{
            parent_id: root.id,
            kind: kind,
            name: "Needle%_ #{kind}"
          })

        assert {:ok, _} =
                 Repo.transact_top_level(fn ->
                   Pages.ensure_properties_in_tx(node.id, %{title: "Stale display title"})
                 end)

        node
      end

    {:ok, body} =
      Pages.create(actor, %{
        parent_id: root.id,
        title: "",
        xml: "<page><p>Needle%_ body</p></page>"
      })

    {:ok, empty} =
      Ankole.Files.Nodes.create(actor, %{parent_id: root.id, kind: :folder, name: "No properties"})

    {:ok, _} = Pages.create(actor, %{parent_id: root.id, title: "NeedleXY distractor"})
    assert {:ok, %{pages: matches}} = Pages.search(actor, "  nEeDlE%_  ")
    assert MapSet.new(matches, & &1.id) == MapSet.new(pod_pages ++ nodes ++ [body], & &1.id)
    assert {:ok, %{pages: []}} = Pages.search(actor, "Stale display title")
    assert {:ok, %{pages: all}} = Pages.search(actor, " ")
    assert Enum.any?(all, &(&1.id == empty.id and &1.title == empty.name))
    assert Enum.any?(all, &(&1.id == body.id and &1.title == ""))
  end

  test "search merges all three branches with the same global top-30 ranking" do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, root} = Ankole.Files.Nodes.private_root(owner.uid)

    titled =
      for _ <- 1..12 do
        {:ok, page} =
          Pages.create(actor, %{
            parent_id: root.id,
            title: "Needle",
            xml: "<page><p>Needle body</p></page>"
          })

        page.id
      end

    named =
      for index <- 1..12 do
        {:ok, node} =
          Ankole.Files.Nodes.create(
            actor,
            %{parent_id: root.id, kind: :file, name: "Needle #{index}"}
          )

        node.id
      end

    body =
      for index <- 1..20 do
        {:ok, page} =
          Pages.create(actor, %{
            parent_id: root.id,
            title: "Body #{index}",
            xml: "<page><p>Needle body</p></page>"
          })

        page.id
      end

    ids = titled ++ named ++ body
    now = DateTime.utc_now(:microsecond)
    Repo.update_all(from(n in Node, where: n.id in ^ids), set: [updated_at: now])
    Repo.update_all(from(p in Properties, where: p.id in ^ids), set: [updated_at: now])

    expected =
      Repo.query!(
        """
        SELECT p.id::text FROM pod_page_nodes p
        WHERE p.tenant_id = $1::text::uuid AND p.id = ANY($2::text[]::uuid[])
          AND (p.title ILIKE '%needle%' OR EXISTS (
            SELECT 1 FROM page_contents c WHERE c.tenant_id = p.tenant_id
              AND c.page_id = p.id AND c.plain_text ILIKE '%needle%'))
        ORDER BY similarity(p.title, 'needle') DESC, p.updated_at DESC, p.id ASC LIMIT 30
        """,
        [Repo.tenant_id!(), ids]
      ).rows
      |> Enum.map(&hd/1)

    assert {:ok, %{pages: actual}} = Pages.search(actor, "needle")
    assert Enum.map(actual, & &1.id) == expected
    assert length(actual) == 30
    assert Enum.any?(actual, &(&1.id in titled))
    assert Enum.any?(actual, &(&1.id in named))
    assert Enum.any?(actual, &(&1.id in body))
  end

  test "destination search checks editable access before the result limit" do
    owner = human_fixture().principal
    reader = human_fixture().principal
    owner_actor = Ankole.PrincipalsFixtures.actor_fixture(owner.uid)
    reader_actor = Ankole.PrincipalsFixtures.actor_fixture(reader.uid)

    {:ok, root} = Pages.create(owner_actor, %{private_owner_uid: owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, root.id, %{
        inherit_permissions: false,
        grants: [
          %{principal_uid: owner.uid, role: "manage"},
          %{principal_uid: reader.uid, role: "view"}
        ]
      })

    for _ <- 1..30 do
      {:ok, _} = Pages.create(owner_actor, %{parent_id: root.id, title: "Needle destination"})
    end

    {:ok, editable} =
      Pages.create(owner_actor, %{parent_id: root.id, title: "Needle destination available"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, editable.id, %{
        inherit_permissions: false,
        grants: [
          %{principal_uid: owner.uid, role: "manage"},
          %{principal_uid: reader.uid, role: "edit"}
        ]
      })

    for actions <- [~w(node_view node_manage), ~w(node_edit)] do
      {:ok, partial} =
        Pages.create(owner_actor, %{parent_id: root.id, title: "Needle destination"})

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(owner.uid, partial.id, %{
          inherit_permissions: false,
          grants: [
            %{principal_uid: owner.uid, role: "manage"},
            %{principal_uid: reader.uid, actions: actions}
          ]
        })
    end

    assert {:ok, %{pages: ordinary}} = Pages.search(reader_actor, "Needle destination")
    assert length(ordinary) == 30
    refute Enum.any?(ordinary, &(&1.id == editable.id))

    assert {:ok, %{pages: [found]}} =
             Pages.search(reader_actor, "Needle destination", %{required_action: "node_edit"})

    assert found.id == editable.id
    assert "node_edit" in found.actions
  end

  for scope <- ~w(recent favorites), hidden <- [:revoked, :deleted] do
    @scope scope
    @hidden hidden
    test "#{hidden} states do not consume the #{scope} entry limit" do
      owner = human_fixture().principal
      other = human_fixture().principal

      {:ok, older} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          title: "Older saved page"
        })

      {:ok, _} =
        Pages.state(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), older.id, %{
          favorite: true,
          visited: true
        })

      {:ok, latest} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
          title: "Latest saved page"
        })

      {:ok, state} =
        Pages.state(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), latest.id, %{
          favorite: true,
          visited: true
        })

      {:ok, _} =
        Pages.update(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), older.id, %{
          title: "Updated saved page",
          expected_title: older.title
        })

      {:ok, hidden_root} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
          title: "Hidden subtree"
        })

      insert_states(owner, other, hidden_root, 201, DateTime.add(state.visited_at, 60, :second))

      case @hidden do
        :revoked ->
          assert {:ok, _} =
                   Ankole.Pod.PagesFixtures.set_sharing(other.uid, hidden_root.id, %{
                     inherit_permissions: false
                   })

        :deleted ->
          assert {:ok, _} =
                   Pages.delete(
                     Ankole.PrincipalsFixtures.actor_fixture(other.uid),
                     hidden_root.id
                   )
      end

      assert {:ok, pages} =
               Pages.list(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{scope: @scope})

      assert Enum.map(pages, & &1.id) == [latest.id, older.id]
    end
  end

  test "version reconciliation returns only visible live Pages and tables" do
    owner = human_fixture().principal
    other = human_fixture().principal

    {:ok, visible} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: "base"})

    {:ok, hidden} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        type: "base",
        private_owner_uid: other.uid
      })

    {:ok, deleted} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{type: "base"})

    {:ok, visible_table} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), visible.id, %{
        name: "Visible"
      })

    {:ok, hidden_table} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(other.uid), hidden.id, %{
        name: "Hidden"
      })

    {:ok, deleted_table} =
      Bases.create_table(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), deleted.id, %{
        name: "Deleted"
      })

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), deleted.id)

    assert {:ok, %{pages: pages, tables: tables}} =
             Pages.reconcile_versions(
               Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
               [visible.id, hidden.id, deleted.id, visible.id, "invalid"],
               [visible_table.id, hidden_table.id, deleted_table.id, visible_table.id, "invalid"]
             )

    assert pages == [Map.take(visible, [:id, :revision, :object_id])]
    assert tables == [Map.take(visible_table, [:id, :data_version])]
  end

  test "other owners' recent trash cannot hide a person's older trash" do
    owner = human_fixture().principal
    other = human_fixture().principal

    {:ok, own} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        type: "file",
        private_owner_uid: owner.uid
      })

    {:ok, own} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), own.id)
    newer = DateTime.add(own.deleted_at, 60, :second)
    insert_trash(other, 201, %{private_owner_uid: other.uid}, newer)

    assert {:ok, pages} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{scope: "trash"})

    assert Enum.map(pages, & &1.id) == [own.id]
  end

  test "deleted descendants do not consume the Trash entry limit" do
    owner = human_fixture().principal

    {:ok, root} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{title: "Deleted folder"})

    {:ok, root} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), root.id)

    insert_trash(
      owner,
      201,
      %{parent_id: root.id, parent_anchor_id: root.id},
      DateTime.add(root.deleted_at, 60, :second)
    )

    assert {:ok, pages} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{scope: "trash"})

    assert Enum.map(pages, & &1.id) == [root.id]
  end

  test "Trash orders by deletion time and searches deleted titles" do
    owner = human_fixture().principal

    {:ok, first} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        type: "file",
        title: "First deleted"
      })

    {:ok, second} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        type: "file",
        title: "Second deleted"
      })

    {:ok, first} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), first.id)
    {:ok, second} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), second.id)

    Repo.update!(
      Ecto.Changeset.change(Repo.get_by!(Properties, id: first.id),
        updated_at: DateTime.add(second.updated_at, 60, :second)
      )
    )

    assert {:ok, pages} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{scope: "trash"})

    assert Enum.map(pages, & &1.id) == [second.id, first.id]

    assert {:ok, [found]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
               scope: "trash",
               query: "First deleted"
             })

    assert found.id == first.id
  end

  test "Trash search finds and restores an older page beyond the current result limit" do
    owner = human_fixture().principal
    actor = Ankole.PrincipalsFixtures.actor_fixture(owner.uid)
    {:ok, page} = Pages.create(actor, %{type: "file", title: "Older deleted notes"})
    {:ok, page} = Pages.delete(actor, page.id)
    insert_trash(owner, 201, %{}, DateTime.add(page.deleted_at, 60, :second))

    assert {:ok, current} = Pages.list(actor, %{scope: "trash"})
    assert length(current) == 200
    refute Enum.any?(current, &(&1.id == page.id))
    assert {:ok, [found]} = Pages.list(actor, %{scope: "trash", query: "Older deleted notes"})
    assert found.id == page.id
    assert {:ok, _} = Pages.restore(actor, found.id)
    assert {:ok, %{page: %{deleted_at: nil}}} = Pages.get(actor, page.id)
  end

  defp insert_states(owner, creator, parent, count, time) do
    pages =
      for index <- 1..count do
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: owner.tenant_id,
          type: :file,
          title: "Newer page #{index}",
          position: Integer.to_string(index),
          parent_id: parent.id,
          acl_anchor_id: parent.acl_anchor_id,
          created_by: Ankole.ActorRef.from_principal(creator),
          created_at: time,
          updated_at: time
        }
      end

    insert_pages(pages, count)

    states =
      Enum.map(pages, fn page ->
        %{
          tenant_id: owner.tenant_id,
          principal_uid: owner.uid,
          page_id: page.id,
          favorited_at: time,
          visited_at: time
        }
      end)

    assert {^count, nil} = Repo.insert_all(PageUserState, states)
  end

  defp insert_trash(owner, count, attrs, time) do
    {:ok, root} =
      if uid = attrs[:private_owner_uid],
        do: Ankole.Files.Nodes.private_root(uid),
        else: Ankole.Files.Nodes.public_root()

    attrs = Map.delete(attrs, :private_owner_uid)

    rows =
      for index <- 1..count do
        id = Ankole.Ecto.UUIDv7.autogenerate()

        Map.merge(
          %{
            id: id,
            tenant_id: owner.tenant_id,
            type: :file,
            title: "Deleted #{index}",
            position: Integer.to_string(index),
            parent_id: root.id,
            parent_anchor_id: root.id,
            acl_anchor_id: id,
            created_by: Ankole.ActorRef.from_principal(owner),
            created_at: time,
            updated_at: time,
            deleted_at: time
          },
          attrs
        )
      end

    insert_pages(rows, count)
  end

  defp insert_pages(rows, count) do
    nodes =
      Enum.map(rows, fn row ->
        row
        |> Map.drop([:type, :title, :position])
        |> Map.put(:kind, row.type)
        |> Map.put(:name, row.title)
      end)

    properties =
      Enum.map(
        rows,
        &Map.take(&1, [:id, :tenant_id, :title, :position, :created_at, :updated_at])
      )

    assert {^count, nil} = Repo.insert_all(Node, nodes)
    assert {^count, nil} = Repo.insert_all(Properties, properties)
  end
end
