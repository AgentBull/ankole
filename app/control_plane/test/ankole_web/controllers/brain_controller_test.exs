defmodule AnkoleWeb.BrainControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Registry
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Brain.Chunks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "manual Dreaming uses the scheduled worker and reuses pending rounds", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    assert {:ok, true} = AppConfigure.put_global_by_key("brain.enabled", true)
    cron = Ankole.Brain.Config.dreaming_task_cron()
    worker = Ankole.Brain.Jobs.Dreaming
    worker_name = Oban.Worker.to_string(worker)

    assert %{"result" => %{"status" => "enqueued"}} =
             conn |> api(:post, ~p"/api/v2/brain/dream") |> json_response(201)

    job = Repo.one!(from(job in Oban.Job, where: job.worker == ^worker_name))
    assert job.state == "available"
    assert job.args == %{"tenant_id" => Repo.tenant_id!()}

    assert %{"result" => %{"status" => "already_pending"}} =
             conn |> recycle_api() |> api(:post, ~p"/api/v2/brain/dream") |> json_response(201)

    Repo.update!(Ecto.Changeset.change(job, state: "executing"))

    assert %{"result" => %{"status" => "already_pending"}} =
             conn |> recycle_api() |> api(:post, ~p"/api/v2/brain/dream") |> json_response(201)

    assert {:ok, %{id: id, conflict?: true}} = Oban.insert(worker.new(%{}))
    assert id == job.id
    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^worker_name), :count) == 1
    assert Ankole.Brain.Config.dreaming_task_cron() == cron
  end

  test "manual Dreaming requires Brain update permission", %{conn: conn} do
    {conn, principal_uid} = console_conn_with_principal(conn)

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

    assert conn |> recycle_api() |> api(:get, ~p"/api/v2/brain/health") |> response(200)

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             conn |> recycle_api() |> api(:post, ~p"/api/v2/brain/dream") |> json_response(403)

    worker = Oban.Worker.to_string(Ankole.Brain.Jobs.Dreaming)
    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^worker), :count) == 0
  end

  test "manual Dreaming rejects a disabled Brain and unauthenticated callers", %{conn: conn} do
    assert conn |> api(:post, ~p"/api/v2/brain/dream") |> response(401)
    {conn, _principal_uid} = console_conn_with_principal(conn)
    assert {:ok, false} = AppConfigure.put_global_by_key("brain.enabled", false)

    assert %{"errors" => [%{"detail" => "Brain is disabled"}]} =
             conn |> api(:post, ~p"/api/v2/brain/dream") |> json_response(422)

    worker = Oban.Worker.to_string(Ankole.Brain.Jobs.Dreaming)
    assert Repo.aggregate(from(job in Oban.Job, where: job.worker == ^worker), :count) == 0
  end

  test "health reports effective Pod profiles and an unconfigured web fetch", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "brain-health-provider",
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, "light", %{
               provider_id: "brain-health-provider",
               model: "light-model"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, "heavy", %{
               provider_id: "brain-health-provider",
               model: "heavy-model"
             })

    assert %{"health" => health} =
             conn
             |> api(:get, ~p"/api/v2/brain/health")
             |> json_response(200)

    refute Map.has_key?(health, "maintainer_agent_uid")

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

    assert %{"health" => health} =
             conn |> api(:get, ~p"/api/v2/brain/health") |> json_response(200)

    assert health["grading"] == %{
             "status" => "skipped",
             "reason" => "dreaming_model_not_configured"
           }
  end

  test "health keeps Pod profiles available when every Agent is disabled", %{conn: conn} do
    {conn, _principal_uid} = console_conn_with_principal(conn)
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "brain-health-independent",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    for profile <- ["light", "heavy"] do
      assert {:ok, _profile} =
               ModelProfiles.put_default_model_profile(:tenant, profile, %{
                 provider_id: "brain-health-independent",
                 model: "pod-model"
               })
    end

    assert {:ok, %{status: :disabled}} =
             Ankole.PrincipalsFixtures.disable_principal_fixture(agent.uid)

    assert %{"health" => health} =
             conn
             |> api(:get, ~p"/api/v2/brain/health")
             |> json_response(200)

    refute Map.has_key?(health, "maintainer_agent_uid")

    for model <- ["extraction", "dreaming"] do
      assert health["models"][model]["configured"] == true
      assert health["models"][model]["model"] == "pod-model"
      assert health["models"][model]["provider_available"] == true
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
          |> api(:get, ~p"/api/v2/brain/health")
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

  test "search preview applies the selected Principal's knowledge and disclosure boundary", %{
    conn: conn
  } do
    {:ok, _} = Ankole.Brain.SchemaPacks.install_packs([])
    {conn, writer_uid} = console_conn_with_principal(conn)
    %{principal: member} = human_fixture()
    %{principal: outsider} = human_fixture()

    {:ok, object} =
      Ankole.Brain.create_object(
        %{
          slug: "notes/zirconium-preview",
          type: "note",
          title: "Zirconium preview",
          body: "Zirconium public research passage."
        },
        writer_uid
      )

    {:ok, %{claim: claim}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: object.slug,
          claim: "Zirconium confidential plan",
          kind: "fact",
          holder: "people/#{member.uid}",
          audience_scope: "principal:#{member.uid}",
          notability: "high",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "Console preview test"
        },
        writer_uid
      )

    preview = fn uid, extra ->
      conn
      |> api(
        :post,
        ~p"/api/v2/brain/search-preview",
        Map.merge(%{principal_uid: uid, query: "Zirconium"}, extra)
      )
      |> json_response(201)
      |> Map.fetch!("result")
    end

    member_result = preview.(member.uid, %{})
    assert Enum.any?(member_result["claims"], &(&1["id"] == claim.id))
    assert Enum.any?(member_result["chunks"], &(&1["object_slug"] == object.slug))
    refute Enum.any?(preview.(outsider.uid, %{})["claims"], &(&1["id"] == claim.id))

    refute Enum.any?(
             preview.(member.uid, %{disclosure_mode: "strict", present_uids: [outsider.uid]})[
               "claims"
             ],
             &(&1["id"] == claim.id)
           )

    audit =
      conn
      |> api(:get, ~p"/api/v2/brain/principals/#{member.uid}/knowledge")
      |> json_response(200)

    assert %{
             "claim" => "Zirconium confidential plan",
             "provenance" => "Console preview test",
             "confidence" => 0.9
           } = Enum.find(audit["claims"], &(&1["id"] == claim.id))
  end

  defp api(conn, method, path, data \\ nil) do
    conn =
      if get_req_header(conn, "x-csrf-token") == [], do: recycle(conn), else: recycle_api(conn)

    conn =
      conn
      |> delete_req_header("content-type")
      |> put_req_header("accept", "application/vnd.api+json")

    conn =
      if data, do: put_req_header(conn, "content-type", "application/vnd.api+json"), else: conn

    dispatch(conn, @endpoint, method, path, data && Jason.encode!(%{data: data}))
  end
end
