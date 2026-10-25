defmodule AnkoleWeb.JSONAPI.PodPagesTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

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
             "pages" => [%{"id" => ^root_id, "actions" => actions}],
             "next_cursor" => nil,
             "can_create_private" => true,
             "can_create_space" => true
           } = owner |> recycle_json() |> get("/api/v2/pod/pages/children") |> json_response(200)

    assert actions == ~w(page_view page_write_records page_edit page_manage)

    assert %{"pages" => [%{"id" => ^private_id}], "next_cursor" => nil} =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages/children", %{scope: "private"})
             |> json_response(200)

    assert %{"pages" => [%{"id" => ^child_id}], "next_cursor" => nil} =
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

    assert actions == ~w(page_view page_write_records page_edit page_manage)

    human = Ankole.PrincipalsFixtures.human_fixture().principal

    {:ok, other, flow} =
      conn |> Plug.Test.init_test_session(%{}) |> AnkoleWeb.Session.begin_login(:pod, %{})

    {:ok, _} =
      Ankole.BrowserSessions.bind_provider(
        AnkoleWeb.Session.browser_reference(other),
        flow.id,
        "lark-main"
      )

    {:ok, other, _} =
      AnkoleWeb.Session.complete_login(other, flow.id, %{
        "principal_uid" => human.uid,
        "access_version" => human.access_version,
        "provider_id" => "lark-main",
        "external_id" => "other"
      })

    other = other |> with_console_csrf() |> get("/api/v2/browser/session")
    denied = other |> recycle_json() |> get("/api/v2/pod/pages/#{id}")
    assert %{"errors" => [%{"code" => "forbidden"}]} = json_response(denied, 403)

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             other
             |> send_json(:post, "/pages/#{id}/move", %{parent_id: nil})
             |> json_response(403)

    assert {:ok, %{page: %{private_owner_uid: ^uid}, content: %{content: ^xml}}} =
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
        source_page_id: source.id,
        source_action: "page_view",
        resource_pattern: "pod:**:#{target.id}:**",
        action: "page_write_records"
      })

    sharing =
      owner
      |> recycle_json()
      |> get("/api/v2/pod/pages/#{target.id}/sharing")
      |> json_response(200)

    assert [%{"actions" => ["page_write_records"]}] = sharing["grants"]

    grants =
      Enum.map(sharing["grants"], fn grant ->
        Map.take(
          grant,
          ~w(principal_uid group_id source_page_id source_action target_scope condition actions)
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
    assert {:error, :forbidden} = Ankole.Pod.Pages.authorize(reader, target.id, "page_view")
    assert {:ok, _} = Ankole.Pod.Pages.authorize(reader, target.id, "page_write_records")
  end

  test "sharing accepts one rule meaning and rejects conflicting role and actions", %{conn: conn} do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    human = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})

    for rule <- [
          %{role: "view"},
          %{actions: ["page_write_records"]},
          %{role: "contribute", actions: ["page_write_records", "page_view"]}
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
      grants: [%{principal_uid: human.uid, role: "view", actions: ["page_write_records"]}]
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
          Ankole.Pod.Pages.create(actor, %{parent_id: source.id, title: "Child #{number}"})

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
        required_action: "page_edit"
      })
      |> json_response(200)

    assert Enum.map(candidates["pages"], & &1["id"]) == [destination.id]
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
