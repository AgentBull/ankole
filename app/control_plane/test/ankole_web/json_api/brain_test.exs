defmodule AnkoleWeb.JSONAPI.BrainTest do
  @moduledoc "Checks the Brain routes of the Console JSON:API at `/api/v2/brain`."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
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

  defp object_form(attrs) do
    Map.merge(
      %{
        "slug" => "notes/v2",
        "type" => "note",
        "title" => "V2 object",
        "body" => "Body.",
        "meta" => %{}
      },
      attrs
    )
  end

  defp insert_object!(slug, attrs \\ %{}) do
    now = DateTime.utc_now(:microsecond)

    {:ok, object} =
      Repo.transact(fn ->
        Ankole.Ash.create(
          Object,
          :create,
          Map.merge(
            %{
              id: UUIDv7.autogenerate(),
              slug: slug,
              type: "note",
              title: slug,
              body: "",
              meta: %{},
              created_at: now,
              updated_at: now
            },
            attrs
          )
        )
      end)

    object
  end

  defp write_fact!(object, writer, attrs \\ %{}) do
    {:ok, %{claim: claim}} =
      Ankole.Brain.write_fact(
        Map.merge(
          %{
            object_slug: object.slug,
            claim: "A fact",
            kind: "fact",
            holder: "world",
            audience_scope: "world",
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

  defp chunk_scopes(object) do
    Chunk
    |> where([chunk], chunk.object_id == ^object.id)
    |> order_by([chunk], asc: chunk.chunk_index)
    |> Repo.all()
    |> Enum.map(& &1.audience_scope)
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
               |> api(:post, "/api/v2/brain/objects", object_form(%{"slug" => "notes/refused"}))
               |> error_code(403)

      refute Repo.get_by(Object, slug: "notes/refused")
    end

    test "a list gives only the rows of the data tenant", %{conn: conn} do
      {conn, _principal_uid} = console_conn_with_principal(conn)
      insert_object!("notes/home-tenant")
      other = Ankole.DataCase.create_tenant()
      Repo.with_tenant(other.id, fn -> insert_object!("notes/other-tenant") end)

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
    test "a Console writer creates, CAS-updates, and reads the version history", %{conn: conn} do
      assert {:ok, _} = SchemaPacks.install_packs([])
      {conn, principal_uid} = console_conn_with_principal(conn)

      body = """
      Public.
      {% audience scope="principal:#{principal_uid}" %}
      Private.
      {% /audience %}
      """

      created =
        conn
        |> api(
          :post,
          "/api/v2/brain/objects",
          object_form(%{
            "slug" => "notes/console-edit",
            "body" => body,
            "meta" => %{"source" => "console"},
            "effective_date" => "2026-08-30"
          })
        )
        |> document(201)

      assert created["slug"] == "notes/console-edit"
      assert created["effective_date"] == "2026-08-30"
      assert created["managed_by_source_id"] == nil

      object = Repo.get_by!(Object, slug: "notes/console-edit")
      assert object |> chunk_scopes() |> Enum.sort() == ["principal:#{principal_uid}", "world"]
      page = object_page(conn, "notes/console-edit")
      assert page["body"] == body

      updated_body = String.replace(body, "Private.", "Revised private.")

      update = %{
        "slug" => "notes/console-edit",
        "title" => "Console edit revised",
        "body" => updated_body,
        "meta" => %{"source" => "console"},
        "expected_content_hash" => page["content_hash"]
      }

      assert %{"title" => "Console edit revised"} =
               conn |> api(:patch, "/api/v2/brain/objects", update) |> document(200)

      assert Repo.reload!(object).body == updated_body

      assert "content_hash_conflict" ==
               conn
               |> api(:patch, "/api/v2/brain/objects", %{update | "title" => "Stale"})
               |> error_code(409)

      assert [%{"author" => author, "body" => ^body}] =
               conn
               |> api(:get, "/api/v2/brain/object-versions?slug=notes%2Fconsole-edit")
               |> records()

      assert author["uid"] == principal_uid

      assert "not_found" ==
               conn
               |> api(:get, "/api/v2/brain/object-versions?slug=notes%2Fmissing")
               |> error_code(404)
    end

    test "Console tags stay when omitted and clear with an explicit empty list", %{conn: conn} do
      {conn, _uid} = console_conn_with_principal(conn)
      assert {:ok, _} = SchemaPacks.install_packs([])

      form =
        object_form(%{
          "slug" => "notes/console-tags",
          "tags" => [" research ", "research", "AI", "multi\nline", "literal\\ntext"]
        })

      conn |> api(:post, "/api/v2/brain/objects", form) |> document(201)
      created = object_page(conn, "notes/console-tags")
      assert created["tags"] == ["AI", "literal\\ntext", "multi\nline", "research"]

      update =
        form
        |> Map.drop(["type", "tags"])
        |> Map.put("expected_content_hash", created["content_hash"])

      conn |> api(:patch, "/api/v2/brain/objects", update) |> document(200)
      preserved = object_page(conn, "notes/console-tags")
      assert preserved["tags"] == created["tags"]

      clear =
        update
        |> Map.put("tags", [])
        |> Map.put("expected_content_hash", preserved["content_hash"])

      conn |> api(:patch, "/api/v2/brain/objects", clear) |> document(200)
      assert object_page(conn, "notes/console-tags")["tags"] == []
    end

    test "object writes give the domain reason as the error code", %{conn: conn} do
      assert {:ok, _} = SchemaPacks.install_packs([])
      {conn, principal_uid} = console_conn_with_principal(conn)

      assert {:ok, _} =
               Ankole.AuthZ.create_principal_group(%{
                 name: "restricted",
                 display_name: "Restricted"
               })

      cases = [
        {%{"slug" => "notes/bad slug"}, "invalid_slug"},
        {%{"type" => "made-up"}, "unknown_object_type"},
        {%{"body" => "{% audience scope=\"group:restricted\" %}\nSecret\n{% /audience %}"},
         "writer_not_in_scope_group"},
        {%{
           "body" => """
           {% audience scope="principal:#{principal_uid}" %}
           private
           ~~~markdoc
           {% /audience %}
           ~~~
           tail
           """
         }, "unclosed_audience_tag"}
      ]

      for {attrs, code} <- cases do
        assert code ==
                 conn
                 |> api(:post, "/api/v2/brain/objects", object_form(attrs))
                 |> error_code(422)
      end

      refute Repo.get_by(Object, slug: "notes/v2")
      conn |> api(:post, "/api/v2/brain/objects", object_form(%{})) |> document(201)

      assert "slug_taken" ==
               conn |> api(:post, "/api/v2/brain/objects", object_form(%{})) |> error_code(409)

      assert %{"errors" => [%{"source" => %{"pointer" => _}} | _]} =
               conn
               |> api(:post, "/api/v2/brain/objects", Map.delete(object_form(%{}), "title"))
               |> document(400)
    end

    test "a deleted object refuses edits and rollbacks until a restore", %{conn: conn} do
      {:ok, _} = SchemaPacks.install_packs([])
      {conn, _writer} = console_conn_with_principal(conn)
      conn |> api(:post, "/api/v2/brain/objects", object_form(%{})) |> document(201)
      original = object_page(conn, "notes/v2")

      update = %{
        "slug" => "notes/v2",
        "title" => "Revised",
        "body" => "Revised body.",
        "meta" => %{},
        "expected_content_hash" => original["content_hash"]
      }

      conn |> api(:patch, "/api/v2/brain/objects", update) |> document(200)
      object = Repo.get_by!(Object, slug: "notes/v2")
      [version] = Repo.all(from(v in ObjectVersion, where: v.object_id == ^object.id))

      assert %{"deleted_at" => deleted_at} =
               conn
               |> api(:post, "/api/v2/brain/objects/forget", %{
                 "slug" => "notes/v2",
                 "reason" => "Obsolete"
               })
               |> document(201)

      assert is_binary(deleted_at)
      deleted = Repo.reload!(object)
      assert deleted.meta["forgotten_by"] == "console admin"

      assert "object_deleted" ==
               conn
               |> api(:post, "/api/v2/brain/objects/rollback", %{
                 "slug" => "notes/v2",
                 "version_id" => version.id
               })
               |> error_code(409)

      Ankole.DataCase.assert_persisted_equal(Repo.reload!(object), deleted)

      assert [%{"slug" => "notes/v2"}] =
               conn |> api(:get, "/api/v2/brain/objects?deleted=true") |> records()

      assert %{"deleted_at" => nil} =
               conn
               |> api(:post, "/api/v2/brain/objects/restore", %{"slug" => "notes/v2"})
               |> document(201)

      assert %{"slug" => "notes/v2"} =
               conn
               |> api(:post, "/api/v2/brain/objects/rollback", %{
                 "slug" => "notes/v2",
                 "version_id" => version.id
               })
               |> document(201)

      assert Repo.reload!(object).body == "Body."

      assert "forget_reason_required" ==
               conn
               |> api(:post, "/api/v2/brain/objects/forget", %{
                 "slug" => "notes/v2",
                 "reason" => " "
               })
               |> error_code(422)
    end

    test "an edit repairs one stored invalid body", %{conn: conn} do
      {:ok, _result} = SchemaPacks.install_packs([])
      {conn, principal_uid} = console_conn_with_principal(conn)

      invalid_body = """
      {% audience scope="principal:#{principal_uid}" %}
      private
      ~~~markdoc
      {% /audience %}
      ~~~
      tail
      """

      object = insert_object!("notes/repair", %{body: invalid_body, content_hash: "invalid"})

      update = %{
        "slug" => object.slug,
        "title" => object.title,
        "body" => invalid_body,
        "meta" => %{},
        "expected_content_hash" => "invalid"
      }

      assert "unclosed_audience_tag" ==
               conn |> api(:patch, "/api/v2/brain/objects", update) |> error_code(422)

      repaired_body = """
      {% audience scope="principal:#{principal_uid}" %}
      private
      {% /audience %}
      """

      conn
      |> api(:patch, "/api/v2/brain/objects", %{update | "body" => repaired_body})
      |> document(200)

      assert Repo.reload!(object).body == repaired_body
      assert chunk_scopes(object) == ["principal:#{principal_uid}"]
    end

    test "fork moves a Library page into instance ownership", %{conn: conn} do
      {conn, _uid} = console_conn_with_principal(conn)
      now = DateTime.utc_now(:microsecond)

      {:ok, source} =
        Ankole.Ash.create(Source, :register, %{
          upstream_id: "json-api-fork-library",
          kind: "library",
          name: "Fork library",
          default_audience_scope: "world",
          config: %{},
          created_at: now
        })

      insert_projection!(source, "concepts/json-api-fork", now)

      assert [%{"managed_by_source_id" => source_id}] =
               conn |> api(:get, "/api/v2/brain/objects?prefix=concepts/json-api") |> records()

      assert source_id == source.id

      assert %{"managed_by_source_id" => nil} =
               conn
               |> api(:post, "/api/v2/brain/objects/fork", %{"slug" => "concepts/json-api-fork"})
               |> document(201)
    end

    test "object search filters before the list limit and treats wildcards literally", %{
      conn: conn
    } do
      {conn, _principal_uid} = console_conn_with_principal(conn)

      targets = %{
        "RARE%20OBJECT" => insert_object!("zz/rare-object", %{title: "Rare object"}),
        "%25" => insert_object!("zz/percent-literal", %{title: "Budget is 20% complete"}),
        "_" => insert_object!("zz/underscore-literal", %{title: "part_number"}),
        "%5C" => insert_object!("zz/backslash-literal", %{title: "path\\segment"})
      }

      insert_object!("zz/percent-decoy", %{title: "Budget is 201 complete"})
      insert_object!("zz/underscore-decoy", %{title: "partXnumber"})
      insert_object!("zz/backslash-decoy", %{title: "pathsegment"})
      for index <- 1..100, do: insert_object!("notes/object-search-fill-#{index}")

      unfiltered = conn |> api(:get, "/api/v2/brain/objects") |> records()
      assert length(unfiltered) == 100
      refute Enum.any?(unfiltered, &(&1["slug"] == "zz/rare-object"))

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
          other.uid
        )

      claim = write_fact!(object, other.uid, %{audience_scope: "principal:#{other.uid}"})

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
        |> api(:get, "/api/v2/brain/claims?object_slug=notes%2Fclaims&status=current")
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
            object_slug: object.slug,
            claim: "The deal closes",
            kind: "bet",
            holder: "world",
            audience_scope: "world",
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
          object_slug: object.slug,
          claim: claim,
          kind: "fact",
          holder: "world",
          audience_scope: "world",
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
      insert_object!("companies/acme", %{title: "Acme", type: "company"})

      {:ok, suggestion} =
        Ankole.Ash.create(MergeSuggestion, :suggest, %{
          id: UUIDv7.autogenerate(),
          a_slug: "companies/acme",
          b_slug: "companies/gone",
          reason: "same name",
          created_at: DateTime.utc_now(:microsecond)
        })

      assert [listed] = conn |> api(:get, "/api/v2/brain/merge-suggestions") |> records()

      assert listed["a_page"] == %{
               "slug" => "companies/acme",
               "title" => "Acme",
               "type" => "company"
             }

      assert listed["b_page"] == %{"slug" => "companies/gone", "title" => nil, "type" => nil}

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

      scope = "principal:#{principal_uid}"

      assert %{"default_audience_scope" => ^scope} =
               conn
               |> api(:patch, "/api/v2/brain/sources/#{oidc.id}", %{"scope" => scope})
               |> document(200)

      conn
      |> api(:patch, "/api/v2/brain/sources/#{oidc.id}", %{"scope" => nil})
      |> document(200)

      assert Repo.get!(Source, oidc.id).default_audience_scope == nil

      conn
      |> api(:patch, "/api/v2/brain/sources/#{oidc.id}", %{"scope" => "group:missing"})
      |> document(422)

      assert Repo.get!(Source, oidc.id).default_audience_scope == nil

      assert {:ok, true} = Ankole.AppConfigure.put_global_by_key("brain.enabled", true)
      [url_source] = Repo.all(from(source in Source, where: source.kind == "url"))

      assert %{"success" => true} =
               conn
               |> api(:post, "/api/v2/brain/sources/#{url_source.id}/learn")
               |> document(201)

      assert length(conn |> api(:get, "/api/v2/brain/sources") |> records()) == 2
    end

    test "archiving a Library Source withdraws its managed pages", %{conn: conn} do
      {conn, _principal_uid} = console_conn_with_principal(conn)
      now = DateTime.utc_now(:microsecond)

      {:ok, source} =
        Ankole.Ash.create(Source, :register, %{
          upstream_id: "json-api-archive-library",
          kind: "library",
          name: "Archive library",
          default_audience_scope: "world",
          config: %{},
          created_at: now
        })

      object = insert_projection!(source, "concepts/json-api-archive", now)

      assert %{"archived_at" => archived_at} =
               conn
               |> api(:post, "/api/v2/brain/sources/#{source.id}/archive")
               |> document(201)

      assert is_binary(archived_at)
      assert Repo.get!(Object, object.id).deleted_at != nil

      assert "not_found" ==
               conn
               |> api(:post, "/api/v2/brain/sources/#{UUIDv7.autogenerate()}/archive")
               |> error_code(404)

      assert "not_found" ==
               conn
               |> api(:post, "/api/v2/brain/objects/restore", %{"slug" => "notes/missing"})
               |> error_code(404)
    end
  end

  test "a site administrator in another tenant writes with its own attribution", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, admin_uid} = console_conn_with_principal(conn)
    other = Ankole.DataCase.create_tenant()
    Repo.with_tenant(other.id, fn -> assert {:ok, _} = SchemaPacks.install_packs([]) end)
    headers = [{"x-ankole-tenant", other.id}]

    conn
    |> api(:post, "/api/v2/brain/objects", object_form(%{"slug" => "notes/admin-edit"}), headers)
    |> document(201)

    page =
      conn
      |> api(:get, ~p"/api/v2/brain/objects/show?slug=notes%2Fadmin-edit", nil, headers)
      |> json_response(200)
      |> Map.fetch!("object")

    conn
    |> api(
      :patch,
      "/api/v2/brain/objects",
      %{
        "slug" => "notes/admin-edit",
        "title" => "Revised admin edit",
        "body" => page["body"],
        "meta" => page["meta"],
        "expected_content_hash" => page["content_hash"]
      },
      headers
    )
    |> document(200)

    assert [%{"author" => author}] =
             conn
             |> api(:get, "/api/v2/brain/object-versions?slug=notes%2Fadmin-edit", nil, headers)
             |> records()

    assert author == %{"tenant_id" => tenant.id, "uid" => admin_uid}
  end

  defp insert_projection!(source, slug, now) do
    {:ok, object} =
      Repo.transact(fn ->
        Ankole.Ash.create(Object, :create_projection, %{
          id: UUIDv7.autogenerate(),
          slug: slug,
          type: "concept",
          title: slug,
          body: "Managed body",
          meta: %{},
          managed_by_source_id: source.id,
          created_at: now,
          updated_at: now
        })
      end)

    object
  end
end
