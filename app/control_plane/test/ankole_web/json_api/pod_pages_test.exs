defmodule AnkoleWeb.JSONAPI.PodPagesTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  test "a stale title is rejected without overwriting the winner", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Original"})

    {:ok, _} =
      Ankole.Pod.Pages.update(actor, page.id, %{
        title: "Their title",
        expected_title: "Original"
      })

    response =
      owner
      |> recycle_json()
      |> patch("/api/v2/pod/pages/#{page.id}", %{
        data: %{title: "My draft", expected_title: "Original"}
      })
      |> json_response(409)

    assert [%{"code" => "title_conflict", "meta" => %{"details" => %{"title" => "Their title"}}}] =
             response["errors"]

    assert {:ok, %{title: "Their title"}} = Ankole.Pod.Pages.fetch(page.id)

    accepted =
      owner
      |> recycle_json()
      |> patch("/api/v2/pod/pages/#{page.id}", %{
        data: %{title: "My draft", expected_title: "Their title"}
      })
      |> json_response(200)

    assert accepted["page"]["title"] == "My draft"
  end

  test "title updates require a base while other metadata updates do not", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Current title"})

    for data <- [%{title: "Overwrite"}, %{title: "Overwrite", expected_title: nil}] do
      response =
        owner
        |> recycle_json()
        |> patch("/api/v2/pod/pages/#{page.id}", %{data: data})
        |> json_response(409)

      assert [
               %{
                 "code" => "title_conflict",
                 "meta" => %{"details" => %{"title" => "Current title"}}
               }
             ] =
               response["errors"]
    end

    assert {:ok, %{title: "Current title"}} = Ankole.Pod.Pages.fetch(page.id)

    metadata =
      owner
      |> recycle_json()
      |> patch("/api/v2/pod/pages/#{page.id}", %{
        data: %{icon: "📄", children_view: %{collapsed: true}}
      })
      |> json_response(200)

    assert metadata["page"]["title"] == "Current title"
    assert metadata["page"]["icon"] == "📄"
    assert metadata["page"]["children_view"]["collapsed"]
  end

  test "embed deletion accepts one batch and trashes every direct child", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, parent} = Ankole.Pod.Pages.create(actor, %{})
    {:ok, first} = Ankole.Pod.Pages.create(actor, %{parent_id: parent.id})
    {:ok, second} = Ankole.Pod.Pages.create(actor, %{parent_id: parent.id})

    response =
      owner
      |> recycle_json()
      |> post("/api/v2/pod/pages/#{parent.id}/embeds/delete", %{
        data: %{refs: [first.id, second.id]}
      })

    assert json_response(response, 201) == true

    for id <- [first.id, second.id] do
      assert {:ok, %{deleted_at: %DateTime{}}} = Ankole.Pod.Pages.fetch(id)
    end
  end

  test "deleting a Page reports how many live descendants moved to Trash with it", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, parent} = Ankole.Pod.Pages.create(actor, %{title: "Parent"})
    {:ok, child} = Ankole.Pod.Pages.create(actor, %{parent_id: parent.id})
    {:ok, _} = Ankole.Pod.Pages.create(actor, %{parent_id: child.id})

    response =
      owner
      |> recycle_json()
      |> delete("/api/v2/pod/pages/#{parent.id}")
      |> json_response(200)

    assert response["descendant_count"] == 2
    assert response["page"]["id"] == parent.id
  end

  test "Trash reads return authorized rows without recalculating root creation permissions", %{
    conn: conn
  } do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Trash row"})
    {:ok, _} = Ankole.Pod.Pages.delete(actor, page.id)
    function = {Ankole.Kernel, :authz_evaluate_drive_context, 1}
    :erlang.trace_pattern(function, true, [:call_count])

    try do
      response =
        owner
        |> recycle_json()
        |> get("/api/v2/pod/pages", %{scope: "trash"})
        |> json_response(200)

      assert Enum.sort(Map.keys(response)) == ["pages", "trash_retention_days"]
      assert response["trash_retention_days"] == 30
      assert [%{"id" => id, "actions" => actions}] = response["pages"]
      assert id == page.id
      assert "node_manage" in actions
      assert :erlang.trace_info(function, :call_count) == {:call_count, 1}
    after
      :erlang.trace_pattern(function, false, [:call_count])
    end
  end

  test "children and empty search accept omitted optional arguments", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)

    {:ok, root} =
      Ankole.Pod.Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{title: "Root"})

    {:ok, private} =
      Ankole.Pod.Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        private_owner_uid: uid,
        title: "Private"
      })

    {:ok, child} =
      Ankole.Pod.Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        parent_id: private.id,
        title: "Child"
      })

    root_id = root.id
    private_id = private.id
    child_id = child.id

    assert %{
             "pages" => [%{"id" => ^root_id, "actions" => actions, "has_children" => false}],
             "next_cursor" => nil,
             "can_create_private" => true,
             "can_create_space" => true
           } = owner |> recycle_json() |> get("/api/v2/pod/pages/children") |> json_response(200)

    assert actions == ~w(node_view node_contribute node_edit node_manage node_comment)

    assert %{"pages" => [%{"id" => ^private_id, "has_children" => true}], "next_cursor" => nil} =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages/children", %{scope: "private"})
             |> json_response(200)

    assert %{"pages" => [%{"id" => ^child_id, "has_children" => false}], "next_cursor" => nil} =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages/children", %{parent_id: private.id, scope: "private"})
             |> json_response(200)

    assert %{"pages" => pages, "can_create_private" => true, "can_create_space" => true} =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages/search", %{query: ""})
             |> json_response(200)

    assert MapSet.new(pages, & &1["id"]) == MapSet.new([root.id, private.id, child.id])
  end

  test "root and child directories paginate equal positions and reject invalid keysets", %{
    conn: conn
  } do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, parent} = Ankole.Pod.Pages.create(actor, %{title: "Parent"})

    for {location, query} <- [
          {%{private_owner_uid: uid}, %{scope: "private"}},
          {%{parent_id: parent.id}, %{parent_id: parent.id}}
        ] do
      pages =
        for number <- 1..5 do
          {:ok, page} =
            Ankole.Pod.Pages.create(
              actor,
              Map.merge(location, %{title: "Page #{number}", position: "A"})
            )

          page
        end

      first =
        owner
        |> recycle_json()
        |> get("/api/v2/pod/pages/children", Map.put(query, :limit, 2))
        |> json_response(200)

      second =
        owner
        |> recycle_json()
        |> get(
          "/api/v2/pod/pages/children",
          Map.merge(query, %{limit: 2, cursor: first["next_cursor"]})
        )
        |> json_response(200)

      last =
        owner
        |> recycle_json()
        |> get(
          "/api/v2/pod/pages/children",
          Map.merge(query, %{limit: 2, cursor: second["next_cursor"]})
        )
        |> json_response(200)

      assert Enum.map([first, second, last], &length(&1["pages"])) == [2, 2, 1]
      assert is_binary(first["next_cursor"])
      assert is_binary(second["next_cursor"])
      assert is_nil(last["next_cursor"])

      assert Enum.map(first["pages"] ++ second["pages"] ++ last["pages"], & &1["id"]) ==
               Enum.sort(Enum.map(pages, & &1.id))

      assert %{"errors" => [%{"code" => "invalid_keyset"}]} =
               owner
               |> recycle_json()
               |> get("/api/v2/pod/pages/children", Map.put(query, :cursor, "invalid"))
               |> json_response(400)
    end
  end

  test "a human edits their private page while another human cannot read or move it", %{
    conn: conn
  } do
    {owner, uid} = console_conn_with_principal(conn)
    created = send_json(owner, :post, "/pages", %{title: "Private draft", private_owner_uid: uid})
    assert %{"page" => %{"id" => id, "revision" => 0}} = json_response(created, 201)

    saved =
      send_json(owner, :put, "/pages/#{id}/content", %{
        base_revision: 0,
        xml: "<page><p>Saved text</p></page>"
      })

    assert %{"page" => %{"revision" => 1}, "content" => %{"content" => xml}} =
             json_response(saved, 200)

    assert xml =~ "Saved text"

    stale =
      send_json(owner, :put, "/pages/#{id}/content", %{
        base_revision: 0,
        xml: "<page><p>Stale text</p></page>"
      })

    assert %{
             "errors" => [
               %{"code" => "revision_conflict", "meta" => %{"details" => %{"revision" => 1}}}
             ]
           } = json_response(stale, 409)

    assert %{"pages" => [%{"id" => ^id, "title" => "Private draft"}]} =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages", %{scope: "private"})
             |> json_response(200)

    assert %{"pages" => [%{"id" => ^id}]} =
             owner |> recycle_json() |> get("/api/v2/pod/pages") |> json_response(200)

    read = owner |> recycle_json() |> get("/api/v2/pod/pages/#{id}")

    assert %{"content" => %{"content" => ^xml}, "role" => "manage", "actions" => actions} =
             json_response(read, 200)

    assert actions == ~w(node_view node_contribute node_edit node_manage node_comment)

    human = Ankole.PrincipalsFixtures.human_fixture().principal

    other = conn |> Plug.Test.init_test_session(%{}) |> AnkoleWeb.Session.ensure_browser()

    {:ok, %{browser: browser, authentication: auth}} =
      Ankole.BrowserSessions.authenticate(AnkoleWeb.Session.browser_reference(other), %{
        "principal_uid" => human.uid,
        "access_version" => human.access_version,
        "provider_id" => "lark-main",
        "external_id" => "other"
      })

    other = AnkoleWeb.Session.put_authentication(other, browser, auth)

    other = other |> with_console_csrf() |> get("/api/v2/browser/session")
    denied = other |> recycle_json() |> get("/api/v2/pod/pages/#{id}")
    assert %{"errors" => [%{"code" => "forbidden"}]} = json_response(denied, 403)

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             other
             |> send_json(:post, "/pages/#{id}/move", %{parent_id: nil})
             |> json_response(403)

    assert {:ok, private_root} = Ankole.Files.private_root(uid)
    private_root_id = private_root.id

    assert {:ok, %{page: %{parent_id: ^private_root_id}, content: %{content: ^xml}}} =
             Ankole.Pod.Pages.get(Ankole.PrincipalsFixtures.actor_fixture(uid), id)
  end

  test "the sharing API preserves exact userset actions on a settings round trip", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    human = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, source} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})
    {:ok, target} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(uid, source.id, %{
        grants: [%{principal_uid: human.uid, role: "view"}]
      })

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        source_node_id: source.id,
        source_action: "node_view",
        resource_pattern: "drive:**:#{target.id}:**",
        target_node_id: target.id,
        target_scope: "container",
        action: "node_contribute"
      })

    sharing =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{target.id}/sharing")
      |> json_response(200)

    assert [%{"actions" => ["node_contribute"]}] = sharing["grants"]

    grants =
      Enum.map(sharing["grants"], fn grant ->
        Map.take(
          grant,
          ~w(principal_uid group_id source_node_id source_action target_scope condition actions)
        )
      end)

    assert %{"page" => %{"id" => id}} =
             owner
             |> send_json(:put, "/pages/#{target.id}/sharing", %{
               sharing_version: sharing["sharing_version"],
               inherit_permissions: sharing["inherit_permissions"],
               grants: grants
             })
             |> json_response(200)

    assert id == target.id
    reader = Ankole.PrincipalsFixtures.actor_fixture(human.uid)
    assert {:error, :forbidden} = Ankole.Pod.Pages.authorize(reader, target.id, "node_view")
    assert {:ok, _} = Ankole.Pod.Pages.authorize(reader, target.id, "node_contribute")
  end

  test "sharing accepts one rule meaning and rejects conflicting role and actions", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    human = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})

    for rule <- [
          %{role: "view"},
          %{actions: ["node_contribute"]},
          %{role: "contribute", actions: ["node_contribute", "node_view", "node_comment"]}
        ] do
      {:ok, sharing} = Ankole.Pod.Pages.sharing(actor, page.id)

      owner
      |> send_json(:put, "/pages/#{page.id}/sharing", %{
        sharing_version: sharing.sharing_version,
        grants: [Map.put(rule, :principal_uid, human.uid)]
      })
      |> json_response(200)
    end

    {:ok, sharing} = Ankole.Pod.Pages.sharing(actor, page.id)

    owner
    |> send_json(:put, "/pages/#{page.id}/sharing", %{
      sharing_version: sharing.sharing_version,
      grants: [%{principal_uid: human.uid, role: "view", actions: ["node_contribute"]}]
    })
    |> json_response(422)

    assert {:ok, same} = Ankole.Pod.Pages.sharing(actor, page.id)
    assert same.sharing_version == sharing.sharing_version
  end

  test "AshJsonApi derives concrete page identifiers and timestamps for all page results" do
    spec = AnkoleWeb.JSONAPI.PodRouter.spec() |> OpenApiSpex.OpenApi.to_map()
    page = spec["components"]["schemas"]["pod_page-type"]
    assert "id" in page["required"]
    assert page["properties"]["id"]["type"] == "string"
    assert page["properties"]["created_at"]["format"] == "date-time"

    scope =
      Enum.find(spec["paths"]["/api/v2/pod/pages"]["get"]["parameters"], &(&1["name"] == "scope"))

    refute scope["required"]
  end

  test "move undo restores the last loaded item ahead of the next directory page", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, source} = Ankole.Pod.Pages.create(actor, %{title: "Source"})
    {:ok, destination} = Ankole.Pod.Pages.create(actor, %{title: "Destination"})

    children =
      for number <- 1..202 do
        {:ok, child} =
          Ankole.Pod.Pages.create(actor, %{
            parent_id: source.id,
            title: "Child #{String.pad_leading(to_string(number), 3, "0")}"
          })

        child
      end

    first =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/children", %{parent_id: source.id})
      |> json_response(200)

    assert length(first["pages"]) == 200
    assert is_binary(first["next_cursor"])
    moving = Enum.at(children, 199)
    successor = Enum.at(children, 200)

    moved =
      owner
      |> send_json(:post, "/pages/#{moving.id}/move", %{parent_id: destination.id})
      |> json_response(201)

    assert moved["page"]["parent_id"] == destination.id
    assert moved["undo"]["parent_id"] == source.id
    assert moved["undo"]["before_id"] == successor.id

    restored =
      owner
      |> send_json(:post, "/pages/#{moving.id}/move", moved["undo"])
      |> json_response(201)

    assert restored["page"]["parent_id"] == source.id

    first_again =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/children", %{parent_id: source.id})
      |> json_response(200)

    assert Enum.map(first_again["pages"], & &1["id"]) ==
             Enum.map(Enum.take(children, 200), & &1.id)

    remaining =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/children", %{
        parent_id: source.id,
        cursor: first_again["next_cursor"]
      })
      |> json_response(200)

    assert Enum.map(remaining["pages"], & &1["id"]) ==
             Enum.map(Enum.drop(children, 200), & &1.id)
  end

  test "move undo returns real neighbors without a loaded directory", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, source} = Ankole.Pod.Pages.create(actor, %{title: "Source"})
    {:ok, destination} = Ankole.Pod.Pages.create(actor, %{title: "Destination"})
    {:ok, first} = Ankole.Pod.Pages.create(actor, %{parent_id: source.id, title: "First"})
    {:ok, last} = Ankole.Pod.Pages.create(actor, %{parent_id: source.id, title: "Last"})

    moved =
      owner
      |> send_json(:post, "/pages/#{last.id}/move", %{parent_id: destination.id})
      |> json_response(201)

    assert moved["undo"]["after_id"] == first.id

    owner
    |> send_json(:post, "/pages/#{last.id}/move", moved["undo"])
    |> json_response(201)

    assert {:ok, %{pages: pages}} = Ankole.Pod.Pages.list_children(actor, source.id)
    assert Enum.map(pages, & &1.id) == [first.id, last.id]

    {:ok, only} = Ankole.Pod.Pages.create(actor, %{parent_id: destination.id, title: "Only"})

    moved_only =
      owner
      |> send_json(:post, "/pages/#{only.id}/move", %{parent_id: source.id})
      |> json_response(201)

    assert moved_only["undo"]["parent_id"] == destination.id
    assert is_nil(moved_only["undo"]["before_id"])
    assert is_nil(moved_only["undo"]["after_id"])

    owner
    |> send_json(:post, "/pages/#{only.id}/move", moved_only["undo"])
    |> json_response(201)

    assert {:ok, %{pages: [restored]}} = Ankole.Pod.Pages.list_children(actor, destination.id)
    assert restored.id == only.id
  end

  test "move search excludes the full subtree before the result limit", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, source} = Ankole.Pod.Pages.create(actor, %{title: "needle"})
    {:ok, middle} = Ankole.Pod.Pages.create(actor, %{parent_id: source.id, title: "Middle"})

    for _ <- 1..31 do
      {:ok, _} = Ankole.Pod.Pages.create(actor, %{parent_id: middle.id, title: "needle"})
    end

    {:ok, destination} = Ankole.Pod.Pages.create(actor, %{title: "needle outside the subtree"})
    other = Ankole.PrincipalsFixtures.human_fixture().principal

    {:ok, _} =
      Ankole.Pod.Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        title: "needle private",
        private_owner_uid: other.uid
      })

    ordinary =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/search", %{query: "needle"})
      |> json_response(200)

    assert length(ordinary["pages"]) == 30
    refute Enum.any?(ordinary["pages"], &(&1["id"] == destination.id))

    candidates =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/search", %{
        query: "needle",
        exclude_subtree_of: source.id,
        required_action: "node_edit"
      })
      |> json_response(200)

    assert Enum.map(candidates["pages"], & &1["id"]) == [destination.id]
  end

  test "recent scope exposes each page's visited_at timestamp in visit order", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, first} = Ankole.Pod.Pages.create(actor, %{title: "First page"})
    {:ok, second} = Ankole.Pod.Pages.create(actor, %{title: "Second page"})

    assert %{"user_state" => %{"visited_at" => first_visited}} =
             owner
             |> send_json(:put, "/pages/#{first.id}/user-state", %{visited: true})
             |> json_response(200)

    Process.sleep(5)

    assert %{"user_state" => %{"visited_at" => second_visited}} =
             owner
             |> send_json(:put, "/pages/#{second.id}/user-state", %{visited: true})
             |> json_response(200)

    assert %{
             "pages" => [
               %{"id" => second_id, "visited_at" => ^second_visited},
               %{"id" => first_id, "visited_at" => ^first_visited}
             ]
           } =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages", %{scope: "recent"})
             |> json_response(200)

    assert [second_id, first_id] == [second.id, first.id]
  end

  test "pod pages API exposes child_count, persists children_view for editors, and serves subpage details",
       %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)

    {:ok, parent} = Ankole.Pod.Pages.create(actor, %{title: "Parent Doc"})
    {:ok, child} = Ankole.Pod.Pages.create(actor, %{parent_id: parent.id, title: "Child Doc"})

    {:ok, _} =
      Ankole.Pod.Documents.write(
        actor,
        child.id,
        0,
        "<page><p>Preview body from child document.</p></page>"
      )

    assert %{"child_count" => 1, "page" => %{"children_view" => %{}}} =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages/#{parent.id}")
             |> json_response(200)

    assert %{
             "page" => %{
               "children_view" => %{
                 "collapsed" => true,
                 "view" => "grid",
                 "visible_fields" => ["created_by", "created_at"]
               }
             }
           } =
             owner
             |> send_json(:patch, "/pages/#{parent.id}", %{
               children_view: %{
                 collapsed: true,
                 view: "grid",
                 visible_fields: ["created_by", "created_at"]
               }
             })
             |> json_response(200)

    assert %{"errors" => [%{"status" => "400"}]} =
             owner
             |> send_json(:patch, "/pages/#{parent.id}", %{
               children_view: %{field_order: ["created_by"]}
             })
             |> json_response(400)

    assert %{
             "pages" => [
               %{
                 "id" => child_id,
                 "creator_name" => creator_name,
                 "excerpt" => "Preview body from child document.",
                 "created_at" => created_at,
                 "updated_at" => updated_at
               }
             ]
           } =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages/children", %{parent_id: parent.id, details: true})
             |> json_response(200)

    assert child_id == child.id
    assert is_binary(creator_name) and creator_name != ""
    assert is_binary(created_at) and is_binary(updated_at)
  end

  test "sharing read exposes a read-only collaborator overview to viewers while redacting subjects, advanced rules, and unshared guest peers",
       %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    viewer = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Space Viewer"}).principal
    outsider = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Outsider"}).principal

    guest =
      Ankole.PrincipalsFixtures.human_fixture(%{membership: :guest, display_name: "Guest Reader"}).principal

    {:ok, parent} = Ankole.Pod.Pages.create(actor, %{title: "Space Parent"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(uid, parent.id, %{
        grants: [%{principal_uid: uid, role: "manage"}]
      })

    {:ok, child} = Ankole.Pod.Pages.create(actor, %{parent_id: parent.id, title: "Shared Child"})

    {:ok, secret} =
      Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid, title: "Secret Source"})

    {:ok, %{id: group_id}} = Ankole.Files.Access.space_group()

    {:ok, :ok} =
      Ankole.Repo.transact_top_level(fn ->
        {:ok, Ankole.Files.Access.put_role(%{group_id: group_id}, "drive:space:**", "view")}
      end)

    {:ok, _} =
      Ankole.Pod.Pages.update_sharing(actor, child.id, %{
        upserts: [
          %{principal_uid: guest.uid, role: "view", target_scope: "container"},
          %{principal_uid: outsider.uid, role: "edit", target_scope: "self"}
        ]
      })

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        source_node_id: secret.id,
        source_action: "node_view",
        resource_pattern: "drive:**:#{child.id}:node",
        target_node_id: child.id,
        target_scope: "self",
        action: "node_view"
      })

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: viewer.uid,
        resource_pattern: "drive:**:#{child.id}:node",
        target_node_id: child.id,
        target_scope: "self",
        action: "node_edit",
        condition: "context.request.ip == \"10.0.0.1\""
      })

    partial = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Partial Action"}).principal

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: partial.uid,
        resource_pattern: "drive:**:#{child.id}:node",
        target_node_id: child.id,
        target_scope: "self",
        action: "node_contribute"
      })

    manager_sharing =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{child.id}/sharing")
      |> json_response(200)

    assert manager_sharing["can_manage"] == true
    assert manager_sharing["scope_kind"] == "space"
    assert manager_sharing["space_role"] == "view"
    assert manager_sharing["subjects"] != []

    assert Enum.any?(
             manager_sharing["grants"],
             &(&1["principal_uid"] == outsider.uid and &1["rule_kind"] == "role")
           )

    assert Enum.any?(
             manager_sharing["grants"],
             &(&1["kind"] == "userset" and &1["rule_kind"] == "advanced")
           )

    assert Enum.any?(
             manager_sharing["grants"],
             &(&1["condition"] != "true" and &1["rule_kind"] == "advanced")
           )

    assert Enum.any?(
             manager_sharing["grants"],
             &(&1["principal_uid"] == partial.uid and &1["rule_kind"] == "advanced")
           )

    viewer_conn = session_conn_for(conn, viewer, "space-viewer")

    viewer_sharing =
      viewer_conn
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{child.id}/sharing")
      |> json_response(200)

    assert viewer_sharing["can_manage"] == false
    assert viewer_sharing["subjects"] == []
    assert Enum.any?(viewer_sharing["inherited"], &(&1["origin"] == "space_default"))

    assert Enum.any?(
             viewer_sharing["inherited"],
             &(&1["origin"] == "ancestor" and &1["principal_uid"] == uid)
           )

    assert Enum.all?(viewer_sharing["grants"], &(&1["rule_kind"] == "role"))
    refute Enum.any?(viewer_sharing["grants"], &(&1["kind"] == "userset"))
    refute Enum.any?(viewer_sharing["grants"], &(&1["condition"] != "true"))
    refute Enum.any?(viewer_sharing["grants"], &(&1["principal_uid"] == partial.uid))

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             viewer_conn
             |> send_json(:patch, "/pages/#{child.id}/sharing", %{inherit_permissions: false})
             |> json_response(403)

    guest_conn = session_conn_for(conn, guest, "guest-reader")

    guest_sharing =
      guest_conn
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{child.id}/sharing")
      |> json_response(200)

    assert guest_sharing["can_manage"] == false
    assert guest_sharing["subjects"] == []

    refute Enum.any?(
             guest_sharing["inherited"],
             &(&1["origin"] in ["space_admin", "space_default", "space_agent"])
           )

    assert Enum.map(guest_sharing["grants"], & &1["principal_uid"]) == [guest.uid, outsider.uid]
  end

  test "granular PATCH /pages/:id/sharing merges concurrent updates and rejects guest grants on Private subtrees",
       %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    co_manager = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Co Manager"}).principal
    alice = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Alice"}).principal
    bob = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Bob"}).principal
    carol = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Carol"}).principal

    guest =
      Ankole.PrincipalsFixtures.human_fixture(%{membership: :guest, display_name: "Ext Guest"}).principal

    {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Concurrent Doc"})
    co_conn = session_conn_for(conn, co_manager, "co-manager")

    assert %{"grants" => initial_grants} =
             owner
             |> send_json(:patch, "/pages/#{page.id}/sharing", %{
               upserts: [
                 %{principal_uid: alice.uid, role: "edit", target_scope: "container"},
                 %{principal_uid: bob.uid, role: "view", target_scope: "self"}
               ]
             })
             |> json_response(200)

    assert Enum.any?(
             initial_grants,
             &(&1["principal_uid"] == alice.uid and &1["role"] == "edit" and
                 &1["target_scope"] == "container")
           )

    assert Enum.any?(
             initial_grants,
             &(&1["principal_uid"] == bob.uid and &1["role"] == "view" and
                 &1["target_scope"] == "self")
           )

    assert %{"grants" => co_grants} =
             co_conn
             |> send_json(:patch, "/pages/#{page.id}/sharing", %{
               upserts: [
                 %{principal_uid: carol.uid, role: "contribute", target_scope: "container"}
               ]
             })
             |> json_response(200)

    assert Enum.any?(co_grants, &(&1["principal_uid"] == carol.uid))

    assert %{"inherit_permissions" => false, "grants" => merged_grants} =
             owner
             |> send_json(:patch, "/pages/#{page.id}/sharing", %{inherit_permissions: false})
             |> json_response(200)

    granted_uids = MapSet.new(merged_grants, & &1["principal_uid"])
    assert MapSet.subset?(MapSet.new([uid, alice.uid, bob.uid, carol.uid]), granted_uids)

    assert %{"grants" => after_remove} =
             owner
             |> send_json(:patch, "/pages/#{page.id}/sharing", %{
               removes: [%{principal_uid: bob.uid, target_scope: "self"}]
             })
             |> json_response(200)

    refute Enum.any?(after_remove, &(&1["principal_uid"] == bob.uid))
    assert Enum.any?(after_remove, &(&1["principal_uid"] == alice.uid))
    assert Enum.any?(after_remove, &(&1["principal_uid"] == carol.uid))

    {:ok, private_root} =
      Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid, title: "Private Root"})

    {:ok, private_child} =
      Ankole.Pod.Pages.create(actor, %{parent_id: private_root.id, title: "Private Child"})

    for target_id <- [private_root.id, private_child.id] do
      assert %{"sharing_version" => version, "grants" => before_grants} =
               owner
               |> recycle_json()
               |> get("/api/v2/pod/pages/#{target_id}/sharing")
               |> json_response(200)

      assert %{"errors" => [%{"code" => "guest_forbidden_in_private"}]} =
               owner
               |> send_json(:patch, "/pages/#{target_id}/sharing", %{
                 upserts: [%{principal_uid: guest.uid, role: "view", target_scope: "container"}]
               })
               |> json_response(422)

      assert %{"errors" => [%{"code" => "guest_forbidden_in_private"}]} =
               owner
               |> send_json(:put, "/pages/#{target_id}/sharing", %{
                 sharing_version: version,
                 grants: [
                   %{principal_uid: uid, role: "manage"},
                   %{principal_uid: guest.uid, role: "view", target_scope: "container"}
                 ]
               })
               |> json_response(422)

      assert %{"grants" => ^before_grants} =
               owner
               |> recycle_json()
               |> get("/api/v2/pod/pages/#{target_id}/sharing")
               |> json_response(200)
    end

    guest_manager =
      Ankole.PrincipalsFixtures.human_fixture(%{
        membership: :guest,
        display_name: "Guest Manager"
      }).principal

    unseen_peer =
      Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Unseen Tenant Member"}).principal

    {:ok, guest_managed} = Ankole.Pod.Pages.create(actor, %{title: "Guest Managed Space Page"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(uid, guest_managed.id, %{
        grants: [
          %{principal_uid: uid, role: "manage"},
          %{principal_uid: guest_manager.uid, role: "manage"}
        ]
      })

    guest_manager_conn = session_conn_for(conn, guest_manager, "guest-manager")

    assert %{"sharing_version" => guest_version} =
             guest_manager_conn
             |> recycle_json()
             |> get("/api/v2/pod/pages/#{guest_managed.id}/sharing")
             |> json_response(200)

    assert %{"errors" => [%{"code" => "invalid_grants"}]} =
             guest_manager_conn
             |> send_json(:patch, "/pages/#{guest_managed.id}/sharing", %{
               upserts: [%{principal_uid: unseen_peer.uid, role: "view"}]
             })
             |> json_response(422)

    assert %{"errors" => [%{"code" => "invalid_grants"}]} =
             guest_manager_conn
             |> send_json(:put, "/pages/#{guest_managed.id}/sharing", %{
               sharing_version: guest_version,
               grants: [
                 %{principal_uid: uid, role: "manage"},
                 %{principal_uid: guest_manager.uid, role: "manage"},
                 %{principal_uid: unseen_peer.uid, role: "view"}
               ]
             })
             |> json_response(422)

    {:ok, movable} = Ankole.Pod.Pages.create(actor, %{title: "Movable Space Page"})

    assert %{"scope_kind" => "space"} =
             owner
             |> send_json(:patch, "/pages/#{movable.id}/sharing", %{
               upserts: [%{principal_uid: guest.uid, role: "view", target_scope: "container"}]
             })
             |> json_response(200)

    assert {:ok, _} = Ankole.Pod.Pages.move(actor, movable.id, %{parent_id: private_root.id})

    moved_sharing =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{movable.id}/sharing")
      |> json_response(200)

    assert moved_sharing["scope_kind"] == "private"

    assert %{"inactive_in_private" => true} =
             Enum.find(moved_sharing["grants"], &(&1["principal_uid"] == guest.uid))

    assert %{"page" => %{"id" => moved_id}} =
             owner
             |> send_json(:put, "/pages/#{movable.id}/sharing", %{
               sharing_version: moved_sharing["sharing_version"],
               inherit_permissions: moved_sharing["inherit_permissions"],
               grants: moved_sharing["grants"]
             })
             |> json_response(200)

    assert moved_id == movable.id

    assert {:error, :forbidden} =
             Ankole.Pod.Pages.get(Ankole.PrincipalsFixtures.actor_fixture(guest), movable.id)

    assert %{"errors" => [%{"code" => "guest_forbidden_in_private"}]} =
             owner
             |> send_json(:patch, "/pages/#{movable.id}/sharing", %{
               upserts: [%{principal_uid: guest.uid, role: "view", target_scope: "container"}]
             })
             |> json_response(422)

    refreshed_moved =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{movable.id}/sharing")
      |> json_response(200)

    assert %{"errors" => [%{"code" => "guest_forbidden_in_private"}]} =
             owner
             |> send_json(:put, "/pages/#{movable.id}/sharing", %{
               sharing_version: refreshed_moved["sharing_version"],
               inherit_permissions: refreshed_moved["inherit_permissions"],
               grants:
                 Enum.map(refreshed_moved["grants"], fn row ->
                   if row["principal_uid"] == guest.uid,
                     do: Map.put(row, "role", "edit") |> Map.delete("actions"),
                     else: row
                 end)
             })
             |> json_response(422)
  end

  test "sharing diff replacement, scope deduplication, file/applet self validation, manager retention, and guest PII redaction",
       %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)

    alice =
      Ankole.PrincipalsFixtures.human_fixture(%{
        display_name: "Alice Member",
        email: "alice.member@example.com"
      }).principal

    departed =
      Ankole.PrincipalsFixtures.human_fixture(%{
        display_name: "Departed Editor",
        email: "departed.editor@example.com"
      }).principal

    legacy_guest =
      Ankole.PrincipalsFixtures.human_fixture(%{
        membership: :guest,
        display_name: "Legacy Partner",
        email: "legacy.partner@external.example"
      }).principal

    viewer =
      Ankole.PrincipalsFixtures.human_fixture(%{
        display_name: "Read Only Viewer",
        email: "viewer@example.com"
      }).principal

    {:ok, doc} = Ankole.Pod.Pages.create(actor, %{title: "Diff Managed Doc"})

    assert %{"grants" => _} =
             owner
             |> send_json(:patch, "/pages/#{doc.id}/sharing", %{
               upserts: [
                 %{principal_uid: alice.uid, role: "view", target_scope: "container"},
                 %{principal_uid: departed.uid, role: "edit", target_scope: "container"},
                 %{principal_uid: legacy_guest.uid, role: "edit", target_scope: "self"}
               ]
             })
             |> json_response(200)

    # Guest caller receives nil subtitle on sharing grants and inherited rows.
    guest_conn = session_conn_for(conn, legacy_guest, "legacy-partner")

    guest_sharing =
      guest_conn
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{doc.id}/sharing")
      |> json_response(200)

    assert Enum.all?(guest_sharing["grants"], &is_nil(&1["subtitle"]))
    assert Enum.all?(guest_sharing["inherited"], &is_nil(&1["subtitle"]))

    # Switching target_scope in PATCH upserts replaces the opposite scope rather than duplicating.
    assert %{"grants" => scoped_grants} =
             owner
             |> send_json(:patch, "/pages/#{doc.id}/sharing", %{
               upserts: [%{principal_uid: alice.uid, role: "edit", target_scope: "self"}]
             })
             |> json_response(200)

    alice_grants = Enum.filter(scoped_grants, &(&1["principal_uid"] == alice.uid))
    assert [%{"role" => "edit", "target_scope" => "self"}] = alice_grants

    alice_grant_ids_before =
      Ankole.Files.Access.page_grants(doc.id)
      |> Enum.filter(&(&1.principal_uid == alice.uid))
      |> MapSet.new(& &1.id)

    assert {:ok, _} = Ankole.PrincipalsFixtures.disable_principal_fixture(departed.uid)

    # Custom unconditional grant conferring node_view appears in read-only overview, while disabled principals are omitted.
    custom_editor =
      Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Custom View+Edit"}).principal

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: custom_editor.uid,
        resource_pattern: "drive:**:#{doc.id}:node",
        target_node_id: doc.id,
        target_scope: "self",
        action: "node_view"
      })

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: custom_editor.uid,
        resource_pattern: "drive:**:#{doc.id}:node",
        target_node_id: doc.id,
        target_scope: "self",
        action: "node_edit"
      })

    {:ok, %{id: all_humans_id}} = Ankole.Files.Access.space_group()

    {:ok, :ok} =
      Ankole.Repo.transact_top_level(fn ->
        {:ok, Ankole.Files.Access.put_role(%{group_id: all_humans_id}, "drive:space:**", "view")}
      end)

    viewer_conn = session_conn_for(conn, viewer, "readonly-viewer")

    readonly_sharing =
      viewer_conn
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{doc.id}/sharing")
      |> json_response(200)

    refute Enum.any?(readonly_sharing["grants"], &(&1["principal_uid"] == departed.uid))

    assert Enum.any?(
             readonly_sharing["grants"],
             &(&1["principal_uid"] == custom_editor.uid and &1["rule_kind"] == "advanced")
           )

    # PUT /sharing preserves unchanged grant IDs and allows keeping/narrowing disabled & legacy guest grants, while rejecting escalation.
    {:ok, false} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)

    try do
      manager_view =
        owner
        |> recycle_json()
        |> get("/api/v2/pod/pages/#{doc.id}/sharing")
        |> json_response(200)

      assert %{"name" => "Departed Editor"} =
               Enum.find(manager_view["grants"], &(&1["principal_uid"] == departed.uid))

      grant_fields =
        ~w(principal_uid group_id source_node_id source_action target_scope condition actions)

      narrowed_grants =
        Enum.map(manager_view["grants"], fn row ->
          base = Map.take(row, grant_fields)

          if row["principal_uid"] == departed.uid do
            base |> Map.put("role", "view") |> Map.put("actions", ["node_view"])
          else
            base
          end
        end)

      assert %{"page" => %{"id" => _}} =
               owner
               |> send_json(:put, "/pages/#{doc.id}/sharing", %{
                 sharing_version: manager_view["sharing_version"],
                 inherit_permissions: manager_view["inherit_permissions"],
                 grants: narrowed_grants
               })
               |> json_response(200)

      alice_grant_ids_after =
        Ankole.Files.Access.page_grants(doc.id)
        |> Enum.filter(&(&1.principal_uid == alice.uid))
        |> MapSet.new(& &1.id)

      assert alice_grant_ids_after == alice_grant_ids_before

      after_narrow =
        owner
        |> recycle_json()
        |> get("/api/v2/pod/pages/#{doc.id}/sharing")
        |> json_response(200)

      assert %{"errors" => [%{"code" => "invalid_grants"}]} =
               owner
               |> send_json(:put, "/pages/#{doc.id}/sharing", %{
                 sharing_version: after_narrow["sharing_version"],
                 inherit_permissions: after_narrow["inherit_permissions"],
                 grants:
                   Enum.map(after_narrow["grants"], fn row ->
                     base = Map.take(row, grant_fields)

                     if row["principal_uid"] == departed.uid do
                       base |> Map.put("role", "edit") |> Map.delete("actions")
                     else
                       base
                     end
                   end)
               })
               |> json_response(422)

      assert %{"errors" => [%{"code" => "invalid_grants"}]} =
               owner
               |> send_json(:put, "/pages/#{doc.id}/sharing", %{
                 sharing_version: after_narrow["sharing_version"],
                 inherit_permissions: after_narrow["inherit_permissions"],
                 grants:
                   Enum.map(after_narrow["grants"], fn row ->
                     base = Map.take(row, grant_fields)

                     if row["principal_uid"] == legacy_guest.uid do
                       base
                       |> Map.put("role", "manage")
                       |> Map.delete("actions")
                     else
                       base
                     end
                   end)
               })
               |> json_response(422)
    after
      {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", true)
    end

    # File readers can receive commenting on the file itself; Applets have no such surface.
    {:ok, file_page} = Ankole.Pod.Pages.create(actor, %{type: :file, title: "Spec PDF"})
    {:ok, applet_page} = Ankole.Pod.Pages.create(actor, %{type: :applet, title: "Dashboard App"})

    assert %{
             "grants" => [
               %{"role" => "contribute", "target_scope" => "self", "actions" => actions}
             ]
           } =
             owner
             |> send_json(:patch, "/pages/#{file_page.id}/sharing", %{
               upserts: [%{principal_uid: alice.uid, role: "contribute", target_scope: "self"}]
             })
             |> json_response(200)

    assert "node_comment" in actions

    assert %{"errors" => [%{"code" => "invalid_grants"}]} =
             owner
             |> send_json(:patch, "/pages/#{applet_page.id}/sharing", %{
               upserts: [%{principal_uid: alice.uid, role: "contribute", target_scope: "self"}]
             })
             |> json_response(422)

    for typed_page <- [file_page, applet_page] do
      assert %{"grants" => _} =
               owner
               |> send_json(:patch, "/pages/#{typed_page.id}/sharing", %{
                 upserts: [
                   %{principal_uid: alice.uid, role: "contribute", target_scope: "container"}
                 ]
               })
               |> json_response(200)

      assert %{"grants" => _} =
               owner
               |> send_json(:patch, "/pages/#{typed_page.id}/sharing", %{
                 upserts: [%{principal_uid: alice.uid, role: "edit", target_scope: "self"}]
               })
               |> json_response(200)
    end

    # retain_manager preserves self-scoped manage without adding container manage, and retains only the executing Agent on Agent turns.
    {:ok, self_managed} = Ankole.Pod.Pages.create(actor, %{title: "Self Scoped Anchor"})

    {:ok, sv} = Ankole.Pod.Pages.sharing(actor, self_managed.id)

    assert %{"page" => %{"inherit_permissions" => false}} =
             owner
             |> send_json(:put, "/pages/#{self_managed.id}/sharing", %{
               sharing_version: sv.sharing_version,
               inherit_permissions: false,
               grants: [%{principal_uid: uid, role: "manage", target_scope: "self"}]
             })
             |> json_response(200)

    owner_scopes =
      Ankole.Files.Access.page_grants(self_managed.id)
      |> Enum.filter(&(&1.principal_uid == uid))
      |> MapSet.new(& &1.target_scope)

    assert owner_scopes == MapSet.new(["self"])

    agent =
      Ankole.PrincipalsFixtures.agent_fixture(%{
        owner_principal_uid: uid,
        uid: "sharing_agent",
        display_name: "Sharing Agent"
      }).principal

    {:ok, _} = Ankole.Pod.Pages.space_agent(actor, agent.uid, "manage")
    {:ok, agent_page} = Ankole.Pod.Pages.create(actor, %{title: "Interactive Agent Anchor"})

    interactive_actor =
      Ankole.AuthZ.Actor.new(agent)

    assert {:ok, _} =
             Ankole.Pod.Pages.update_sharing(interactive_actor, agent_page.id, %{
               inherit_permissions: false
             })

    assert {:ok, _} = Ankole.Pod.Pages.authorize(interactive_actor, agent_page.id, "node_manage")
    assert {:error, :forbidden} = Ankole.Pod.Pages.authorize(actor, agent_page.id, "node_manage")
  end

  defp session_conn_for(conn, principal, external_id) do
    session = conn |> Plug.Test.init_test_session(%{}) |> AnkoleWeb.Session.ensure_browser()

    {:ok, %{browser: browser, authentication: auth}} =
      Ankole.BrowserSessions.authenticate(AnkoleWeb.Session.browser_reference(session), %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "lark-main",
        "external_id" => external_id
      })

    session
    |> AnkoleWeb.Session.put_authentication(browser, auth)
    |> with_console_csrf()
    |> get("/api/v2/browser/session")
  end

  defp recycle_json(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end

  defp send_json(conn, method, path, attrs) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> dispatch(@endpoint, method, "/api/v2/pod" <> path, Ankole.JSON.encode!(%{data: attrs}))
  end
end
