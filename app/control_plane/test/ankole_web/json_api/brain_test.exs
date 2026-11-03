defmodule AnkoleWeb.JSONAPI.BrainTest do
  @moduledoc "Checks the Brain routes of the Console JSON:API at `/api/v2/brain`."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    {:ok, _} = SchemaPacks.install_packs([])
    {:ok, false} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), false)
    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  # Sends one JSON:API request on the Console session of `conn`. As in the
  # browser, a request without a body has no content type.
  defp api(conn, method, path, data \\ nil, headers \\ []) do
    conn =
      conn
      |> recycle_api()
      |> delete_req_header("content-type")
      |> put_req_header("accept", "application/vnd.api+json")

    conn =
      if data, do: put_req_header(conn, "content-type", "application/vnd.api+json"), else: conn

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> dispatch(@endpoint, method, path, data && Jason.encode!(%{data: data}))
  end

  defp document(conn, status), do: conn |> response(status) |> Jason.decode!()

  defp error_code(conn, status) do
    assert %{"errors" => [%{"code" => code} | _]} = document(conn, status)
    code
  end

  defp records(conn) do
    conn
    |> document(200)
    |> Map.fetch!("data")
    |> Enum.map(&Map.put(&1["attributes"], "id", &1["id"]))
  end

  defp object_page(conn, slug) do
    conn
    |> recycle_api()
    |> api(:get, ~p"/api/v2/brain/objects/show?slug=#{slug}")
    |> json_response(200)
    |> Map.fetch!("object")
  end

  defp insert_object!(slug, attrs \\ %{}) do
    {:ok, object} =
      Ankole.Brain.create_object(
        Map.merge(%{slug: slug, type: "note", title: slug, body: ""}, attrs),
        :system
      )

    object
  end

  defp write_fact!(object, writer, attrs \\ %{}) do
    {:ok, %{claim: claim}} =
      Ankole.Brain.write_fact(
        Map.merge(
          %{
            subject_page_id: object.id,
            claim: "A fact",
            kind: "fact",
            holder: "world",
            source_node_id: object.id,
            notability: "medium",
            valid_from: DateTime.utc_now(),
            confidence: 0.75,
            provenance: "json api test"
          },
          attrs
        ),
        writer,
        %{options: [embed: false]}
      )

    claim
  end

  describe "authorization and tenant" do
    test "a read grant lists Brain resources and refuses each write before it runs", %{
      conn: conn
    } do
      {conn, principal_uid} = console_conn_with_principal(conn)
      assert {:ok, _} = SchemaPacks.install_packs([])

      Repo.delete_all(
        from(grant in Ankole.AuthZ.Grant,
          where: grant.resource_pattern in ["site_console:**", "tenant_console:**"]
        )
      )

      assert {:ok, _grant} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: principal_uid,
                 resource_pattern: "site_console:brain",
                 action: "read",
                 condition: "true",
                 metadata: %{}
               })

      assert conn |> api(:get, "/api/v2/brain/objects?prefix=notes/") |> records() == []

      assert "forbidden" ==
               conn
               |> api(:post, "/api/v2/brain/sources", %{
                 "kind" => "url",
                 "upstream_id" => "https://refused.example",
                 "name" => "Refused"
               })
               |> error_code(403)

      refute Repo.get_by(Source, upstream_id: "https://refused.example")
    end

    test "a list gives only the rows of the data tenant", %{conn: conn} do
      {conn, _principal_uid} = console_conn_with_principal(conn)
      insert_object!("notes/home-tenant")
      other = Ankole.DataCase.create_tenant()

      Repo.with_tenant(other.id, fn ->
        {:ok, _} = SchemaPacks.install_packs([])
        insert_object!("notes/other-tenant")
      end)

      assert [%{"slug" => "notes/home-tenant"}] =
               conn |> api(:get, "/api/v2/brain/objects?prefix=notes/") |> records()

      assert [%{"slug" => "notes/other-tenant"}] =
               conn
               |> api(:get, "/api/v2/brain/objects?prefix=notes/", nil, [
                 {"x-ankole-tenant", other.id}
               ])
               |> records()
    end
  end

  describe "objects" do
    test "the Console reader links to the one Pod content owner", %{conn: conn} do
      {conn, _uid} = console_conn_with_principal(conn)
      object = insert_object!("notes/read-through", %{body: "Canonical knowledge"})
      page = object_page(conn, object.id)
      assert page["page_id"] == object.id

      assert String.ends_with?(
               page["pod_url"],
               AnkoleWeb.PodURL.page_path(object.id, object.title)
             )

      refute Map.has_key?(page, "body")
    end

    test "object search filters before the list limit and treats wildcards literally", %{
      conn: conn
    } do
      {conn, _principal_uid} = console_conn_with_principal(conn)

      targets = %{
        "RARE%20OBJECT" => insert_object!("notes/zz/rare-object", %{title: "zz Rare object"}),
        "%25" => insert_object!("notes/zz/percent-literal", %{title: "Budget is 20% complete"}),
        "_" => insert_object!("notes/zz/underscore-literal", %{title: "part_number"}),
        "%5C" => insert_object!("notes/zz/backslash-literal", %{title: "path\\segment"})
      }

      insert_object!("notes/zz/percent-decoy", %{title: "Budget is 201 complete"})
      insert_object!("notes/zz/underscore-decoy", %{title: "partXnumber"})
      insert_object!("notes/zz/backslash-decoy", %{title: "pathsegment"})
      for index <- 1..100, do: insert_object!("notes/object-search-fill-#{index}")

      unfiltered = conn |> api(:get, "/api/v2/brain/objects") |> records()
      assert length(unfiltered) == 100
      refute Enum.any?(unfiltered, &(&1["slug"] == "notes/zz/rare-object"))

      for {search, target} <- targets do
        assert [%{"slug" => slug}] =
                 conn |> api(:get, "/api/v2/brain/objects?search=#{search}") |> records()

        assert slug == target.slug
      end
    end
  end

  describe "claims" do
    test "a Console writer cannot supersede another person's private fact", %{conn: conn} do
      {conn, _admin_uid} = console_conn_with_principal(conn)
      %{principal: other} = human_fixture()
      assert {:ok, _} = SchemaPacks.install_packs([])

      {:ok, object} =
        Ankole.Brain.create_object(
          %{slug: "notes/private", type: "note", title: "Private"},
          :system
        )

      {:ok, private} = Ankole.Pod.Pages.Tree.private_root(other.uid)
      claim = write_fact!(object, other.uid, %{source_node_id: private.id})

      assert "writer_not_in_claim_scope" ==
               conn
               |> api(:post, "/api/v2/brain/claims/#{claim.id}/supersede", %{"claim" => "Changed"})
               |> error_code(422)

      refute Repo.reload!(claim).superseded_by
    end

    test "supersede, forget, and resolve record the Console operator", %{conn: conn} do
      {conn, admin_uid} = console_conn_with_principal(conn)
      assert {:ok, _} = SchemaPacks.install_packs([])
      object = insert_object!("notes/claims")
      fact = write_fact!(object, admin_uid)

      assert %{"claim" => "A corrected fact", "author" => author} =
               conn
               |> api(:post, "/api/v2/brain/claims/#{fact.id}/supersede", %{
                 "claim" => "A corrected fact",
                 "confidence" => 0.9
               })
               |> document(201)

      assert author["uid"] == admin_uid
      assert Repo.reload!(fact).superseded_by

      [replacement] =
        conn
        |> api(:get, "/api/v2/brain/claims?subject_page_id=#{object.id}&status=current")
        |> records()

      assert replacement["claim"] == "A corrected fact"

      assert %{"expired_at" => expired_at} =
               conn
               |> api(:post, "/api/v2/brain/claims/#{replacement["id"]}/forget", %{
                 "reason" => "Wrong"
               })
               |> document(201)

      assert is_binary(expired_at)
      assert Repo.get!(Claim, replacement["id"]).provenance =~ "forgotten by console admin: Wrong"

      assert "wrong_claim_type" ==
               conn
               |> api(:post, "/api/v2/brain/claims/#{fact.id}/resolve", %{
                 "resolved_quality" => "correct",
                 "resolved_outcome" => true
               })
               |> error_code(422)

      {:ok, take} =
        Ankole.Brain.Claims.write_take(
          %{
            subject_page_id: object.id,
            claim: "The deal closes",
            kind: "bet",
            holder: "world",
            source_node_id: object.id,
            weight: 0.6,
            provenance: "json api test"
          },
          admin_uid
        )

      assert %{"resolved_quality" => "correct", "resolved_outcome" => true} =
               conn
               |> api(:post, "/api/v2/brain/claims/#{take.id}/resolve", %{
                 "resolved_quality" => "correct",
                 "resolved_outcome" => true
               })
               |> document(201)

      assert Repo.reload!(take).resolved_by ==
               to_string(
                 Ankole.ActorRef.from_principal(
                   Repo.get_by!(Ankole.Principals.Principal, uid: admin_uid)
                 )
               )
    end

    test "claim search filters before the list limit and treats wildcards literally", %{
      conn: conn
    } do
      {conn, principal_uid} = console_conn_with_principal(conn)
      now = DateTime.utc_now(:microsecond)
      object = insert_object!("notes/claim-search")

      author =
        Ankole.ActorRef.from_principal(
          Repo.get_by!(Ankole.Principals.Principal, uid: principal_uid)
        )

      row = fn claim, created_at ->
        %{
          id: UUIDv7.autogenerate(),
          tenant_id: Repo.tenant_id!(),
          author: author,
          claim_type: :fact,
          subject_page_id: object.id,
          claim: claim,
          kind: "fact",
          holder: "world",
          source_node_id: object.id,
          notability: "medium",
          valid_from: now,
          confidence: 0.75,
          provenance: "json api test",
          created_at: created_at,
          updated_at: created_at
        }
      end

      targets = %{
        "RARE%20CLAIM" => row.("Rare claim beyond the first page", DateTime.add(now, -1, :day)),
        "%25" => row.("Budget is 20% complete", DateTime.add(now, -2, :day)),
        "_" => row.("part_number", DateTime.add(now, -4, :day)),
        "%5C" => row.("path\\segment", DateTime.add(now, -6, :day))
      }

      decoys = [
        row.("Budget is 201 complete", DateTime.add(now, -3, :day)),
        row.("partXnumber", DateTime.add(now, -5, :day)),
        row.("pathsegment", DateTime.add(now, -7, :day))
      ]

      fillers =
        for index <- 1..100,
            do: row.("Common claim #{index}", DateTime.add(now, index, :microsecond))

      {107, nil} = Repo.insert_all(Claim, Map.values(targets) ++ decoys ++ fillers)

      unfiltered = conn |> api(:get, "/api/v2/brain/claims") |> records()
      assert length(unfiltered) == 100

      for {search, target} <- targets do
        assert [%{"id" => id}] =
                 conn |> api(:get, "/api/v2/brain/claims?search=#{search}") |> records()

        assert id == target.id
      end

      assert %{"errors" => [_ | _]} =
               conn |> api(:get, "/api/v2/brain/claims?claim_type=unknown") |> document(400)
    end
  end

  describe "reviews" do
    test "a promotion rejection keeps the review record and its reviewer", %{conn: conn} do
      {conn, admin_uid} = console_conn_with_principal(conn)

      {:ok, suggestion} =
        Ankole.Ash.create(SchemaSuggestion, :suggest, %{
          id: UUIDv7.autogenerate(),
          kind: :new_type,
          term: "review-test",
          evidence_count: 100,
          rationale: "Persisted evidence",
          created_at: DateTime.utc_now(:microsecond)
        })

      assert [%{"id" => id, "term" => "review-test"}] =
               conn |> api(:get, "/api/v2/brain/suggestions") |> records()

      assert id == suggestion.id

      assert %{"status" => "rejected"} =
               conn
               |> api(:post, "/api/v2/brain/suggestions/#{suggestion.id}/reject")
               |> document(201)

      reviewed = Repo.get!(SchemaSuggestion, suggestion.id)
      assert reviewed.decided_by.uid == admin_uid
      assert reviewed.decided_at
      assert reviewed.rationale == "Persisted evidence"

      assert [%{"id" => ^id}] =
               conn |> api(:get, "/api/v2/brain/suggestions?status=rejected") |> records()

      for path <- [
            "/api/v2/brain/suggestions",
            "/api/v2/brain/merge-suggestions",
            "/api/v2/brain/contradictions"
          ] do
        encoded = conn |> api(:get, path <> "?status=unknown-state") |> response(400)
        refute encoded =~ "Ash."
        refute encoded =~ "Ankole."
        refute encoded =~ "SELECT"
      end
    end

    test "a merge suggestion lists both page summaries and records its reviewer", %{
      conn: conn
    } do
      {conn, admin_uid} = console_conn_with_principal(conn)
      a = insert_object!("companies/acme", %{title: "Acme", type: "company"})
      b = insert_object!("companies/other", %{title: "Other", type: "company"})

      {:ok, suggestion} =
        Ankole.Ash.create(MergeSuggestion, :suggest, %{
          id: UUIDv7.autogenerate(),
          a_slug: min(a.id, b.id),
          b_slug: max(a.id, b.id),
          reason: "same name",
          created_at: DateTime.utc_now(:microsecond)
        })

      assert [listed] = conn |> api(:get, "/api/v2/brain/merge-suggestions") |> records()

      assert listed["a_page"]["page_id"] == min(a.id, b.id)
      assert listed["b_page"]["page_id"] == max(a.id, b.id)
      assert is_binary(listed["a_page"]["pod_url"])
      assert is_binary(listed["b_page"]["pod_url"])

      assert %{"status" => "rejected"} =
               conn
               |> api(:post, "/api/v2/brain/merge-suggestions/#{suggestion.id}/reject")
               |> document(201)

      assert Repo.get!(MergeSuggestion, suggestion.id).decided_by.uid == admin_uid
    end

    test "a contradiction lists the text of both Claims and takes one decision", %{conn: conn} do
      {conn, admin_uid} = console_conn_with_principal(conn)
      assert {:ok, _} = SchemaPacks.install_packs([])
      object = insert_object!("notes/contradiction")
      a = write_fact!(object, admin_uid, %{claim: "The sky is blue"})
      b = write_fact!(object, admin_uid, %{claim: "The sky is green"})

      {:ok, contradiction} =
        Ankole.Ash.create(Contradiction, :record_verdict, %{
          id: UUIDv7.autogenerate(),
          a_claim_id: a.id,
          b_claim_id: b.id,
          verdict: "contradiction",
          severity: :high,
          confidence: 0.9,
          created_at: DateTime.utc_now(:microsecond)
        })

      assert [listed] = conn |> api(:get, "/api/v2/brain/contradictions") |> records()
      assert listed["id"] == contradiction.id
      assert listed["a_claim_text"] == "The sky is blue"
      assert listed["b_claim_text"] == "The sky is green"

      assert %{"status" => "dismissed"} =
               conn
               |> api(:post, "/api/v2/brain/contradictions/#{contradiction.id}/decide", %{
                 "status" => "dismissed",
                 "resolution_note" => "Different sky"
               })
               |> document(201)

      assert conn |> api(:get, "/api/v2/brain/contradictions") |> records() == []

      assert "conflict" ==
               conn
               |> api(:post, "/api/v2/brain/contradictions/#{contradiction.id}/decide", %{
                 "status" => "resolved"
               })
               |> error_code(409)

      assert "not_found" ==
               conn
               |> api(:post, "/api/v2/brain/contradictions/#{UUIDv7.autogenerate()}/decide", %{
                 "status" => "resolved"
               })
               |> error_code(404)
    end
  end

  describe "sources" do
    test "a Console operator registers, scopes, enqueues, and archives a Source", %{conn: conn} do
      {conn, principal_uid} = console_conn_with_principal(conn)

      assert %{"kind" => "url", "name" => "Docs"} =
               conn
               |> api(:post, "/api/v2/brain/sources", %{
                 "upstream_id" => "https://example.com/docs",
                 "kind" => "url",
                 "name" => "Docs"
               })
               |> document(201)

      assert "unsupported_source_kind" ==
               conn
               |> api(:post, "/api/v2/brain/sources", %{
                 "upstream_id" => "x",
                 "kind" => "unknown",
                 "name" => "X"
               })
               |> error_code(422)

      {:ok, oidc} =
        Ankole.Brain.Sources.create(%{
          kind: "oidc_client",
          upstream_id: UUIDv7.autogenerate(),
          name: "OIDC Client"
        })

      {:ok, private} = Ankole.Pod.Pages.Tree.private_root(principal_uid)
      scope = private.id

      assert %{"default_source_node_id" => ^scope} =
               conn
               |> api(:patch, "/api/v2/brain/sources/#{oidc.id}", %{"source_node_id" => scope})
               |> document(200)

      conn
      |> api(:patch, "/api/v2/brain/sources/#{oidc.id}", %{"source_node_id" => nil})
      |> document(200)

      assert Repo.get!(Source, oidc.id).default_source_node_id == nil

      conn
      |> api(:patch, "/api/v2/brain/sources/#{oidc.id}", %{
        "source_node_id" => UUIDv7.autogenerate()
      })
      |> document(422)

      assert Repo.get!(Source, oidc.id).default_source_node_id == nil

      assert {:ok, true} = Ankole.AppConfigure.put_global_by_key("brain.enabled", true)
      [url_source] = Repo.all(from(source in Source, where: source.kind == "url"))

      assert %{"success" => true} =
               conn
               |> api(:post, "/api/v2/brain/sources/#{url_source.id}/learn")
               |> document(201)

      assert length(conn |> api(:get, "/api/v2/brain/sources") |> records()) == 2
    end

    test "archiving a Source preserves its editable Pod content", %{conn: conn} do
      {conn, _principal_uid} = console_conn_with_principal(conn)
      now = DateTime.utc_now(:microsecond)

      {:ok, source} =
        Ankole.Ash.create(Source, :register, %{
          upstream_id: "json-api-archive-library",
          kind: "url",
          name: "Archive library",
          default_source_node_id: Ankole.Brain.Scope.world(),
          config: %{},
          created_at: now
        })

      object = insert_projection!(source, "concepts/json-api-archive", now)

      assert %{"archived_at" => archived_at} =
               conn
               |> api(:post, "/api/v2/brain/sources/#{source.id}/archive")
               |> document(201)

      assert is_binary(archived_at)
      assert {:ok, %{deleted_at: nil}} = Ankole.Pod.Pages.Tree.fetch(object.id)

      assert "not_found" ==
               conn
               |> api(:post, "/api/v2/brain/sources/#{UUIDv7.autogenerate()}/archive")
               |> error_code(404)
    end
  end

  test "a site administrator in another tenant records its own attribution", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, admin_uid} = console_conn_with_principal(conn)
    other = Ankole.DataCase.create_tenant()

    claim =
      Repo.with_tenant(other.id, fn ->
        {:ok, _} = SchemaPacks.install_packs([])
        object = insert_object!("notes/admin-edit")
        write_fact!(object, :system)
      end)

    result =
      conn
      |> api(
        :post,
        "/api/v2/brain/claims/#{claim.id}/supersede",
        %{"claim" => "Corrected across tenant"},
        [{"x-ankole-tenant", other.id}]
      )
      |> document(201)

    assert result["author"] == %{"tenant_id" => tenant.id, "uid" => admin_uid}
  end

  defp insert_projection!(source, slug, _now) do
    {:ok, object} =
      Ankole.Brain.upsert_source_projection(source, %{
        slug: slug,
        type: "concept",
        title: slug,
        body: "Managed body"
      })

    object
  end
end
