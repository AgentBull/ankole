defmodule AnkoleWeb.JSONAPI.MetaAnkoleTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod
  import Ankole.PrincipalsFixtures

  defp meta_conn(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end

  setup %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)

    for action <- ["update", "delete"] do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: uid,
          resource_pattern: "tenant_console:**",
          action: action
        })
    end

    %{conn: conn, uid: uid}
  end

  test "a member creates, edits and reads a binary Skill package with CAS", %{conn: conn} do
    created =
      conn
      |> meta_conn()
      |> post("/api/v2/pod/meta/skills", %{
        data: %{
          slug: "api-demo",
          manifest_xml: "<page><p>Read references/data.bin when needed.</p></page>",
          metadata: %{name: "API demo", description: "Demonstrate a package"}
        }
      })
      |> json_response(201)

    refute created["enabled_for_all"]
    assert created["manifest_markdown"] =~ "Read references/data.bin"

    data = %{
      path: "references/data.bin",
      content_base64: Base.encode64(<<0, 1, 255>>),
      base_revision: created["revision"],
      content_type: "application/octet-stream",
      mode: 292
    }

    saved =
      conn
      |> meta_conn()
      |> put("/api/v2/pod/meta/skills/api-demo/file", %{data: data})
      |> json_response(200)

    conn
    |> meta_conn()
    |> put("/api/v2/pod/meta/skills/api-demo/file", %{data: data})
    |> json_response(409)

    read =
      conn
      |> meta_conn()
      |> get("/api/v2/pod/meta/skills/api-demo/file", %{path: data.path})
      |> json_response(200)

    assert read["content_base64"] == data.content_base64
    assert read["revision"] == saved["revision"]

    conflict =
      conn
      |> meta_conn()
      |> put("/api/v2/pod/meta/skills/api-demo/file", %{
        data: %{data | path: "references", base_revision: saved["revision"]}
      })
      |> json_response(409)

    assert Enum.any?(conflict["errors"], &(&1["code"] == "skill_path_conflict"))
    detail = conn |> meta_conn() |> get("/api/v2/pod/meta/skills/api-demo") |> json_response(200)
    assert detail["skill"]["revision"] == saved["revision"]
    assert [%{"relative_path" => "references/data.bin"}] = detail["files"]
  end

  test "the Skill list reports each Skill's permissions by its source", %{conn: conn} do
    conn
    |> meta_conn()
    |> post("/api/v2/pod/meta/skills", %{
      data: %{
        slug: "list-demo",
        manifest_xml: "<page />",
        metadata: %{name: "List demo", description: "List a custom Skill"}
      }
    })
    |> json_response(201)

    list = conn |> meta_conn() |> get("/api/v2/pod/meta/skills") |> json_response(200)
    by_source = Enum.group_by(list["skills"], & &1["source_kind"])

    assert list["can_create"]

    assert [
             %{
               "slug" => "list-demo",
               "can_edit" => true,
               "can_delete" => true,
               "can_bind_all" => true
             }
           ] = by_source["custom"]

    assert [_ | _] = by_source["builtin"]

    assert Enum.all?(
             by_source["builtin"],
             &(&1["can_edit"] and not &1["can_delete"] and &1["can_bind_all"])
           )
  end

  test "the Agent list excludes disabled colleagues", %{conn: conn} do
    agent = agent_fixture().principal
    {:ok, _} = Ankole.Principals.disable_agent(agent.uid)
    result = conn |> meta_conn() |> get("/api/v2/pod/meta/agents") |> json_response(200)
    refute Enum.any?(result["agents"], &(&1["uid"] == agent.uid))
  end

  test "an administrator cannot read another member's assistant contracts", %{conn: conn} do
    owner = human_fixture().principal
    worker_provider_fixture(%{is_default: true})
    {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(owner.uid)

    conn
    |> meta_conn()
    |> get("/api/v2/pod/meta/agents/#{assistant.uid}/contracts")
    |> json_response(403)

    conn |> meta_conn() |> get("/api/v2/pod/meta/agents/#{assistant.uid}") |> json_response(403)
  end

  test "global contract editing uses independent slots and rejects a stale revision", %{
    conn: conn
  } do
    result =
      conn |> meta_conn() |> get("/api/v2/pod/meta/contracts") |> json_response(200)

    slot = Enum.find(result["contracts"], &(&1["slot"] == "agents"))

    data = %{
      mode: "override",
      content_xml: "<page><p>Organization instruction</p></page>",
      metadata: %{},
      base_revision: slot["revision"]
    }

    saved =
      conn
      |> meta_conn()
      |> put("/api/v2/pod/meta/contracts/agents", %{data: data})
      |> json_response(200)

    assert saved["content_markdown"] =~ "Organization instruction"

    effective =
      conn |> meta_conn() |> get("/api/v2/pod/meta/contracts") |> json_response(200)

    assert Enum.find(effective["contracts"], &(&1["slot"] == "agents"))["effective_markdown"] ==
             saved["content_markdown"]

    conn
    |> meta_conn()
    |> put("/api/v2/pod/meta/contracts/agents", %{data: data})
    |> json_response(409)
  end

  test "the assistant editor displays the same effective instructions as its runtime", %{
    conn: conn,
    uid: uid
  } do
    worker_provider_fixture(%{is_default: true})
    {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(uid)

    before =
      conn
      |> meta_conn()
      |> get("/api/v2/pod/meta/agents/#{assistant.uid}/contracts")
      |> json_response(200)

    design = Enum.find(before["contracts"], &(&1["slot"] == "design"))

    conn
    |> meta_conn()
    |> put("/api/v2/pod/meta/agents/#{assistant.uid}/contracts/design", %{
      data: %{
        mode: "append",
        content_xml: "<page><p>Use numbered diagrams.</p></page>",
        metadata: %{},
        base_revision: design["revision"]
      }
    })
    |> json_response(200)

    after_save =
      conn
      |> meta_conn()
      |> get("/api/v2/pod/meta/agents/#{assistant.uid}/contracts")
      |> json_response(200)

    {:ok, runtime} = Ankole.AIAgent.Library.Contracts.effective(assistant.uid)
    actual = Enum.find(after_save["contracts"], &(&1["slot"] == "design"))["effective_markdown"]
    assert actual == runtime["design"]["content"]
    assert actual =~ "Use numbered diagrams."
    assert actual =~ design["effective_markdown"]
  end

  test "Agent UIDs are literal even when named assistant or global", %{conn: conn, uid: uid} do
    worker_provider_fixture(%{is_default: true})
    {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(uid)

    for name <- ["assistant", "global"] do
      created =
        conn
        |> meta_conn()
        |> post("/api/v2/pod/meta/agents", %{
          data: %{uid: name, display_name: "Colleague #{name}", role: "Review"}
        })
        |> json_response(201)

      shown = conn |> meta_conn() |> get("/api/v2/pod/meta/agents/#{name}") |> json_response(200)
      assert shown["uid"] == created["uid"]
      refute shown["uid"] == assistant.uid
      assert shown["type"] == "ai_colleague"

      updated =
        conn
        |> meta_conn()
        |> patch("/api/v2/pod/meta/agents/#{name}", %{
          data: %{display_name: "Renamed #{name}"}
        })
        |> json_response(200)

      assert updated["uid"] == name
      assert updated["display_name"] == "Renamed #{name}"

      {:ok, baseline} = Ankole.AIAgent.Library.Contracts.get(nil, :agents)

      result =
        conn
        |> meta_conn()
        |> get("/api/v2/pod/meta/agents/#{name}/contracts")
        |> json_response(200)

      slot = Enum.find(result["contracts"], &(&1["slot"] == "agents"))

      conn
      |> meta_conn()
      |> put("/api/v2/pod/meta/agents/#{name}/contracts/agents", %{
        data: %{
          mode: "override",
          content_xml: "<page><p>Only #{name}</p></page>",
          metadata: %{},
          base_revision: slot["revision"]
        }
      })
      |> json_response(200)

      assert {:ok, ^baseline} = Ankole.AIAgent.Library.Contracts.get(nil, :agents)
      {:ok, effective} = Ankole.AIAgent.Library.Contracts.effective(name)
      assert effective["agents"]["content"] =~ "Only #{name}"
    end

    {:ok, personal} = Ankole.Principals.get_agent(assistant.uid)
    refute personal.principal.display_name in ["Renamed assistant", "Renamed global"]
  end

  test "Brain favorites, search and trash remain in the Brain domain", %{uid: uid} do
    actor = actor_fixture(uid)
    category = Ankole.BrainFixtures.category_fixture(uid)

    {:ok, brain} =
      Ankole.Pod.Pages.create(actor, %{
        type: :knowledge,
        parent_id: category.id,
        title: "Domain sample"
      })

    {:ok, ordinary} = Ankole.Pod.Pages.create(actor, %{type: :doc, title: "Domain sample"})
    for page <- [brain, ordinary], do: Ankole.Pod.Pages.state(actor, page.id, %{favorite: true})
    assert {:ok, favorites} = Ankole.Pod.Pages.list(actor, %{scope: :favorites, domain: :brain})
    assert Enum.any?(favorites, &(&1.id == brain.id))
    refute Enum.any?(favorites, &(&1.id == ordinary.id))

    assert {:ok, %{pages: search}} =
             Ankole.Pod.Pages.search(actor, "Domain sample", %{domain: :all})

    assert Enum.any?(search, &(&1.id == brain.id))
    assert Enum.any?(search, &(&1.id == ordinary.id))
    for page <- [brain, ordinary], do: Ankole.Pod.Pages.delete(actor, page.id)
    assert {:ok, trash} = Ankole.Pod.Pages.list(actor, %{scope: :trash, domain: :brain})
    assert Enum.any?(trash, &(&1.id == brain.id))
    refute Enum.any?(trash, &(&1.id == ordinary.id))
    assert {:ok, pages_trash} = Ankole.Pod.Pages.list(actor, %{scope: :trash})
    refute Enum.any?(pages_trash, &(&1.id == brain.id))
    assert Enum.any?(pages_trash, &(&1.id == ordinary.id))
  end

  test "knowledge export reads current content without a snapshot and authorized history with one",
       %{
         conn: conn,
         uid: uid
       } do
    actor = actor_fixture(uid)
    category = Ankole.BrainFixtures.category_fixture(uid)

    {:ok, page} =
      Ankole.Pod.Pages.create(actor, %{
        type: :knowledge,
        parent_id: category.id,
        title: "Export sample",
        xml: "<page><p>Original knowledge</p></page>",
        metadata: %{"summary" => "Original summary"}
      })

    history =
      conn |> meta_conn() |> get("/api/v2/pod/pages/#{page.id}/history") |> json_response(200)

    [%{"id" => snapshot_id}] = history["snapshots"]

    {:ok, _} =
      Ankole.Pod.Knowledge.write(
        actor,
        page.id,
        page.revision,
        "<page><p>Current knowledge</p></page>",
        %{"summary" => "Current summary"}
      )

    path = "/api/v2/pod/pages/#{page.id}/knowledge/export"
    current = conn |> meta_conn() |> get(path) |> json_response(200)
    assert current["markdown"] =~ "Current knowledge"
    assert current["markdown"] =~ "Current summary"

    historical =
      conn |> meta_conn() |> get(path, %{snapshot_id: snapshot_id}) |> json_response(200)

    assert historical["markdown"] =~ "Original knowledge"
    assert historical["markdown"] =~ "Original summary"
    refute historical["markdown"] =~ "Current knowledge"
  end

  test "knowledge export rejects an unreadable page without a snapshot", %{conn: conn, uid: uid} do
    owner = human_fixture().principal
    category = Ankole.BrainFixtures.category_fixture(owner.uid)
    actor = actor_fixture(owner.uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{type: :knowledge, parent_id: category.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: owner.uid, role: "manage"}]
      })

    assert {:error, :forbidden} =
             Ankole.Pod.Pages.authorize(actor_fixture(uid), page.id, "node_view")

    response = conn |> meta_conn() |> get("/api/v2/pod/pages/#{page.id}/knowledge/export")
    assert [%{"code" => "forbidden"}] = json_response(response, 403)["errors"]
  end

  test "knowledge panel returns its visible contents", %{conn: conn, uid: uid} do
    category = Ankole.BrainFixtures.category_fixture(uid)

    {:ok, page} =
      Ankole.Pod.Pages.create(actor_fixture(uid), %{type: :knowledge, parent_id: category.id})

    response = conn |> meta_conn() |> get("/api/v2/pod/pages/#{page.id}/knowledge")

    assert %{
             "panel" => %{
               "backlinks" => [],
               "claims" => [],
               "timelines" => [],
               "scorecard" => %{"takes" => 0, "brier" => nil}
             }
           } = json_response(response, 200)
  end

  test "knowledge panel returns forbidden for an unreadable page", %{conn: conn, uid: uid} do
    owner = human_fixture().principal
    category = Ankole.BrainFixtures.category_fixture(owner.uid)

    {:ok, page} =
      Ankole.Pod.Pages.create(actor_fixture(owner.uid), %{
        type: :knowledge,
        parent_id: category.id
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: owner.uid, role: "manage"}]
      })

    assert {:error, :forbidden} =
             Ankole.Pod.Pages.authorize(actor_fixture(uid), page.id, "node_view")

    response = conn |> meta_conn() |> get("/api/v2/pod/pages/#{page.id}/knowledge")
    assert [%{"code" => "forbidden"}] = json_response(response, 403)["errors"]
  end

  test "knowledge panel returns not_found for a trashed page", %{conn: conn, uid: uid} do
    category = Ankole.BrainFixtures.category_fixture(uid)
    actor = actor_fixture(uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{type: :knowledge, parent_id: category.id})
    assert {:ok, _} = Ankole.Pod.Pages.delete(actor, page.id)
    response = conn |> meta_conn() |> get("/api/v2/pod/pages/#{page.id}/knowledge")
    assert [%{"code" => "not_found"}] = json_response(response, 404)["errors"]
  end

  test "Brain graph and ontology stay outside the collaboration tree", %{conn: conn, uid: uid} do
    {:ok, _} = Ankole.Brain.SchemaPacks.install_packs([])
    {:ok, category} = Ankole.Brain.ObjectWrites.category("companies")

    {:ok, :ok} =
      Ankole.Repo.transact(fn ->
        :ok =
          Ankole.Pod.Access.put_role(
            %{principal_uid: uid},
            "drive:**:#{category.id}:**",
            "manage"
          )

        {:ok, :ok}
      end)

    {:ok, page} =
      Ankole.Pod.Pages.create(actor_fixture(uid), %{
        type: :knowledge,
        parent_id: category.id,
        title: "Meta company"
      })

    graph = conn |> meta_conn() |> get("/api/v2/pod/meta/brain") |> json_response(200)
    assert Enum.any?(graph["nodes"], &(&1["id"] == page.id))

    search =
      conn
      |> meta_conn()
      |> get("/api/v2/pod/pages/search", %{query: "Meta company"})
      |> json_response(200)

    refute Enum.any?(search["pages"], &(&1["id"] == page.id))

    assert {:error, :invalid_page_domain} =
             Ankole.Pod.Pages.create(actor_fixture(uid), %{type: :knowledge, title: "Wrong root"})

    assert {:error, :immutable_root} = Ankole.Pod.Pages.delete(actor_fixture(uid), category.id)
  end

  test "Brain graph exposes ontology hierarchy, ownership, and authorized evidence edges", %{
    conn: conn,
    uid: uid
  } do
    worker_provider_fixture(%{is_default: true})
    {:ok, _} = Ankole.Brain.SchemaPacks.install_packs([])
    {:ok, %{principal: assistant}} = Ankole.Principals.ensure_personal_assistant(uid)
    actor = actor_fixture(uid)

    {:ok, companies} = Ankole.Brain.ObjectWrites.category("companies")
    {:ok, analysis} = Ankole.Brain.ObjectWrites.category("analysis")

    {:ok, :ok} =
      Ankole.Repo.transact(fn ->
        for category <- [companies, analysis] do
          :ok =
            Ankole.Pod.Access.put_role(
              %{principal_uid: uid},
              "drive:**:#{category.id}:**",
              "manage"
            )
        end

        {:ok, :ok}
      end)

    {:ok, parent_company} =
      Ankole.Pod.Pages.create(actor, %{
        type: :knowledge,
        parent_id: companies.id,
        title: "Parent Corp"
      })

    {:ok, child_division} =
      Ankole.Pod.Pages.create(actor, %{
        type: :knowledge,
        parent_id: parent_company.id,
        title: "Cloud Division"
      })

    {:ok, report_page} =
      Ankole.Pod.Pages.create(actor, %{
        type: :knowledge,
        parent_id: analysis.id,
        title: "Q3 Diligence Report",
        xml: ~s(<page><p>Covers <mention page="#{parent_company.id}" />.</p></page>),
        metadata: %{"subtype" => "diligence"}
      })

    {:ok, _} =
      Ankole.Brain.Claims.write_fact(
        %{
          subject_page_id: child_division.id,
          source_node_id: report_page.id,
          claim: "Cloud Division ARR grew 42% YoY.",
          kind: "fact",
          holder: "world",
          notability: "high",
          valid_from: DateTime.utc_now(:microsecond),
          confidence: 0.9,
          provenance: "test"
        },
        :system,
        embed: false
      )

    other_owner = human_fixture().principal

    {:ok, secret_source} =
      Ankole.Pod.Pages.create(actor_fixture(other_owner.uid), %{
        type: :doc,
        title: "Private Memo"
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(other_owner.uid, secret_source.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: other_owner.uid, role: "manage"}]
      })

    {:ok, member_page} = Ankole.Brain.Objects.resolve_reference("people/" <> uid)
    {:ok, assistant_page} = Ankole.Brain.Objects.resolve_reference("agents/" <> assistant.uid)

    {:ok, _} =
      Ankole.Brain.Claims.write_take(
        %{
          subject_page_id: parent_company.id,
          source_node_id: secret_source.id,
          claim: "Secret take that must stay hidden from uid",
          kind: "thesis",
          holder: member_page.id,
          weight: 0.8,
          provenance: "secret"
        },
        :system,
        embed: false
      )

    {:ok, _} =
      Ankole.Brain.Claims.write_take(
        %{
          subject_page_id: child_division.id,
          source_node_id: report_page.id,
          claim: "Cloud Division will lead margin expansion.",
          kind: "thesis",
          holder: member_page.id,
          weight: 0.8,
          provenance: "visible"
        },
        :system,
        embed: false
      )

    graph = conn |> meta_conn() |> get("/api/v2/pod/meta/brain") |> json_response(200)

    company_category = Enum.find(graph["categories"], &(&1["name"] == "companies"))
    assert company_category["entity_type"] == "company"
    assert company_category["primitive"] == "entity"

    nodes_by_id = Map.new(graph["nodes"], &{&1["id"], &1})
    assert nodes_by_id[parent_company.id]["parent_id"] == companies.id
    assert nodes_by_id[child_division.id]["parent_id"] == parent_company.id
    assert nodes_by_id[report_page.id]["subtype"] == "diligence"

    links = graph["links"]

    assert Enum.any?(
             links,
             &(&1["from_page_id"] == parent_company.id and
                 &1["to_page_id"] == child_division.id and
                 &1["link_type"] == "contains" and
                 &1["relation_kind"] == "hierarchy")
           )

    assert Enum.any?(
             links,
             &(&1["from_page_id"] == report_page.id and
                 &1["to_page_id"] == parent_company.id and
                 &1["link_type"] == "references" and
                 &1["relation_kind"] == "reference")
           )

    assert Enum.any?(
             links,
             &(&1["from_page_id"] == report_page.id and
                 &1["to_page_id"] == child_division.id and
                 &1["link_type"] == "evidences" and
                 &1["relation_kind"] == "evidence")
           )

    assert Enum.any?(
             links,
             &(&1["from_page_id"] == member_page.id and
                 &1["to_page_id"] == child_division.id and
                 &1["link_type"] == "holds_take" and
                 &1["relation_kind"] == "evidence")
           )

    refute Enum.any?(
             links,
             &(&1["from_page_id"] == member_page.id and
                 &1["to_page_id"] == parent_company.id and
                 &1["link_type"] == "holds_take")
           )

    assert Enum.any?(
             links,
             &(&1["from_page_id"] == assistant_page.id and
                 &1["to_page_id"] == member_page.id and
                 &1["link_type"] == "assists" and
                 &1["relation_kind"] == "ownership")
           )
  end
end
