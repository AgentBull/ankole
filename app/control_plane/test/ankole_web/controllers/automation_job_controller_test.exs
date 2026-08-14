defmodule AnkoleWeb.AutomationJobControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import OpenApiSpex.TestAssertions

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.AutomationJobs
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin reads deployment instance jobs and bounded run history by job id", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    source = source_event!(agent.uid)
    other_source = source_event!(agent.uid)

    job = create_job!(agent.uid, source, "Console test consumer")
    other_session_job = create_job!(agent.uid, other_source, "Second session consumer")

    assert {:ok, %{automation_job_run: run}} =
             Repo.transact(fn repo ->
               AutomationJobs.enqueue_run_in_tx(
                 repo,
                 job.id,
                 agent.uid,
                 %{
                   "specversion" => "1.0",
                   "id" => "console-trigger",
                   "source" => "test://console",
                   "type" => "test.triggered",
                   "data" => %{}
                 }
               )
             end)

    assert {:ok, %{run: attempt}} = AutomationJobs.start_attempt(run.id)

    assert {:ok, _run} =
             AutomationJobs.finish_attempt(run.id, attempt.attempt_id, %{
               status: "succeeded",
               exit_code: 0,
               stdout: "checked",
               stderr: ""
             })

    api_spec = AnkoleWeb.APISpec.spec()
    conn = bearer_conn(conn)

    foreign_source = source_event!(other_agent.uid)
    foreign_job = create_job!(other_agent.uid, foreign_source, "Foreign consumer")

    everything =
      conn
      |> get(~p"/api/v1/automation-jobs")
      |> json_response(200)

    assert MapSet.new(everything["automation_jobs"], & &1["id"]) ==
             MapSet.new([job.id, other_session_job.id, foreign_job.id])

    list =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/automation-jobs?agent=#{agent.uid}")
      |> json_response(200)

    assert_schema(list, "AutomationJobListResponse", api_spec)
    assert %{"automation_jobs" => jobs} = list
    assert MapSet.new(jobs, & &1["id"]) == MapSet.new([job.id, other_session_job.id])

    assert MapSet.new(jobs, & &1["owner_session_id"]) ==
             MapSet.new([source.session_id, other_source.session_id])

    assert Enum.all?(jobs, &(&1["runs"] == []))

    detail =
      conn
      |> recycle_bearer()
      |> get(~p"/api/v1/agents/#{agent.uid}/automation-jobs/#{job.id}?runs=20")
      |> json_response(200)

    assert_schema(detail, "AutomationJobResponse", api_spec)
    assert get_in(detail, ["automation_job", "runs", Access.at(0), "status"]) == "succeeded"
    assert get_in(detail, ["automation_job", "runs", Access.at(0), "stdout"]) == "checked"

    assert conn
           |> recycle_bearer()
           |> get(~p"/api/v1/agents/#{agent.uid}/automation-jobs/9007199254740991")
           |> json_response(404)

    assert conn
           |> recycle_bearer()
           |> get(~p"/api/v1/agents/#{agent.uid}/automation-jobs/999")
           |> json_response(404)

    for invalid_id <- [0, 9_007_199_254_740_992] do
      assert %{"error" => %{"code" => "validation_failed"}} =
               conn
               |> recycle_bearer()
               |> get("/api/v1/agents/#{agent.uid}/automation-jobs/#{invalid_id}")
               |> json_response(422)
    end
  end

  test "missing bearer token is rejected", %{conn: conn} do
    assert conn
           |> get(~p"/api/v1/automation-jobs")
           |> json_response(401)
  end

  test "job detail requires the owning Agent read permission", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    job = create_job!(agent.uid, source_event!(agent.uid), "Permission test consumer")
    {conn, admin_uid} = bearer_conn_with_principal(conn)

    Repo.delete_all(from grant in Grant, where: grant.resource_pattern == "**")

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: admin_uid,
               resource_pattern: "agent:#{agent.uid}:automation_jobs",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert conn
           |> get(~p"/api/v1/agents/#{agent.uid}/automation-jobs/#{job.id}")
           |> json_response(200)

    Repo.delete_all(from grant in Grant, where: grant.principal_uid == ^admin_uid)

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: admin_uid,
               resource_pattern: "automation_jobs",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert %{"error" => %{"code" => "forbidden"}} =
             conn
             |> recycle_bearer()
             |> get(~p"/api/v1/agents/#{agent.uid}/automation-jobs/#{job.id}")
             |> json_response(403)

    Repo.delete_all(from grant in Grant, where: grant.principal_uid == ^admin_uid)

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: admin_uid,
               resource_pattern: "agent:#{other_agent.uid}:automation_jobs",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert %{"error" => %{"code" => "forbidden"}} =
             conn
             |> recycle_bearer()
             |> get(~p"/api/v1/agents/#{agent.uid}/automation-jobs/#{job.id}")
             |> json_response(403)
  end

  defp create_job!(agent_uid, source, label) do
    assert {:ok, job} =
             AutomationJobs.create_job(%{
               agent_uid: agent_uid,
               owner_session_id: source.session_id,
               source_actor_event_id: source.id,
               source_entry_id: source.source_entry_id,
               source_provenance: %{"kind" => "console-test"},
               reply_route: %{
                 "binding_name" => source.binding_name,
                 "signal_channel_id" => source.signal_channel_id
               },
               directory_path: "/agents/#{agent_uid}/automation/console-test",
               label: label,
               wake_on_failure: true
             })

    job
  end

  defp source_event!(agent_uid) do
    unique = System.unique_integer([:positive])

    {:ok, event} =
      SignalsGateway.append_actor_event(%{
        agent_uid: agent_uid,
        binding_name: "lark",
        session_id: "automation-console-#{unique}",
        source_event_id: "automation-console-source-#{unique}",
        signal_channel_id: "lark:chat:#{unique}",
        provider_thread_id: "thread-#{unique}",
        source_entry_id: "message-#{unique}",
        type: "im.message.addressed",
        available_at: DateTime.utc_now(:microsecond),
        sender_key: nil,
        payload: %{
          "specversion" => "1.0",
          "id" => "automation-console-source-#{unique}",
          "source" => "test://automation-console",
          "type" => "im.message.addressed",
          "data" => %{}
        }
      })

    event
  end

  defp bearer_conn(conn) do
    {conn, _principal_uid} = bearer_conn_with_principal(conn)
    conn
  end

  defp bearer_conn_with_principal(conn) do
    {conn, principal_uid} = active_admin_conn(conn)

    conn
    |> post(~p"/.internal-apis/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
    |> then(&{&1, principal_uid})
  end

  defp recycle_bearer(conn) do
    authorization = get_req_header(conn, "authorization") |> List.first()

    conn
    |> recycle()
    |> put_req_header("authorization", authorization)
    |> put_req_header("content-type", "application/json")
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("automation-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    session_conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_admin_session(%{
        principal_uid: human.principal.uid,
        provider_id: "lark-main",
        external_id: "external-1"
      })

    {session_conn, human.principal.uid}
  end
end
