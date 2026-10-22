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
  alias Ankole.Brain.Chunks
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
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "review list filters reject invalid states without exposing resource internals", %{
    conn: conn
  } do
    {conn, _} = console_conn_with_principal(conn)

    for path <- [
          "/api/v1/brain/suggestions",
          "/api/v1/brain/merge-suggestions",
          "/api/v1/brain/contradictions"
        ] do
      response =
        conn |> recycle_api() |> get(path <> "?status=unknown-state") |> json_response(422)

      assert response["error"]["code"] == "validation_failed"
      encoded = Torque.encode!(response)
      refute encoded =~ "Ash."
      refute encoded =~ "Ankole."
      refute encoded =~ "SELECT"
    end
  end

  test "Console promotion decisions preserve the review record and its actor", %{conn: conn} do
    {conn, admin_uid} = console_conn_with_principal(conn)

    {:ok, suggestion} =
      Ankole.Ash.create(Ankole.Brain.Schemas.SchemaSuggestion, :suggest, %{
        id: UUIDv7.autogenerate(),
        kind: :new_type,
        term: "review-test",
        evidence_count: 100,
        rationale: "Persisted evidence",
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

  test "a console writer cannot supersede another person's private fact", %{conn: conn} do
    {conn, _admin_uid} = console_conn_with_principal(conn)
    %{principal: other} = human_fixture()
    assert {:ok, _} = SchemaPacks.install_packs([])

    assert {:ok, object} =
             Ankole.Brain.create_object(
               %{slug: "notes/private", type: "note", title: "Private"},
               other.uid
             )

    assert {:ok, %{claim: claim}} =
             Ankole.Brain.write_fact(
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
    assert %{"error" => %{"code" => "writer_not_in_claim_scope"}} = json_response(response, 422)
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
      version = Repo.one!(from(version in ObjectVersion, where: version.object_id == ^object.id))

      assert version.author ==
               Ankole.ActorRef.from_principal(%{tenant_id: tenant.id, uid: admin_uid})
    end)
  end

  test "claim search filters before the list limit and treats wildcards literally", %{conn: conn} do
    {conn, principal_uid} = console_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    {:ok, object} =
      Repo.transact(fn ->
        Ankole.Ash.create(Object, :create, %{
          id: UUIDv7.autogenerate(),
          slug: "notes/claim-search",
          type: "note",
          title: "Claim search",
          body: "",
          meta: %{},
          created_at: now,
          updated_at: now
        })
      end)

    row = fn claim, created_at ->
      %{
        id: UUIDv7.autogenerate(),
        tenant_id: Repo.tenant_id!(),
        author:
          Ankole.ActorRef.from_principal(Repo.get!(Ankole.Principals.Principal, principal_uid)),
        claim_type: :fact,
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

  test "OIDC Source default audience can be configured and reset through the Console", %{
    conn: conn
  } do
    {conn, principal_uid} = console_conn_with_principal(conn)

    {:ok, source} =
      Ankole.Brain.Sources.create(%{
        kind: "oidc_client",
        upstream_id: UUIDv7.autogenerate(),
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

    {:ok, source} =
      Ankole.Ash.create(Source, :register, %{
        upstream_id: "controller-archive-library",
        kind: "library",
        name: "Controller archive library",
        default_audience_scope: "world",
        config: %{},
        created_at: now
      })

    {:ok, object} =
      Repo.transact(fn ->
        Ankole.Ash.create(Object, :create_projection, %{
          id: UUIDv7.autogenerate(),
          slug: "concepts/controller-archive-library",
          type: "concept",
          title: "Controller archive library",
          body: "Managed body",
          meta: %{},
          managed_by_source_id: source.id,
          created_at: now,
          updated_at: now
        })
      end)

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

    job = Repo.one!(from(job in Oban.Job, where: job.worker == ^worker_name))
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
    Repo.delete_all(from(grant in Ankole.AuthZ.Grant, where: grant.resource_pattern == "**"))

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
    assert health["grading"] == %{"status" => "ready", "reason" => nil}

    # A URL source learns only through the `web_fetch` profile; nothing falls
    # back to a Worker browser.
    assert health["models"]["web_fetch"] == %{"configured" => false, "profile" => "web_fetch"}
  end

  test "health reports that grading is skipped without a Dreaming model", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)

    assert %{"health" => health} = conn |> get(~p"/api/v1/brain/health") |> json_response(200)

    assert health["grading"] == %{
             "status" => "skipped",
             "reason" => "dreaming_model_not_configured"
           }
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

    {:ok, object} =
      Repo.transact(fn ->
        Ankole.Ash.create(Object, :create, %{
          id: UUIDv7.autogenerate(),
          slug: "notes/health-internal-error",
          type: "note",
          title: "Health internal error",
          body: "Projection source",
          meta: %{},
          created_at: now,
          updated_at: now
        })
      end)

    assert {:ok, chunk} =
             Repo.transact(fn ->
               Ankole.Ash.create(Chunk, :project, %{
                 object_id: object.id,
                 chunk_index: 0,
                 content_kind: :body,
                 audience_scope: "world",
                 chunk_text: object.body,
                 token_count: 2
               })
             end)

    assert {:ok, :updated} =
             Chunks.record_embedding(chunk, {:error, internal_reason, "failed-signature"})

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
