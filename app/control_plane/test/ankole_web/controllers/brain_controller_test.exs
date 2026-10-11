defmodule AnkoleWeb.BrainControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import Ankole.PrincipalsFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "Console promotion decisions preserve the review record and its actor", %{conn: conn} do
    {conn, admin_uid} = console_conn_with_principal(conn)

    suggestion =
      Repo.insert!(%Ankole.Brain.Schemas.SchemaSuggestion{
        id: UUIDv7.autogenerate(),
        kind: "new_type",
        term: "review-test",
        evidence_count: 100,
        rationale: "Persisted evidence",
        status: "pending",
        created_at: DateTime.utc_now(:microsecond)
      })

    result =
      conn
      |> post(~p"/api/v1/brain/suggestions/#{suggestion.id}/decide", %{"decision" => "reject"})
      |> json_response(200)

    assert result["result"]["status"] == "rejected"
    reviewed = Repo.get!(Ankole.Brain.Schemas.SchemaSuggestion, suggestion.id)
    assert reviewed.decided_by.uid == admin_uid
    assert reviewed.decided_at
    assert reviewed.rationale == "Persisted evidence"

    response =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/brain/suggestions?status=rejected")
      |> json_response(200)

    assert hd(response["suggestions"])["id"] == suggestion.id
  end

  test "a console writer cannot file into a group it does not belong to", %{conn: conn} do
    {conn, _admin_uid} = console_conn_with_principal(conn)
    assert {:ok, _} = SchemaPacks.install_packs([])

    assert {:ok, _} =
             Ankole.AuthZ.create_principal_group(%{
               name: "restricted",
               display_name: "Restricted"
             })

    response =
      post(conn, ~p"/api/v1/brain/objects", %{
        "slug" => "notes/restricted",
        "type" => "note",
        "title" => "Restricted",
        "body" => "{% audience scope=\"group:restricted\" %}\nSecret\n{% /audience %}",
        "meta" => %{}
      })

    assert %{"error" => %{"details" => [%{"reason" => reason}]}} = json_response(response, 422)
    assert reason =~ "writer_not_in_scope_group"
    refute Repo.get_by(Object, slug: "notes/restricted")
  end

  test "a console writer cannot supersede another person's private fact", %{conn: conn} do
    {conn, _admin_uid} = console_conn_with_principal(conn)
    %{principal: other} = human_fixture()
    assert {:ok, _} = SchemaPacks.install_packs([])

    assert {:ok, object} =
             Objects.create_object(
               %{slug: "notes/private", type: "note", title: "Private"},
               other.uid
             )

    assert {:ok, %{claim: claim}} =
             Ankole.Brain.Claims.write_fact(
               %{
                 object_slug: object.slug,
                 claim: "Private original",
                 kind: "fact",
                 holder: "world",
                 audience_scope: "principal:#{other.uid}",
                 notability: "medium",
                 valid_from: DateTime.utc_now(),
                 confidence: 0.75,
                 provenance: "review"
               },
               other.uid
             )

    response = post(conn, ~p"/api/v1/brain/claims/#{claim.id}/supersede", %{"claim" => "Changed"})
    assert %{"error" => %{"details" => [%{"reason" => reason}]}} = json_response(response, 422)
    assert reason =~ "writer_not_in_claim_scope"
    refute Repo.reload!(claim).superseded_by
  end

  test "a site admin writing in another tenant retains its own attribution", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, admin_uid} = console_conn_with_principal(conn)
    other = Ankole.DataCase.create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:ok, _} = SchemaPacks.install_packs([])

      assert {:ok, _} =
               Ankole.AuthZ.create_principal_group(%{
                 name: "restricted",
                 display_name: "Restricted"
               })
    end)

    response =
      conn
      |> put_req_header("x-ankole-tenant", other.id)
      |> post(
        ~p"/api/v1/brain/objects",
        %{
          "slug" => "notes/admin-edit",
          "type" => "note",
          "title" => "Admin edit",
          "body" => "{% audience scope=\"group:restricted\" %}\nSecret\n{% /audience %}",
          "meta" => %{}
        }
      )

    assert %{"object" => created} = json_response(response, 200)

    assert %{"object" => _} =
             conn
             |> recycle_api()
             |> put_req_header("x-ankole-tenant", other.id)
             |> put(~p"/api/v1/brain/objects", %{
               "slug" => "notes/admin-edit",
               "title" => "Revised admin edit",
               "body" => created["body"],
               "meta" => created["meta"],
               "expected_content_hash" => created["content_hash"]
             })
             |> json_response(200)

    versions_response =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", other.id)
      |> get(~p"/api/v1/brain/objects/versions?slug=notes/admin-edit")
      |> json_response(200)

    assert %{"versions" => [%{"author" => author} | _]} = versions_response
    assert_schema(versions_response, "BrainObjectVersionsResponse", AnkoleWeb.APISpec.spec())
    assert author == %{"tenant_id" => tenant.id, "uid" => admin_uid}

    Repo.with_tenant(other.id, fn ->
      object = Repo.get_by!(Object, slug: "notes/admin-edit")
      version = Repo.one!(from version in ObjectVersion, where: version.object_id == ^object.id)

      assert version.author ==
               Ankole.ActorRef.from_principal(%{tenant_id: tenant.id, uid: admin_uid})
    end)
  end

  test "claim search filters before the list limit and treats wildcards literally", %{conn: conn} do
    {conn, principal_uid} = console_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    object =
      Repo.insert!(%Object{
        id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        slug: "notes/claim-search",
        type: "note",
        title: "Claim search",
        body: "",
        meta: %{},
        created_at: now,
        updated_at: now
      })

    row = fn claim, created_at ->
      %{
        id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        author:
          Ankole.ActorRef.from_principal(Repo.get!(Ankole.Principals.Principal, principal_uid)),
        claim_type: "fact",
        object_slug: object.slug,
        claim: claim,
        kind: "fact",
        holder: "world",
        audience_scope: "world",
        notability: "medium",
        valid_from: now,
        confidence: 0.75,
        provenance: "controller test",
        created_at: created_at,
        updated_at: created_at
      }
    end

    target = row.("Rare claim beyond the first page", DateTime.add(now, -1, :day))

    fillers =
      for index <- 1..100 do
        row.("Common claim #{index}", DateTime.add(now, index, :microsecond))
      end

    percent_target = row.("Budget is 20% complete", DateTime.add(now, -2, :day))
    percent_decoy = row.("Budget is 201 complete", DateTime.add(now, -3, :day))
    underscore_target = row.("part_number", DateTime.add(now, -4, :day))
    underscore_decoy = row.("partXnumber", DateTime.add(now, -5, :day))
    backslash_target = row.("path\\segment", DateTime.add(now, -6, :day))
    backslash_decoy = row.("pathsegment", DateTime.add(now, -7, :day))

    {107, nil} =
      Repo.insert_all(Claim, [
        target,
        percent_target,
        percent_decoy,
        underscore_target,
        underscore_decoy,
        backslash_target,
        backslash_decoy
        | fillers
      ])

    assert %{"claims" => unfiltered} =
             conn
             |> get(~p"/api/v1/brain/claims")
             |> json_response(200)

    assert length(unfiltered) == 100
    refute Enum.any?(unfiltered, &(&1["id"] == target.id))

    assert %{"claims" => [%{"id" => target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=RARE%20CLAIM")
             |> json_response(200)

    assert target_id == target.id

    assert %{"claims" => [%{"id" => percent_target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=%25")
             |> json_response(200)

    assert percent_target_id == percent_target.id

    assert %{"claims" => [%{"id" => underscore_target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=_")
             |> json_response(200)

    assert underscore_target_id == underscore_target.id

    assert %{"claims" => [%{"id" => backslash_target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=%5C")
             |> json_response(200)

    assert backslash_target_id == backslash_target.id
  end

  test "object search filters before the list limit and treats wildcards literally", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    row = fn slug, title ->
      %{
        id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        slug: slug,
        type: "note",
        title: title,
        body: "",
        meta: %{},
        created_at: now,
        updated_at: now
      }
    end

    target = row.("zz/rare-object", "Rare object beyond the first page")
    percent_target = row.("zz/percent-literal", "Budget is 20% complete")
    percent_decoy = row.("zz/percent-decoy", "Budget is 201 complete")
    underscore_target = row.("zz/underscore-literal", "part_number")
    underscore_decoy = row.("zz/underscore-decoy", "partXnumber")
    backslash_target = row.("zz/backslash-literal", "path\\segment")
    backslash_decoy = row.("zz/backslash-decoy", "pathsegment")

    fillers =
      for index <- 1..100 do
        row.("notes/object-search-fill-#{index}", "Common object #{index}")
      end

    {107, nil} =
      Repo.insert_all(Object, [
        target,
        percent_target,
        percent_decoy,
        underscore_target,
        underscore_decoy,
        backslash_target,
        backslash_decoy
        | fillers
      ])

    assert %{"objects" => unfiltered} =
             conn
             |> get(~p"/api/v1/brain/objects")
             |> json_response(200)

    assert length(unfiltered) == 100
    refute Enum.any?(unfiltered, &(&1["slug"] == target.slug))

    assert %{"objects" => [%{"slug" => target_slug}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/objects?q=RARE%20OBJECT")
             |> json_response(200)

    assert target_slug == target.slug

    assert %{"objects" => [%{"slug" => percent_target_slug}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/objects?q=%25")
             |> json_response(200)

    assert percent_target_slug == percent_target.slug

    assert %{"objects" => [%{"slug" => underscore_target_slug}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/objects?q=_")
             |> json_response(200)

    assert underscore_target_slug == underscore_target.slug

    assert %{"objects" => [%{"slug" => backslash_target_slug}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/objects?q=%5C")
             |> json_response(200)

    assert backslash_target_slug == backslash_target.slug
  end

  test "the Object API creates, loads, and CAS-updates raw Markdoc bodies", %{conn: conn} do
    {:ok, _result} = SchemaPacks.install_packs([])
    {conn, principal_uid} = console_conn_with_principal(conn)
    %{principal: outsider} = human_fixture()

    body = """
    Public.
    {% audience scope="principal:#{principal_uid}" %}
    Private.
    {% /audience %}
    """

    assert %{"object" => created} =
             conn
             |> post(~p"/api/v1/brain/objects", %{
               "slug" => "notes/console-edit",
               "type" => "note",
               "subtype" => nil,
               "title" => "Console edit",
               "body" => body,
               "meta" => %{"source" => "console"},
               "effective_date" => "2026-08-30"
             })
             |> json_response(200)

    assert created["body"] == body
    assert created["editable"] == true
    assert created["edit_block_reason"] == nil
    assert created["content_hash"] != nil

    object = Repo.get_by!(Object, slug: "notes/console-edit")

    assert object
           |> object_chunk_scopes()
           |> Enum.sort() == ["principal:#{principal_uid}", "world"]

    assert {:ok, owner_page} = GetPage.get_page(principal_uid, object.slug)
    assert owner_page.rendered =~ "Public."
    assert owner_page.rendered =~ "Private."

    assert {:ok, outsider_page} = GetPage.get_page(outsider.uid, object.slug)
    assert outsider_page.rendered =~ "Public."
    refute outsider_page.rendered =~ "Private."

    assert %{"object" => loaded} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/objects/show?slug=notes%2Fconsole-edit")
             |> json_response(200)

    assert loaded["body"] == body

    updated_body = String.replace(body, "Private.", "Revised private.")

    assert %{"object" => updated} =
             conn
             |> recycle_api()
             |> put(~p"/api/v1/brain/objects", %{
               "slug" => "notes/console-edit",
               "subtype" => nil,
               "title" => "Console edit revised",
               "body" => updated_body,
               "meta" => %{"source" => "console"},
               "effective_date" => nil,
               "expected_content_hash" => created["content_hash"]
             })
             |> json_response(200)

    assert updated["body"] == updated_body
    assert updated["content_hash"] != created["content_hash"]

    assert Repo.aggregate(
             from(version in ObjectVersion, where: version.object_id == ^object.id),
             :count
           ) == 1

    assert object
           |> object_chunk_scopes()
           |> Enum.sort() == ["principal:#{principal_uid}", "world"]

    assert %{"error" => %{"code" => "content_hash_conflict"}} =
             conn
             |> recycle_api()
             |> put(~p"/api/v1/brain/objects", %{
               "slug" => "notes/console-edit",
               "subtype" => nil,
               "title" => "Stale edit",
               "body" => body,
               "meta" => %{},
               "effective_date" => nil,
               "expected_content_hash" => created["content_hash"]
             })
             |> json_response(409)
  end

  defp object_chunk_scopes(object) do
    Chunk
    |> where([chunk], chunk.object_id == ^object.id)
    |> order_by([chunk], asc: chunk.chunk_index)
    |> Repo.all()
    |> Enum.map(& &1.audience_scope)
  end

  test "object writes name slug and type problems and the type list is readable", %{conn: conn} do
    {:ok, _result} = SchemaPacks.install_packs([])
    {conn, _principal_uid} = console_conn_with_principal(conn)

    base = %{
      "slug" => "notes/valid",
      "type" => "note",
      "subtype" => nil,
      "title" => "Valid",
      "body" => "Body.",
      "meta" => %{},
      "effective_date" => nil
    }

    assert %{"error" => %{"code" => "invalid_slug", "details" => [%{"path" => "slug"}]}} =
             conn
             |> post(~p"/api/v1/brain/objects", %{base | "slug" => "notes/bad slug"})
             |> json_response(422)

    assert %{"error" => %{"code" => "unknown_object_type", "details" => [type_detail]}} =
             conn
             |> recycle_api()
             |> post(~p"/api/v1/brain/objects", %{base | "type" => "made-up"})
             |> json_response(422)

    assert type_detail["path"] == "type"
    assert "note" in type_detail["installed_types"]

    assert %{"object" => _created} =
             conn
             |> recycle_api()
             |> post(~p"/api/v1/brain/objects", base)
             |> json_response(200)

    assert %{"error" => %{"code" => "slug_taken", "details" => [%{"path" => "slug"}]}} =
             conn
             |> recycle_api()
             |> post(~p"/api/v1/brain/objects", %{base | "title" => "Duplicate"})
             |> json_response(409)

    assert %{"types" => types} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/object-types")
             |> json_response(200)

    assert "note" in types
    refute "agent-skills" in types
  end

  test "the Object API returns the native Markdoc code and line", %{conn: conn} do
    {:ok, _result} = SchemaPacks.install_packs([])
    {conn, principal_uid} = console_conn_with_principal(conn)

    body = """
    {% audience scope="principal:#{principal_uid}" %}
    private
    ~~~markdoc
    {% /audience %}
    ~~~
    tail
    """

    assert %{
             "error" => %{
               "code" => "unclosed_audience_tag",
               "details" => [%{"line" => 1, "path" => "body"}]
             }
           } =
             conn
             |> post(~p"/api/v1/brain/objects", %{
               "slug" => "notes/invalid-markdoc",
               "type" => "note",
               "subtype" => nil,
               "title" => "Invalid Markdoc",
               "body" => body,
               "meta" => %{},
               "effective_date" => nil
             })
             |> json_response(422)

    refute Repo.get_by(Object, slug: "notes/invalid-markdoc")
  end

  test "the Object API exposes and repairs one stored invalid body", %{conn: conn} do
    {:ok, _result} = SchemaPacks.install_packs([])
    {conn, principal_uid} = console_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    invalid_body = """
    {% audience scope="principal:#{principal_uid}" %}
    private
    ~~~markdoc
    {% /audience %}
    ~~~
    tail
    """

    object =
      Repo.insert!(%Object{
        id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        slug: "notes/repair-invalid-markdoc",
        type: "note",
        title: "Repair invalid Markdoc",
        body: invalid_body,
        meta: %{},
        content_hash: Objects.content_hash("Repair invalid Markdoc", invalid_body, %{}),
        created_at: now,
        updated_at: now
      })

    assert %{"object" => %{"body" => ^invalid_body, "content_hash" => content_hash}} =
             conn
             |> get(~p"/api/v1/brain/objects/show?slug=notes%2Frepair-invalid-markdoc")
             |> json_response(200)

    assert %{"error" => %{"code" => "unclosed_audience_tag"}} =
             conn
             |> recycle_api()
             |> put(~p"/api/v1/brain/objects", %{
               "slug" => object.slug,
               "subtype" => nil,
               "title" => object.title,
               "body" => invalid_body,
               "meta" => %{},
               "effective_date" => nil,
               "expected_content_hash" => content_hash
             })
             |> json_response(422)

    repaired_body = """
    {% audience scope="principal:#{principal_uid}" %}
    private
    {% /audience %}
    """

    assert %{"object" => %{"body" => ^repaired_body}} =
             conn
             |> recycle_api()
             |> put(~p"/api/v1/brain/objects", %{
               "slug" => object.slug,
               "subtype" => nil,
               "title" => object.title,
               "body" => repaired_body,
               "meta" => %{},
               "effective_date" => nil,
               "expected_content_hash" => content_hash
             })
             |> json_response(200)

    assert object_chunk_scopes(object) == ["principal:#{principal_uid}"]
  end

  test "OIDC Source default audience can be configured and reset through the Console", %{
    conn: conn
  } do
    {conn, principal_uid} = console_conn_with_principal(conn)

    {:ok, source} =
      Ankole.Brain.Sources.create(%{
        kind: "oidc_client",
        upstream_id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        name: "OIDC Client"
      })

    assert %{"source" => %{"id" => source_id}} =
             conn
             |> patch(~p"/api/v1/brain/sources/#{source.id}", %{
               "default_audience_scope" => "principal:#{principal_uid}"
             })
             |> json_response(200)

    assert source_id == source.id
    assert Repo.get!(Source, source.id).default_audience_scope == "principal:#{principal_uid}"

    conn
    |> recycle()
    |> patch(~p"/api/v1/brain/sources/#{source.id}", %{"default_audience_scope" => nil})
    |> json_response(200)

    assert Repo.get!(Source, source.id).default_audience_scope == nil

    conn |> recycle() |> patch(~p"/api/v1/brain/sources/#{source.id}", %{}) |> json_response(422)

    conn
    |> recycle()
    |> patch(~p"/api/v1/brain/sources/#{source.id}", %{
      "default_audience_scope" => "group:missing"
    })
    |> json_response(422)

    assert Repo.get!(Source, source.id).default_audience_scope == nil
  end

  test "archiving a Library Source immediately withdraws its managed pages", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    source =
      Repo.insert!(%Source{
        upstream_id: "controller-archive-library",
        kind: "library",
        name: "Controller archive library",
        default_audience_scope: "world",
        config: %{},
        created_at: now,
        updated_at: now
      })

    object =
      Repo.insert!(%Object{
        id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        slug: "concepts/controller-archive-library",
        type: "concept",
        title: "Controller archive library",
        body: "Managed body",
        meta: %{},
        managed_by_source_id: source.id,
        created_at: now,
        updated_at: now
      })

    assert %{"source" => %{"id" => source_id, "archived_at" => archived_at}} =
             conn
             |> post(~p"/api/v1/brain/sources/#{source.id}/archive")
             |> json_response(200)

    assert source_id == source.id
    assert is_binary(archived_at)
    assert Repo.get!(Object, object.id).deleted_at != nil
  end

  test "manual Dreaming uses the scheduled worker and reuses pending rounds", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    assert {:ok, true} = AppConfigure.put_global_by_key("brain.enabled", true)
    cron = Ankole.Brain.Config.dreaming_task_cron()
    worker = Ankole.Brain.Jobs.Dreaming
    worker_name = Oban.Worker.to_string(worker)

    assert %{"result" => %{"status" => "enqueued"}} =
             conn |> post(~p"/api/v1/brain/dream") |> json_response(200)

    job = Repo.one!(from job in Oban.Job, where: job.worker == ^worker_name)
    assert job.state == "available"
    assert job.args == %{"tenant_id" => Repo.tenant_id!()}

    assert %{"result" => %{"status" => "already_pending"}} =
             conn |> recycle_api() |> post(~p"/api/v1/brain/dream") |> json_response(200)

    Repo.update!(Ecto.Changeset.change(job, state: "executing"))

    assert %{"result" => %{"status" => "already_pending"}} =
             conn |> recycle_api() |> post(~p"/api/v1/brain/dream") |> json_response(200)

    assert {:ok, %{id: id, conflict?: true}} = Oban.insert(worker.new(%{}))
    assert id == job.id
    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^worker_name), :count) == 1
    assert Ankole.Brain.Config.dreaming_task_cron() == cron
  end

  test "manual Dreaming requires Brain update permission", %{conn: conn} do
    {conn, principal_uid} = console_conn_with_principal(conn)
    Repo.delete_all(from grant in Ankole.AuthZ.Grant, where: grant.resource_pattern == "**")

    assert {:ok, _grant} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: principal_uid,
               resource_pattern: "brain",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert conn |> recycle_api() |> get(~p"/api/v1/brain/health") |> response(200)

    assert %{"error" => %{"code" => "forbidden"}} =
             conn |> recycle_api() |> post(~p"/api/v1/brain/dream") |> json_response(403)

    worker = Oban.Worker.to_string(Ankole.Brain.Jobs.Dreaming)
    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^worker), :count) == 0
  end

  test "manual Dreaming rejects a disabled Brain and unauthenticated callers", %{conn: conn} do
    assert conn |> post(~p"/api/v1/brain/dream") |> response(401)
    {conn, _principal_uid} = console_conn_with_principal(conn)
    assert {:ok, false} = AppConfigure.put_global_by_key("brain.enabled", false)

    assert %{"error" => %{"code" => "brain_disabled"}} =
             conn |> post(~p"/api/v1/brain/dream") |> json_response(422)

    worker = Oban.Worker.to_string(Ankole.Brain.Jobs.Dreaming)
    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^worker), :count) == 0
  end

  test "health reports maintainer Agent profiles and an unconfigured web fetch", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    %{principal: maintainer} = agent_fixture(%{display_name: "Brain Maintainer"})
    maintainer_uid = maintainer.uid

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "brain-health-provider",
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    assert {:ok, ^maintainer_uid} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", maintainer_uid)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(maintainer_uid, "light", %{
               provider_id: "brain-health-provider",
               model: "light-model"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(maintainer_uid, "heavy", %{
               provider_id: "brain-health-provider",
               model: "heavy-model"
             })

    assert %{"health" => health} =
             conn
             |> get(~p"/api/v1/brain/health")
             |> json_response(200)

    assert health["maintainer_agent_uid"] == maintainer_uid

    assert health["models"]["extraction"] == %{
             "configured" => true,
             "model" => "light-model",
             "profile" => "light",
             "provider_available" => true,
             "provider_id" => "brain-health-provider"
           }

    assert health["models"]["dreaming"]["model"] == "heavy-model"

    # A URL source learns only through the `web_fetch` profile; nothing falls
    # back to a Worker browser.
    assert health["models"]["web_fetch"] == %{"configured" => false, "profile" => "web_fetch"}
  end

  test "health reports a disabled maintainer Agent for every Brain profile", %{
    conn: conn
  } do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    %{principal: maintainer} = agent_fixture(%{display_name: "Disabled Brain Maintainer"})

    assert {:ok, maintainer_uid} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", maintainer.uid)

    assert maintainer_uid == maintainer.uid

    assert {:ok, %{status: :disabled}} =
             Ankole.PrincipalsFixtures.disable_principal_fixture(maintainer.uid)

    assert %{"health" => health} =
             conn
             |> get(~p"/api/v1/brain/health")
             |> json_response(200)

    assert health["maintainer_agent_uid"] == maintainer.uid

    for {model, profile} <- [
          {"web_fetch", "web_fetch"},
          {"extraction", "light"},
          {"dreaming", "heavy"}
        ] do
      assert health["models"][model] == %{
               "configured" => false,
               "profile" => profile,
               "profile_error" => "brain_maintainer_agent_disabled"
             }
    end
  end

  test "health keeps internal embedding failures in server logs", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    internal_reason =
      "{:provider_unavailable, credential_id: cred-secret-123, env: OPEN_ROUTER_API_KEY}"

    object =
      Repo.insert!(%Object{
        id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        slug: "notes/health-internal-error",
        type: "note",
        title: "Health internal error",
        body: "Projection source",
        meta: %{},
        created_at: now,
        updated_at: now
      })

    Repo.insert!(%Chunk{
      object_id: object.id,
      chunk_index: 0,
      content_kind: "body",
      audience_scope: "world",
      chunk_text: object.body,
      token_count: 2,
      embedding_signature: "failed-signature",
      embedding_error: internal_reason,
      created_at: now
    })

    assert {:ok, _value} =
             AppConfigure.put_global_by_key("brain.embedding_model", %{
               "provider_id" => "missing-provider",
               "model" => "embedding-model",
               "dimensions" => 8
             })

    test_process = self()

    log =
      capture_log([metadata: [:reason]], fn ->
        response =
          conn
          |> get(~p"/api/v1/brain/health")
          |> json_response(200)

        send(test_process, {:health_response, response})
      end)

    assert_receive {:health_response, %{"health" => health}}
    assert health["models"]["embedding"]["provider_error"] == "not_found"
    assert health["embedding_signature"]["error"] == "not_found"
    assert health["embeddings"]["recent_error"] == "internal_error"
    refute inspect(health) =~ "cred-secret-123"
    refute inspect(health) =~ "OPEN_ROUTER_API_KEY"
    assert log =~ internal_reason
  end
end
