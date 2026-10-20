defmodule AnkoleWeb.BrainObjectControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()
    {:ok, false} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), false)
    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
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

  test "Console tags preserve omitted values and clear only with an explicit empty list", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)
    assert {:ok, _} = SchemaPacks.install_packs([])

    form = %{
      "slug" => "notes/console-tags",
      "type" => "note",
      "title" => "Tagged",
      "body" => "Body",
      "meta" => %{},
      "tags" => [" research ", "research", "AI", "multi\nline", "literal\\ntext"]
    }

    assert %{"object" => created} =
             conn |> post(~p"/api/v1/brain/objects", form) |> json_response(200)

    assert created["tags"] == ["AI", "literal\\ntext", "multi\nline", "research"]

    update =
      form
      |> Map.delete("type")
      |> Map.delete("tags")
      |> Map.put("expected_content_hash", created["content_hash"])

    assert %{"object" => preserved} =
             conn |> recycle_api() |> put(~p"/api/v1/brain/objects", update) |> json_response(200)

    assert preserved["tags"] == created["tags"]

    clear =
      update |> Map.put("tags", []) |> Map.put("expected_content_hash", preserved["content_hash"])

    assert %{"object" => cleared} =
             conn |> recycle_api() |> put(~p"/api/v1/brain/objects", clear) |> json_response(200)

    assert cleared["tags"] == []
    refute cleared["content_hash"] == preserved["content_hash"]
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

  test "metadata conflicts and deleted writes are rejected at the Console API", %{conn: conn} do
    {:ok, _} = SchemaPacks.install_packs([])
    {conn, writer} = console_conn_with_principal(conn)

    form = %{
      "slug" => "notes/metadata-conflict",
      "type" => "note",
      "subtype" => "reference",
      "title" => "Metadata conflict",
      "body" => "Original body",
      "meta" => %{},
      "effective_date" => "2026-08-01"
    }

    %{"object" => original} = conn |> post(~p"/api/v1/brain/objects", form) |> json_response(200)
    stale = Map.put(form, "expected_content_hash", original["content_hash"])

    %{"object" => current} =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/brain/objects", Map.put(stale, "effective_date", "2026-08-02"))
      |> json_response(200)

    refute current["content_hash"] == original["content_hash"]

    assert %{"error" => %{"code" => "content_hash_conflict"}} =
             conn
             |> recycle_api()
             |> put(~p"/api/v1/brain/objects", Map.put(stale, "body", "Stale body"))
             |> json_response(409)

    object = Repo.get_by!(Object, slug: form["slug"])
    assert object.effective_date == ~D[2026-08-02]
    assert object.body == form["body"]
    [version] = Repo.all(from(v in ObjectVersion, where: v.object_id == ^object.id))
    {:ok, deleted} = Objects.soft_delete(object.slug, reason: "Obsolete", by: writer)

    assert %{"error" => %{"code" => "object_deleted"}} =
             conn
             |> recycle_api()
             |> put(
               ~p"/api/v1/brain/objects",
               Map.put(stale, "expected_content_hash", deleted.content_hash)
             )
             |> json_response(409)

    assert %{"error" => %{"code" => "object_deleted"}} =
             conn
             |> recycle_api()
             |> post(~p"/api/v1/brain/objects/rollback", %{
               "slug" => object.slug,
               "version_id" => version.id
             })
             |> json_response(409)

    assert Repo.get!(Object, object.id) == deleted
    assert Repo.all(from(v in ObjectVersion, where: v.object_id == ^object.id)) == [version]
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
        content_hash: "invalid-markdoc-fixture",
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
end
