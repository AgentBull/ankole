defmodule AnkoleWeb.JSONAPI.AutomationJobsTest do
  @moduledoc "Checks the automation job routes of `/api/v2`."
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.AutomationJobs
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  @json_api "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()
    :ok
  end

  test "admin reads the jobs of all Agents or of one Agent, and the runs of one job",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    source = source_event!(agent.uid)
    other_source = source_event!(agent.uid)

    job = create_job!(agent.uid, source, "Console test consumer")
    other_session_job = create_job!(agent.uid, other_source, "Second session consumer")
    foreign_job = create_job!(other_agent.uid, source_event!(other_agent.uid), "Foreign")

    assert {:ok, %{automation_job_run: run}} =
             Repo.transact(fn ->
               AutomationJobs.enqueue_run_in_tx(job.id, agent.uid, %{
                 "specversion" => "1.0",
                 "id" => "console-trigger",
                 "source" => "test://console",
                 "type" => "test.triggered",
                 "data" => %{}
               })
             end)

    assert {:ok, _worker} =
             Ankole.SessionsCase.admit_worker("automation-test-#{agent.uid}", %{
               worker_id: agent.uid
             })

    assert {:ok, %{run: attempt}} = AutomationJobs.start_attempt(run.id)

    assert {:ok, _run} =
             AutomationJobs.finish_attempt(run.id, attempt.attempt_id, %{
               status: "succeeded",
               exit_code: 0,
               stdout: "checked",
               stderr: ""
             })

    conn = console_conn(conn)

    everything = conn |> request("/api/v2/automation-jobs") |> json_response(200)

    assert MapSet.new(everything["data"], & &1["id"]) ==
             MapSet.new(Enum.map([job, other_session_job, foreign_job], &to_string(&1.id)))

    list =
      conn
      |> request("/api/v2/automation-jobs?agent=#{agent.uid}&page[limit]=1")
      |> json_response(200)

    assert [%{"id" => newest, "type" => "automation_job", "attributes" => attributes}] =
             list["data"]

    assert newest == to_string(other_session_job.id)
    assert attributes["owner_session_id"] == other_source.session_id
    assert attributes["status"] == "active"
    refute Map.has_key?(attributes, "human_uid")

    detail =
      conn
      |> request("/api/v2/agents/#{agent.uid}/automation-jobs/#{job.id}")
      |> json_response(200)

    assert detail["data"]["attributes"]["label"] == "Console test consumer"

    runs =
      conn
      |> request("/api/v2/agents/#{agent.uid}/automation-jobs/#{job.id}/runs")
      |> json_response(200)

    assert [%{"attributes" => %{"status" => "succeeded", "stdout" => "checked"}}] = runs["data"]

    assert %{"data" => []} =
             conn
             |> request("/api/v2/agents/#{other_agent.uid}/automation-jobs/#{job.id}/runs")
             |> json_response(200)

    assert %{"errors" => [%{"status" => "404"}]} =
             conn
             |> request("/api/v2/agents/#{other_agent.uid}/automation-jobs/#{job.id}")
             |> json_response(404)
  end

  test "job detail needs the read grant of the owning Agent", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    job = create_job!(agent.uid, source_event!(agent.uid), "Permission test consumer")
    {conn, admin_uid} = console_conn_with_principal(conn)
    path = "/api/v2/agents/#{agent.uid}/automation-jobs/#{job.id}"

    for {pattern, status} <- [
          {"site_console:agent:#{agent.uid}:automation_jobs", 200},
          {"site_console:automation_jobs", 403},
          {"site_console:agent:#{other_agent.uid}:automation_jobs", 403}
        ] do
      Repo.delete_all(
        from grant in Grant,
          where:
            grant.resource_pattern in ["site_console:**", "tenant_console:**"] or
              grant.principal_uid == ^admin_uid
      )

      assert {:ok, _grant} =
               AuthZ.create_permission_grant(%{
                 principal_uid: admin_uid,
                 resource_pattern: pattern,
                 action: "read",
                 condition: "true",
                 metadata: %{}
               })

      assert conn |> request(path) |> json_response(status)
    end
  end

  test "missing browser session is rejected", %{conn: conn} do
    assert conn |> get(~p"/api/v2/automation-jobs") |> json_response(401)
  end

  defp request(conn, path) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @json_api)
    |> put_req_header("content-type", @json_api)
    |> get(path)
  end

  defp create_job!(agent_uid, source, label) do
    drive_file_fixture(agent_uid, "automation/console-test/main.ts")

    assert {:ok, job} =
             AutomationJobs.create_job(%{
               agent_uid: agent_uid,
               owner_session_id: source.session_id,
               source_signal_id: source.id,
               provider_message_id: source.provider_message_id,
               source_provenance: %{"kind" => "console-test"},
               reply_route: %{
                 "binding_name" => source.reply_binding_name,
                 "conversation_id" => source.conversation_id
               },
               drive_prefix: "automation/console-test",
               label: label,
               wake_on_failure: true
             })

    job
  end

  defp source_event!(agent_uid) do
    Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid,
      binding_name: "github",
      source: "test://webhook-source"
    )
  end
end
