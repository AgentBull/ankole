defmodule AnkoleWeb.BrainControllerTest do
  use AnkoleWeb.ConnCase, async: false

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
  alias Ankole.Principals
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

  test "claim search filters before the list limit and treats wildcards literally", %{conn: conn} do
    {conn, principal_uid} = bearer_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    object =
      Repo.insert!(%Object{
        id: UUIDv7.autogenerate(),
        slug: "notes/claim-search",
        type: "note",
        title: "Claim search",
        body: "",
        meta: %{},
        emotional_weight: 0.0,
        created_at: now,
        updated_at: now
      })

    row = fn claim, created_at ->
      %{
        id: UUIDv7.autogenerate(),
        author_uid: principal_uid,
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
    {conn, _principal_uid} = bearer_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    row = fn slug, title ->
      %{
        id: UUIDv7.autogenerate(),
        slug: slug,
        type: "note",
        title: title,
        body: "",
        meta: %{},
        emotional_weight: 0.0,
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
    {conn, principal_uid} = bearer_conn_with_principal(conn)
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
    {conn, _principal_uid} = bearer_conn_with_principal(conn)

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
    {conn, principal_uid} = bearer_conn_with_principal(conn)

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
    {conn, principal_uid} = bearer_conn_with_principal(conn)
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
        slug: "notes/repair-invalid-markdoc",
        type: "note",
        title: "Repair invalid Markdoc",
        body: invalid_body,
        meta: %{},
        emotional_weight: 0.0,
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

  test "archiving a Library Source immediately withdraws its managed pages", %{conn: conn} do
    {conn, _principal_uid} = bearer_conn_with_principal(conn)
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
        slug: "concepts/controller-archive-library",
        type: "concept",
        title: "Controller archive library",
        body: "Managed body",
        meta: %{},
        emotional_weight: 0.0,
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

  test "health reports maintainer Agent profiles and the local web-fetch fallback", %{conn: conn} do
    {conn, _principal_uid} = bearer_conn_with_principal(conn)
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

    assert health["models"]["web_fetch"] == %{
             "configured" => false,
             "fallback" => "ankole_browser",
             "profile" => "web_fetch"
           }
  end

  test "health reports a disabled maintainer Agent and withholds the local web-fetch fallback", %{
    conn: conn
  } do
    {conn, _principal_uid} = bearer_conn_with_principal(conn)
    %{principal: maintainer} = agent_fixture(%{display_name: "Disabled Brain Maintainer"})

    assert {:ok, maintainer_uid} =
             AppConfigure.put_global_by_key("brain.maintainer_agent_uid", maintainer.uid)

    assert maintainer_uid == maintainer.uid
    assert {:ok, %{status: :disabled}} = Principals.disable_principal(maintainer.uid)

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
    {conn, _principal_uid} = bearer_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    internal_reason =
      "{:provider_unavailable, credential_id: cred-secret-123, env: OPEN_ROUTER_API_KEY}"

    object =
      Repo.insert!(%Object{
        id: UUIDv7.autogenerate(),
        slug: "notes/health-internal-error",
        type: "note",
        title: "Health internal error",
        body: "Projection source",
        meta: %{},
        emotional_weight: 0.0,
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
