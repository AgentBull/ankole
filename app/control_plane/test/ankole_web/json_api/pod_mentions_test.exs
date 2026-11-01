defmodule AnkoleWeb.JSONAPI.PodMentionsTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  test "GET /mentions/candidates and POST /mentions/resolve serve authorized pages and principals while isolating guests",
       %{conn: conn} do
    {owner_conn, owner_uid} = console_conn_with_principal(conn)
    owner_actor = Ankole.PrincipalsFixtures.actor_fixture(owner_uid)

    colleague =
      Ankole.PrincipalsFixtures.human_fixture(%{
        display_name: "Elena Engineer",
        email: "elena.identity@example.com",
        job_title: "Frontend Lead"
      }).principal

    assert {:ok, _} = Ankole.Principals.update_human(colleague.uid, %{email: "elena@example.com"})

    outsider =
      Ankole.PrincipalsFixtures.human_fixture(%{
        display_name: "Hidden Member",
        email: "hidden@example.com"
      }).principal

    guest =
      Ankole.PrincipalsFixtures.human_fixture(%{
        membership: :guest,
        display_name: "Partner Guest",
        email: "partner@external.example"
      }).principal

    agent =
      Ankole.PrincipalsFixtures.agent_fixture(%{
        owner_principal_uid: owner_uid,
        uid: "planner_agent",
        display_name: "Planner Agent",
        role: "Roadmap Assistant"
      }).principal

    {:ok, root} = Ankole.Pod.Pages.create(owner_actor, %{title: "Engineering"})

    {:ok, shared_doc} =
      Ankole.Pod.Pages.create(owner_actor, %{
        parent_id: root.id,
        title: "Release Checklist",
        icon: "🚀",
        xml: "<page><p>Launch verification steps.</p></page>"
      })

    {:ok, private_doc} =
      Ankole.Pod.Pages.create(owner_actor, %{
        private_owner_uid: owner_uid,
        title: "Private Salary Band",
        icon: "🔐"
      })

    {:ok, _} =
      Ankole.Pod.Pages.update_sharing(owner_actor, shared_doc.id, %{
        upserts: [
          %{principal_uid: guest.uid, role: "view", target_scope: "self"},
          %{principal_uid: colleague.uid, role: "edit", target_scope: "self"}
        ]
      })

    member_candidates =
      owner_conn
      |> recycle_json()
      |> get("/api/v2/pod/mentions/candidates", %{query: "Planner", category: "principal"})
      |> json_response(200)

    assert [%{"principal_uid" => agent_uid, "kind" => "agent"}] =
             member_candidates["principals"]

    assert agent_uid == agent.uid

    member_page_candidates =
      owner_conn
      |> recycle_json()
      |> get("/api/v2/pod/mentions/candidates", %{query: "Release", category: "page"})
      |> json_response(200)

    assert [
             %{
               "id" => shared_id,
               "title" => "Release Checklist",
               "ancestors" => ["Space", "Engineering"]
             }
           ] = member_page_candidates["pages"]

    assert shared_id == shared_doc.id

    guest_conn = session_conn_for(conn, guest, "partner-guest")

    guest_candidates =
      guest_conn
      |> recycle_json()
      |> get("/api/v2/pod/mentions/candidates", %{
        query: "",
        category: "all",
        current_page_id: shared_doc.id
      })
      |> json_response(200)

    # Empty query excludes `current_page_id` from default page suggestions.
    assert guest_candidates["pages"] == []

    guest_search_candidates =
      guest_conn
      |> recycle_json()
      |> get("/api/v2/pod/mentions/candidates", %{
        query: "Release",
        category: "page",
        current_page_id: shared_doc.id
      })
      |> json_response(200)

    # Explicit keyword search matches `current_page_id`, and omits unreadable `Engineering` parent!
    assert [%{"id" => ^shared_id, "ancestors" => []}] = guest_search_candidates["pages"]

    guest_principal_uids = MapSet.new(guest_candidates["principals"], & &1["principal_uid"])
    assert MapSet.member?(guest_principal_uids, guest.uid)
    assert MapSet.member?(guest_principal_uids, colleague.uid)
    assert MapSet.member?(guest_principal_uids, owner_uid)
    refute MapSet.member?(guest_principal_uids, outsider.uid)
    refute MapSet.member?(guest_principal_uids, agent.uid)

    assert Enum.all?(
             guest_candidates["principals"],
             &(is_nil(&1["email"]) and is_nil(&1["job_title"]))
           )

    for pii_query <- ["elena@example.com", "Frontend Lead"] do
      pii_search =
        guest_conn
        |> recycle_json()
        |> get("/api/v2/pod/mentions/candidates", %{
          query: pii_query,
          category: "principal",
          current_page_id: shared_doc.id
        })
        |> json_response(200)

      assert pii_search["principals"] == []
    end

    resolved =
      guest_conn
      |> recycle_json()
      |> post("/api/v2/pod/mentions/resolve", %{
        data: %{
          page_ids: [shared_doc.id, private_doc.id],
          principal_uids: [colleague.uid, outsider.uid],
          context_page_id: shared_doc.id
        }
      })
      |> json_response(201)

    assert [
             %{
               "id" => ^shared_id,
               "access" => "ok",
               "title" => "Release Checklist",
               "icon" => "🚀",
               "excerpt" => "Launch verification steps."
             },
             %{
               "id" => private_id,
               "access" => "restricted",
               "title" => nil,
               "icon" => nil,
               "excerpt" => nil
             }
           ] = resolved["pages"]

    assert private_id == private_doc.id

    assert [
             %{
               "principal_uid" => colleague_uid,
               "access" => "ok",
               "name" => "Elena Engineer",
               "email" => nil,
               "job_title" => nil
             },
             %{
               "principal_uid" => outsider_uid,
               "access" => "restricted",
               "name" => nil,
               "email" => nil
             }
           ] = resolved["principals"]

    assert colleague_uid == colleague.uid
    assert outsider_uid == outsider.uid

    member_resolved =
      owner_conn
      |> recycle_json()
      |> post("/api/v2/pod/mentions/resolve", %{
        data: %{principal_uids: [colleague.uid], context_page_id: shared_doc.id}
      })
      |> json_response(201)

    assert [
             %{
               "principal_uid" => ^colleague_uid,
               "access" => "ok",
               "name" => "Elena Engineer",
               "email" => "elena@example.com",
               "job_title" => "Frontend Lead"
             }
           ] = member_resolved["principals"]

    {:ok, base_page} =
      Ankole.Pod.Pages.create(owner_actor, %{type: :base, title: "Pipeline Base"})

    embeddable_search =
      owner_conn
      |> recycle_json()
      |> get("/api/v2/pod/pages/search?query=&embeddable=true")
      |> json_response(200)

    returned_ids = Enum.map(embeddable_search["pages"], & &1["id"])
    assert base_page.id in returned_ids
    refute shared_doc.id in returned_ids
    refute private_doc.id in returned_ids
    assert Enum.all?(embeddable_search["pages"], &(&1["type"] in ["base", "file", "applet"]))
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
end
